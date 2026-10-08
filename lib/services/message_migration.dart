import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';
import 'message_archive.dart';
import 'message_channel_service.dart';
import 'message_detail_cache.dart';
import 'message_source.dart';

/// 老缓存键 → 新档案键的一次性迁移。
///
/// ## 为什么必须有它
/// 重构把「每个源各存一份、各写一套」的两套缓存，统一成了
/// `message_archive_<sourceId>` / `message_detail_<sourceId>:<id>`。
/// 如果不迁移，**老用户升级后所有消息列表都是空的** —— 首次打开只能盯着
/// 转圈，断网时直接是「加载失败」。用户看到的形态是"更新完消息就没了"，
/// 这种静默数据回归最难自查，所以宁可多这一个文件。
///
/// ## 策略
/// * **只读老键、只写新键，老键一律保留**（不删）。缓存多占一两百 KB，
///   换来的是「迁移逻辑万一有错也还能再迁一次」。
/// * **只在对应新键为空时写入** —— 迁移重复跑多少次都不会覆盖更新的数据。
/// * 用 [_kDone] 标记只在启动时跑一次（标记丢了也不会造成损坏）。
class MessageMigration {
  static const String _kDone = 'message_archive_migrated_v1';

  // ---- 老键 ----
  static const String _kOldJwcList = 'school_notice_list_cache';
  static const String _kOldJwcDetailPrefix = 'school_notice_detail_';
  static const String _kOldInfoListPrefix = 'campus_info_list_';
  static const String _kOldInfoDetailPrefix = 'campus_info_detail_';

  /// 执行迁移。任何异常都静默 —— 迁移失败不该拦住启动，
  /// 大不了走正常的联网抓取（与原「首次安装」同一条路）。
  static Future<void> ensureMigrated() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kDone) == true) return;

      await _migrateJwc(prefs);
      await _migrateCampus(prefs);

      await prefs.setBool(_kDone, true);
    } catch (_) {
      // 静默：迁移是尽力而为，不是启动的必要条件。
    }
  }

  /// 教务处：`school_notice_list_cache` / `school_notice_detail_<id>`。
  static Future<void> _migrateJwc(SharedPreferences prefs) async {
    const id = kJwcChannelId;
    const badge = '教务处';

    final listRaw = prefs.getString(_kOldJwcList);
    if (listRaw != null && listRaw.isNotEmpty) {
      final urlById = <String, String>{};
      final items = <Message>[];
      for (final e in _decodeList(listRaw)) {
        final mid = (e['id'] ?? '').toString();
        final url = (e['url'] ?? '').toString();
        if (mid.isEmpty) continue;
        urlById[mid] = url;
        items.add(Message(
          id: mid,
          sourceId: id,
          title: (e['title'] ?? '').toString(),
          date: (e['date'] ?? '').toString(),
          url: url,
          badge: badge,
        ));
      }
      await _writeArchiveIfEmpty(id, items);

      // 详情：老键是 `school_notice_detail_<id>`，且正文里**没有 url** ——
      // 从上面刚建的 id→url 映射里补回来（MessageDetail 要求带 url）。
      for (final k in prefs.getKeys().toList()) {
        if (!k.startsWith(_kOldJwcDetailPrefix)) continue;
        final mid = k.substring(_kOldJwcDetailPrefix.length);
        if (mid.isEmpty) continue;
        await _writeDetailIfEmpty(
          sourceId: id,
          id: mid,
          raw: prefs.getString(k),
          url: urlById[mid] ?? '',
        );
      }
    }
  }

  /// 校园资讯：`campus_info_list_<cid>` / `campus_info_detail_<cid>_<id>`。
  static Future<void> _migrateCampus(SharedPreferences prefs) async {
    final nameById = {
      for (final c in MessageChannelService.allChannels) c.id: c.name,
    };

    for (final k in prefs.getKeys().toList()) {
      if (k.startsWith(_kOldInfoListPrefix)) {
        final cid = k.substring(_kOldInfoListPrefix.length);
        final raw = prefs.getString(k);
        if (cid.isEmpty || raw == null || raw.isEmpty) continue;
        final badge = nameById[cid] ?? cid;
        final urlById = <String, String>{};
        final items = <Message>[];
        for (final e in _decodeList(raw)) {
          final mid = (e['id'] ?? '').toString();
          if (mid.isEmpty) continue;
          final url = (e['url'] ?? '').toString();
          urlById[mid] = url;
          items.add(Message(
            id: mid,
            sourceId: cid,
            title: (e['title'] ?? '').toString(),
            date: (e['date'] ?? '').toString(),
            url: url,
            badge: badge,
          ));
        }
        await _writeArchiveIfEmpty(cid, items);

        // 详情老键：`campus_info_detail_<cid>_<id>` —— 在**第一个**下划线处切分，
        // 因为 <id> 自身含下划线（如 `1039_21435`）。栏目 id 都不含下划线。
        const dp = _kOldInfoDetailPrefix;
        for (final dk in prefs.getKeys().toList()) {
          if (!dk.startsWith(dp)) continue;
          final rest = dk.substring(dp.length);
          final sep = rest.indexOf('_');
          if (sep <= 0) continue;
          final did = rest.substring(0, sep);
          if (did != cid) continue;
          final mid = rest.substring(sep + 1);
          await _writeDetailIfEmpty(
            sourceId: cid,
            id: mid,
            raw: prefs.getString(dk),
            url: urlById[mid] ?? '',
          );
        }
      }
    }
  }

  static List<Map<String, dynamic>> _decodeList(String raw) {
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _writeArchiveIfEmpty(String sourceId, List<Message> items) async {
    if (items.isEmpty) return;
    // 已有新档案 → 不动（迁移绝不能盖掉更新的数据）。
    if ((await MessageArchive.load(sourceId)).isNotEmpty) return;
    await MessageArchive.save(sourceId, items);
  }

  static Future<void> _writeDetailIfEmpty({
    required String sourceId,
    required String id,
    required String? raw,
    required String url,
  }) async {
    if (raw == null || raw.isEmpty) return;
    if (await MessageDetailCache.load(sourceId, id) != null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      await MessageDetailCache.save(MessageDetail(
        id: id,
        sourceId: sourceId,
        title: (j['title'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        author: (j['author'] ?? '').toString(),
        // 老详情里可能没有 url，回退到列表里那条的 url。
        url: (j['url'] ?? '').toString().isNotEmpty
            ? (j['url'] ?? '').toString()
            : url,
        content: (j['content'] ?? '').toString(),
        attachments: ((j['attachments'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
      ));
    } catch (_) {
      // 单条损坏跳过，不影响其余条目。
    }
  }
}
