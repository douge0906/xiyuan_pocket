import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';
import 'message_archive.dart';
import 'message_channel_service.dart';
import 'message_detail_cache.dart';
import 'message_source.dart';
import 'sources/jwc_source.dart';

/// 内置种子数据：把**已爬好的内容**打进 App，让首次打开秒出内容。
///
/// 为什么需要：开源版没有服务端，首次安装时本地档案是空的 —— 不预置的话，
/// 用户打开消息页要干等一次联网抓取（几秒，还可能失败）。
///
/// 做法：把随包发布的快照（`assets/seed/app_seed.json`）**翻译成新的档案格式**
/// 写进本地档案，之后走各源正常的「先显示档案 → 后台增量」流程，
/// 刷新拿到的新数据会照常覆盖这些种子。
///
/// ## 两点必须注意
/// * 快照本身仍是**老格式**（`notices` / `notice_details` / `columns` / `details`），
///   这里只在读取时翻译成 [Message] / [MessageDetail] —— 换格式不必重新生成资源。
/// * 只在「档案里没有内容」时才写。[MessageArchive.save] 本身也拒绝写空列表，
///   所以「抓取失败」永远洗不掉档案（这也是本类不能只依赖一个"已写入"标记的原因）。
class SeedData {
  SeedData._();

  /// 沿用旧标记位：老用户在升级时靠 [MessageMigration] 接管，**不需要**重新播种。
  static const String _kApplied = 'app_seed_applied_v1';
  static const String _asset = 'assets/seed/app_seed.json';

  /// 该键是否「没有可用内容」：不存在 / 空串 / 空数组都算没有。
  static bool _missing(SharedPreferences prefs, String key) {
    final v = prefs.getString(key);
    return v == null || v.isEmpty || v == '[]';
  }

  /// 写入内置内容。任何异常都静默 —— 不能让种子数据影响启动。
  static Future<void> ensureApplied() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // 已写过、且教务处档案还在 → 不用再读资源（省启动时间）。
      // 档案被清空时会走到下面重新补齐。
      if (prefs.getBool(_kApplied) == true &&
          !_missing(prefs, 'message_archive_$kJwcChannelId')) {
        return;
      }

      final raw = await rootBundle.loadString(_asset);
      final j = jsonDecode(raw) as Map<String, dynamic>;

      await _seedJwc(j);
      await _seedCampus(j);

      await prefs.setBool(_kApplied, true);
    } catch (_) {
      // 种子缺失/损坏：静默跳过，用户仍可正常联网加载
    }
  }

  // ---------------- 教务处 ----------------

  static Future<void> _seedJwc(Map<String, dynamic> j) async {
    final notices = j['notices'];
    if (notices is! List || notices.isEmpty) return;

    final urlById = <String, String>{};
    final items = <Message>[];
    for (final e in notices) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final id = (m['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final url = (m['url'] ?? '').toString();
      urlById[id] = url;
      items.add(Message(
        id: id,
        sourceId: kJwcChannelId,
        title: (m['title'] ?? '').toString(),
        date: (m['date'] ?? '').toString(),
        url: url,
        badge: kJwcChannel.badge,
      ));
    }
    await _seedArchive(kJwcChannelId, items);

    // 详情：快照里**没有 url**（老详情结构如此），从刚建的映射补回来。
    final details = j['notice_details'];
    if (details is! Map) return;
    for (final e in details.entries) {
      final id = e.key.toString();
      if (e.value is! Map) continue;
      final d = Map<String, dynamic>.from(e.value as Map);
      await _seedDetail(MessageDetail(
        id: id,
        sourceId: kJwcChannelId,
        title: (d['title'] ?? '').toString(),
        date: (d['date'] ?? '').toString(),
        author: (d['author'] ?? '').toString(),
        url: urlById[id] ?? (d['url'] ?? '').toString(),
        content: (d['content'] ?? '').toString(),
        attachments: _attachmentsOf(d),
      ));
    }
  }

  // ---------------- 校园资讯 ----------------

  static Future<void> _seedCampus(Map<String, dynamic> j) async {
    final nameById = {
      for (final c in MessageChannelService.allChannels) c.id: c.name,
    };

    final columns = j['columns'];
    if (columns is Map) {
      for (final e in columns.entries) {
        final cid = e.key.toString();
        if (e.value is! List) continue;
        final badge = nameById[cid] ?? cid;
        final items = <Message>[];
        for (final raw in (e.value as List)) {
          if (raw is! Map) continue;
          final m = Map<String, dynamic>.from(raw);
          final id = (m['id'] ?? '').toString();
          if (id.isEmpty) continue;
          items.add(Message(
            id: id,
            sourceId: cid,
            title: (m['title'] ?? '').toString(),
            date: (m['date'] ?? '').toString(),
            url: (m['url'] ?? '').toString(),
            badge: badge,
          ));
        }
        await _seedArchive(cid, items);
      }
    }

    // 详情键形如 `<栏目>_<id>`：在**第一个**下划线处切分
    // （栏目 id 不含下划线，而 <id> 自身含，如 `1039_21435`）。
    final details = j['details'];
    if (details is! Map) return;
    for (final e in details.entries) {
      final key = e.key.toString();
      final sep = key.indexOf('_');
      if (sep <= 0 || e.value is! Map) continue;
      final cid = key.substring(0, sep);
      final id = key.substring(sep + 1);
      final d = Map<String, dynamic>.from(e.value as Map);
      await _seedDetail(MessageDetail(
        id: id,
        sourceId: cid,
        title: (d['title'] ?? '').toString(),
        date: (d['date'] ?? '').toString(),
        author: (d['author'] ?? '').toString(),
        url: (d['url'] ?? '').toString(),
        content: (d['content'] ?? '').toString(),
        attachments: _attachmentsOf(d),
      ));
    }
  }

  static List<Map<String, dynamic>> _attachmentsOf(Map<String, dynamic> d) =>
      ((d['attachments'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  /// 只在档案为空时写入（不覆盖已有的、更新的数据）。
  static Future<void> _seedArchive(String sourceId, List<Message> items) async {
    if (items.isEmpty) return;
    if ((await MessageArchive.load(sourceId)).isNotEmpty) return;
    await MessageArchive.save(sourceId, items);
  }

  /// 只在详情不存在时写入。
  static Future<void> _seedDetail(MessageDetail detail) async {
    if (detail.id.isEmpty || detail.sourceId.isEmpty) return;
    if (await MessageDetailCache.load(detail.sourceId, detail.id) != null) {
      return;
    }
    await MessageDetailCache.save(detail);
  }
}
