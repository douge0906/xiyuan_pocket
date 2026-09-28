import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'campus/campus_info_crawler.dart';
import 'campus/campus_http_fetcher.dart';

/// 一条校园资讯（列表项，不含正文）。
class CampusInfoItem {
  final String id;
  final String title;
  final String date;
  final String url;
  final String column;

  const CampusInfoItem({
    required this.id,
    required this.title,
    required this.date,
    required this.url,
    required this.column,
  });

  factory CampusInfoItem.fromJson(Map<String, dynamic> j) => CampusInfoItem(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
        column: (j['column'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'date': date,
        'url': url,
        'column': column,
      };
}

/// 资讯详情（含 Markdown 正文与附件）。
class CampusInfoDetail {
  final String id;
  final String title;
  final String date;
  final String author;
  final String url;
  final String content;
  final List<Map<String, dynamic>> attachments;

  const CampusInfoDetail({
    required this.id,
    required this.title,
    required this.date,
    required this.author,
    required this.url,
    required this.content,
    this.attachments = const [],
  });

  factory CampusInfoDetail.fromJson(Map<String, dynamic> j) => CampusInfoDetail(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        author: (j['author'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
        content: (j['content'] ?? '').toString(),
        attachments: ((j['attachments'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
      );
}

/// 校园资讯服务（v2.3.0）。
///
/// 校园资讯中心：5 个公开栏目（通知公告 / 校园要闻 / 校园快讯 /
/// 学工处 / 团委），30 分钟定时同步。
///
/// 缓存策略：**先本地后网络** —— 进入栏目立刻显示上次缓存（无白屏），
/// 同时后台拉新并回写；下拉刷新则强制走网络。
class CampusInfoService {
  CampusInfoService._();

  static const String _kListPrefix = 'campus_info_list_';
  static const String _kDetailPrefix = 'campus_info_detail_';

  /// 拉取某栏目列表。
  ///
  /// [force] 为 true 时跳过缓存直连网络（下拉刷新用）。
  static Future<List<CampusInfoItem>> fetchList(
    String columnId, {
    bool force = false,
    int limit = 200,
    String q = '',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_kListPrefix$columnId';
    // 有搜索词时不走缓存（缓存是全量列表，避免"搜出来的是旧缓存"的错觉）
    final searching = q.trim().isNotEmpty;
    if (searching) force = true;

    if (!force) {
      final cached = prefs.getString(key);
      if (cached != null) {
        try {
          final list = (jsonDecode(cached) as List)
              .whereType<Map>()
              .map((e) => CampusInfoItem.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          if (list.isNotEmpty) {
            // 后台刷新（不阻塞 UI 显示）
            _refreshInBackground(columnId, limit);
            return list;
          }
        } catch (_) {
          // 缓存损坏 → 走网络
        }
      }
    }

    final fresh = await _fetchFromNetwork(columnId, limit, q);
    if (fresh != null) {
      await prefs.setString(
          key, jsonEncode(fresh.map((e) => e.toJson()).toList()));
      return fresh;
    }
    return const [];
  }

  static Future<void> _refreshInBackground(String columnId, int limit) async {
    try {
      final fresh = await _fetchFromNetwork(columnId, limit);
      if (fresh != null && fresh.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('$_kListPrefix$columnId',
            jsonEncode(fresh.map((e) => e.toJson()).toList()));
      }
    } catch (_) {}
  }

  static Future<List<CampusInfoItem>?> _fetchFromNetwork(
      String columnId, int limit, [String q = '']) async {
    // 开源版：改为**客户端直抓公开网页**（原走 GET /api/v1/campus-info/...）。
    // 用 CampusInfoCrawler 抓取（正则方案，无需 HTML 解析库）。
    try {
      final items = await CampusInfoCrawler.fetchList(
        fetcher: CampusHttpFetcher.inject,
        columnId: columnId,
        targetItems: limit > 20 ? limit : 60,
      );
      var list = items
          .map((it) => CampusInfoItem(
                id: it.id,
                title: it.title,
                date: it.date,
                url: it.url,
                column: columnId,
              ))
          .toList();
      // 本地搜索（在客户端过滤）
      final kw = q.trim().toLowerCase();
      if (kw.isNotEmpty) {
        list = list.where((e) => e.title.toLowerCase().contains(kw)).toList();
      }
      return list;
    } catch (_) {
      return null;
    }
  }

  /// 拉取详情（含正文）。缓存优先，缺失时联网。
  static Future<CampusInfoDetail?> fetchDetail(
      String columnId, String noticeId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_kDetailPrefix${columnId}_$noticeId';

    final cached = prefs.getString(key);
    if (cached != null) {
      try {
        return CampusInfoDetail.fromJson(
            jsonDecode(cached) as Map<String, dynamic>);
      } catch (_) {}
    }

    // 开源版：改客户端直抓详情页。
    // 详情需要 URL，但调用方只传了 noticeId —— 先从本地列表缓存里按 id 找回 URL。
    try {
      final listRaw = prefs.getString('$_kListPrefix$columnId');
      String? url;
      if (listRaw != null) {
        for (final e in (jsonDecode(listRaw) as List)) {
          if (e is Map && e['id']?.toString() == noticeId) {
            url = e['url']?.toString();
            break;
          }
        }
      }
      if (url == null || url.isEmpty) return null;

      final d = await CampusInfoCrawler.fetchDetail(
        fetcher: CampusHttpFetcher.inject,
        detailUrl: url,
      );
      if (d == null) return null;

      final body = <String, dynamic>{
        'id': noticeId,
        'title': d.title,
        'date': d.date,
        'author': d.author,
        'url': url,
        'content': d.content,
        'attachments': d.attachments,
      };
      await prefs.setString(key, jsonEncode(body));
      return CampusInfoDetail.fromJson(body);
    } catch (_) {
      return null;
    }
  }
}