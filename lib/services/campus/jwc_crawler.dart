import 'campus_http_fetcher.dart' show CampusFetchException;
import 'campus_web.dart';

/// 一条公告（列表项）。
/// 这样**页面层不需要改**（只换数据来源）。
class NoticeItem {
  final String id;
  final String title;
  final String date;
  final String url;

  const NoticeItem({
    required this.id,
    required this.title,
    required this.date,
    required this.url,
  });

  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'date': date, 'url': url, 'has_content': false, 'views': 0};
}

/// 公告详情。
class NoticeDetail {
  final String title;
  final String date;
  final String author;
  final String content; // Markdown
  final List<Map<String, String>> attachments;

  const NoticeDetail({
    required this.title,
    required this.date,
    this.author = '',
    this.content = '',
    this.attachments = const [],
  });
}

/// 教务处公告抓取（开源版 · 客户端直连）。
///
/// **移植自**原实现 `crawler/jwc_notice_crawler.py`，正则与解析逻辑逐条对应，
/// 保证与原实现结果一致（便于对比排查）。
///
/// ⚠️ 这是**只读公开页面**，不登录、不绕验证。
class JwcCrawler {
  JwcCrawler._();

  static const String baseUrl = 'https://jwc.cwxu.edu.cn';
  static const String listUrl = '$baseUrl/index/tzgg.htm';

  /// 抓列表页（首页 + 可选翻页）。
  ///
  /// [fetcher] 注入的 HTTP 客户端（形如 `(url, headers) async => body`）。
  /// [maxPages] 翻页上限（1 = 只抓首页）。页码越大越新，故从最大页往回翻。
  static Future<List<NoticeItem>> fetchList({
    required Future<Object?> Function(String, Map<String, String>) fetcher,
    int maxPages = 1,
  }) async {
    final html = await CampusWeb.httpGet(fetcher, listUrl);
    // 🔴 首页抓不到 = 整体失败，**必须抛**（不能返回空列表 —— 那会被
    // 上层当成「确实没有公告」，于是断网时界面显示「暂无内容」）。
    if (html == null) {
      throw CampusFetchException(listUrl, '列表首页抓取失败');
    }
    final items = _parseList(html);
    // 抓到了页面却解析不出任何条目 = 站点结构变了 / 被拦截页顶替，
    // 同样是失败。教务处通知公告页从来不会是空的。
    if (items.isEmpty) {
      throw CampusFetchException(listUrl, '列表首页解析不出条目');
    }

    if (maxPages > 1) {
      final maxp = _detectMaxPage(html);
      for (var n = maxp; n >= 1 && items.length < maxPages * 20; n--) {
        final page = await CampusWeb.httpGet(fetcher, '$baseUrl/index/tzgg/$n.htm');
        if (page == null) break;
        final got = _parseList(page);
        if (got.isEmpty) break;
        items.addAll(got);
      }
    }

    // 去重（按 id）+ 新→旧排序
    final seen = <String>{};
    final uniq = <NoticeItem>[];
    for (final it in items) {
      if (seen.add(it.id)) uniq.add(it);
    }
    uniq.sort((a, b) => b.date.compareTo(a.date));
    return uniq;
  }

  /// 解析列表页（对应 Python `_parse_list_items`）。
  static List<NoticeItem> _parseList(String html) {
    final out = <NoticeItem>[];
    // <li id="line_u7_数字"> ... </li>
    final liRe = RegExp(r'''<li[^>]*id=["']line_u7_\d+["'][^>]*>(.*?)</li>''',
        dotAll: true, caseSensitive: false);
    final aRe = RegExp(r'''<a[^>]+href=["']([^"']+)["'][^>]*>(.*?)</a>''',
        dotAll: true, caseSensitive: false);
    final emRe = RegExp(r'<em>(.*?)</em>', dotAll: true, caseSensitive: false);
    final spanRe = RegExp(r'<span>(.*?)</span>', dotAll: true, caseSensitive: false);

    for (final li in liRe.allMatches(html)) {
      final block = li.group(1)!;
      final am = aRe.firstMatch(block);
      if (am == null) continue;
      final href = am.group(1)!;
      final inner = am.group(2)!;

      final em = emRe.firstMatch(inner);
      final title = CampusWeb.stripTags(em?.group(1) ?? inner);
      final sp = spanRe.firstMatch(inner);
      final date = sp == null ? '' : CampusWeb.stripTags(sp.group(1)!);

      final url = CampusWeb.resolveUrl(href, baseUrl);
      final idm = RegExp(r'/info/\d+/(\d+)\.htm').firstMatch(url);
      final id = idm != null
          ? idm.group(1)!
          : url.replaceAll(RegExp(r'\W+'), '_');

      if (title.isNotEmpty && url.isNotEmpty) {
        out.add(NoticeItem(id: id, title: title, date: date, url: url));
      }
    }
    return out;
  }

  /// 从首页分页链接找最大页码（页码越大越新）。
  static int _detectMaxPage(String html) {
    final nums = RegExp(r'tzgg/(\d+)\.htm')
        .allMatches(html)
        .map((m) => int.tryParse(m.group(1)!) ?? 0)
        .toList();
    if (nums.isEmpty) return 0;
    return nums.reduce((a, b) => a > b ? a : b);
  }

  /// 抓详情（对应 Python `fetch_notice_detail`）。
  static Future<NoticeDetail?> fetchDetail({
    required Future<Object?> Function(String, Map<String, String>) fetcher,
    required String detailUrl,
  }) async {
    final html = await CampusWeb.httpGet(fetcher, detailUrl);
    if (html == null) return null;

    // 标题：<h1>
    var title = '';
    final h1 = RegExp(r'<h1[^>]*>(.*?)</h1>', dotAll: true, caseSensitive: false)
        .firstMatch(html);
    if (h1 != null) title = CampusWeb.stripTags(h1.group(1)!);

    // 作者 / 日期：<h3> 里的「作者：xxx 时间：YYYY-MM-DD」
    var author = '';
    var date = '';
    final h3 = RegExp(r'<h3[^>]*>(.*?)</h3>', dotAll: true, caseSensitive: false)
        .firstMatch(html);
    if (h3 != null) {
      final t = CampusWeb.stripTags(h3.group(1)!);
      final a = RegExp(r'作者：(.*?)时间：').firstMatch(t);
      if (a != null) author = a.group(1)!.trim();
      final d = RegExp(r'(\d{4}-\d{2}-\d{2})').firstMatch(t);
      if (d != null) date = d.group(1)!;
    }

    // 正文：v_news_content 或 vsb_content_N
    var contentHtml = '';
    final c1 = RegExp(r'''<div[^>]*class=["']?v_news_content["']?[^>]*>(.*?)</div>\s*</div>''',
        dotAll: true, caseSensitive: false).firstMatch(html);
    if (c1 != null) {
      contentHtml = c1.group(1)!.trim();
    } else {
      final c2 = RegExp(r'''<div[^>]*id=["']vsb_content_\d+["'][^>]*>(.*?)</div>''',
          dotAll: true, caseSensitive: false).firstMatch(html);
      if (c2 != null) contentHtml = c2.group(1)!.trim();
    }

    return NoticeDetail(
      title: title,
      date: date,
      author: author,
      content: CampusWeb.htmlToMarkdown(contentHtml, baseUrl),
      attachments: CampusWeb.extractAttachments(
          contentHtml.isEmpty ? html : contentHtml, baseUrl),
    );
  }
}