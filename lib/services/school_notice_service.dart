import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/school_notice.dart';
import '../models/message_read_storage.dart';
import 'campus/jwc_crawler.dart';
import 'campus/campus_http_fetcher.dart';

/// 列表分页结果
class SchoolNoticeListResult {
  final List<SchoolNotice> items;
  final int total;
  const SchoolNoticeListResult({required this.items, required this.total});
}

/// 学校公告服务（独立于消息中心）。
/// - 列表分页（limit/offset）+ 标题模糊搜索（q）
/// - 本地缓存：先显示上次数据，后台刷新（show-first-load-later）
/// v2.3.1：JSON 请求统一走 ApiService.requestJson。
class SchoolNoticeService {
  static const String _kListCache = 'school_notice_list_cache';
  static const String _kDetailPrefix = 'school_notice_detail_';

  // ---- 列表 ----

  /// 抓取列表（分页），返回 items + total。
  static Future<SchoolNoticeListResult> fetchList({
    int limit = 20,
    int offset = 0,
    String q = '',
  }) async {
    // 开源版：改为**客户端直抓教务处公开页面**（原走 GET /api/v1/school-notices）。
    // 用 JwcCrawler 抓取（正则方案，无需 HTML 解析库）。
    try {
      final all = await JwcCrawler.fetchList(
        fetcher: CampusHttpFetcher.inject,
        maxPages: 1,
      );
      var list = all
          .map((it) => SchoolNotice(
                id: it.id,
                title: it.title,
                date: it.date,
                url: it.url,
              ))
          .toList();
      // 本地搜索 + 分页
      final kw = q.trim().toLowerCase();
      if (kw.isNotEmpty) {
        list = list.where((e) => e.title.toLowerCase().contains(kw)).toList();
      }
      final total = list.length;
      final page = list.skip(offset).take(limit).toList();
      return SchoolNoticeListResult(items: page, total: total);
    } catch (_) {
      return const SchoolNoticeListResult(items: [], total: 0);
    }
  }

  /// 未读红点基准线（天级）：首次打开公告页时记录当天。
  ///
  /// 实现已搬到 [MessageReadStorage]（它才是"已读状态"该在的地方）。
  /// 这里保留一个转发，避免同一段逻辑存在两份。
  static Future<String> loadOrInitUnreadBaseline() =>
      MessageReadStorage.loadOrInitUnreadBaseline();

  /// 缓存首页列表，供下次打开先显示。
  ///
  /// ⚠️ **空列表一律不写入**：抓取失败时 `fetchList` 不抛异常、直接返回空列表，
  /// 若照写会把「内置快照 / 上次抓到的结果」覆盖成空 —— 用户下次打开消息页
  /// 只能看到转圈（历史 bug，见 notification_page._refreshNotices）。
  static Future<void> cacheList(List<SchoolNotice> notices) async {
    if (notices.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(notices.map((e) => e.toJson()).toList());
      await prefs.setString(_kListCache, json);
    } catch (_) {}
  }

  static Future<List<SchoolNotice>> loadCachedList() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kListCache);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => SchoolNotice.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ---- 详情 ----

  /// 拉取单条详情（正文 Markdown + 附件）。
  /// 超时/网络异常时回退本地缓存（有缓存秒开，无缓存抛原错误）。
  static Future<Map<String, dynamic>> fetchDetail(String id) async {
    // 开源版：改客户端直抓详情页。
    // 详情需要 URL —— 先从本地列表缓存里按 id 找回。
    try {
      final prefs = await SharedPreferences.getInstance();
      String? url;
      final raw = prefs.getString(_kListCache);
      if (raw != null) {
        for (final e in (jsonDecode(raw) as List)) {
          if (e is Map && e['id']?.toString() == id) {
            url = e['url']?.toString();
            break;
          }
        }
      }
      if (url == null || url.isEmpty) return const {};
      final d = await JwcCrawler.fetchDetail(
        fetcher: CampusHttpFetcher.inject,
        detailUrl: url,
      );
      if (d == null) return const {};
      return {
        'title': d.title,
        'date': d.date,
        'author': d.author,
        'content': d.content,
        'attachments': d.attachments,
      };
    } catch (_) {
      return const {};
    }
  }

  static Future<Map<String, dynamic>?> loadCachedDetail(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kDetailPrefix + id);
      if (raw == null || raw.isEmpty) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}
