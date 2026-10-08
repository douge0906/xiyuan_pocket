import 'campus_http_fetcher.dart' show CampusFetchException;
import 'campus_web.dart';
import 'jwc_crawler.dart' show NoticeItem, NoticeDetail;

/// 校园资讯栏目定义。
class InfoColumn {
  final String id;
  final String name;
  final String host;
  final String listUrl;
  final String kind; // main / xgc / tw_list
  final String pagePattern;

  const InfoColumn({
    required this.id,
    required this.name,
    required this.host,
    required this.listUrl,
    required this.kind,
    this.pagePattern = '',
  });
}

/// 校园资讯抓取（开源版 · 客户端直连）。
///
/// **移植自**原实现 `crawler/campus_notice_crawler.py`。
/// 特别注意：5 个栏目的列表页有 **3 种不同模板**，必须分别解析：
///   · `main`    —— 主站三栏目（`<div class="time"><p>日</p><p>年-月</p></div>` + `<a title>`）
///   · `xgc`     —— 学工处（`<p class="day">日</p><p class="month">英文月</p>`）
///   · `tw_list` —— 团委子栏（`<span>完整日期</span><a><em>标题</em>`）
///
/// ⚠️ 无年份的日期（xgc/tw）要按「是否晚于今天」推断年份，
///    否则会出现未来日期且排序错乱（曾踩过这个坑）。
class CampusInfoCrawler {
  CampusInfoCrawler._();

  static const String _mainHost = 'https://www.cwxu.edu.cn';

  /// 栏目清单（顺序即展示顺序）。
  static const List<InfoColumn> columns = [
    InfoColumn(
      id: 'notice',
      name: '通知公告',
      host: _mainHost,
      listUrl: '$_mainHost/notice_list.jsp?urltype=tree.TreeTempUrl&wbtreeid=1039',
      kind: 'main',
      // ⚠️ 主站公告栏翻页参数是 PAGENUM（不是 page）
      pagePattern: '$_mainHost/notice_list.jsp?totalpage=248&PAGENUM={n}'
          '&urltype=tree.TreeTempUrl&wbtreeid=1039',
    ),
    InfoColumn(
      id: 'news',
      name: '校园要闻',
      host: _mainHost,
      listUrl: '$_mainHost/index/xyyw.htm',
      kind: 'main',
      pagePattern: '$_mainHost/index/xyyw/{n}.htm',
    ),
    InfoColumn(
      id: 'express',
      name: '校园快讯',
      host: _mainHost,
      listUrl: '$_mainHost/index/xykx.htm',
      kind: 'main',
      pagePattern: '$_mainHost/index/xykx/{n}.htm',
    ),
    InfoColumn(
      id: 'xgc',
      name: '学工处',
      host: 'https://xgc.cwxu.edu.cn',
      listUrl: 'https://xgc.cwxu.edu.cn/index/tzgg.htm',
      kind: 'xgc',
      pagePattern: 'https://xgc.cwxu.edu.cn/index/tzgg/{n}.htm',
    ),
    InfoColumn(
      id: 'tw',
      name: '团委',
      host: 'https://tw.cwxu.edu.cn',
      listUrl: 'https://tw.cwxu.edu.cn/index/tzgg.htm',
      kind: 'tw_list',
      pagePattern: 'https://tw.cwxu.edu.cn/index/tzgg/{n}.htm',
    ),
  ];

  static InfoColumn? columnById(String id) {
    for (final c in columns) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 抓某栏目列表。[targetItems] 目标条数（默认 60，避免客户端长时间翻页）。
  static Future<List<NoticeItem>> fetchList({
    required Future<Object?> Function(String, Map<String, String>) fetcher,
    required String columnId,
    int targetItems = 60,
  }) async {
    final col = columnById(columnId);
    if (col == null) {
      throw CampusFetchException(columnId, '栏目未在抓取器里登记');
    }

    final html = await CampusWeb.httpGet(fetcher, col.listUrl);
    // 🔴 首页抓不到 = 整体失败，**必须抛**（理由同教务处抓取器：
    // 返回空列表会被上层当成「这个栏目没有内容」）。
    if (html == null) {
      throw CampusFetchException(col.listUrl, '列表首页抓取失败');
    }
    final items = _parse(col.kind, html, col.host);
    if (items.isEmpty) {
      throw CampusFetchException(col.listUrl, '列表首页解析不出条目');
    }

    // 翻页（页码越大越新 → 从最大页往小翻）
    if (col.pagePattern.isNotEmpty && items.length < targetItems) {
      final maxp = _detectMaxPage(html);
      for (var n = maxp; n >= 1 && items.length < targetItems; n--) {
        final page = await CampusWeb.httpGet(fetcher, col.pagePattern.replaceAll('{n}', '$n'));
        if (page == null) break;
        final got = _parse(col.kind, page, col.host);
        if (got.isEmpty) break;
        items.addAll(got);
      }
    }

    final seen = <String>{};
    final uniq = <NoticeItem>[];
    for (final it in items) {
      if (seen.add(it.id)) uniq.add(it);
    }
    uniq.sort((a, b) => b.date.compareTo(a.date));
    return uniq;
  }

  /// 按模板类型分派解析。
  static List<NoticeItem> _parse(String kind, String html, String host) {
    switch (kind) {
      case 'xgc':
        return _parseXgc(html, host);
      case 'tw_list':
        return _parseTwList(html, host);
      default:
        return _parseMain(html, host);
    }
  }

  /// 主站三栏目。**必须先按 `<li>` 切分再解析** ——
  /// 否则用 `.*?` 跨条目匹配会让「日期」配到别的「标题」（曾踩过）。
  static List<NoticeItem> _parseMain(String html, String host) {
    final out = <NoticeItem>[];
    for (final li in _splitItems(html)) {
      final dm = RegExp(
        r'<div[^>]*class="[^"]*\btime\b[^"]*"[^>]*>\s*'
        r'<p[^>]*>\s*(\d{1,2})\s*</p>\s*'
        r'<p[^>]*>\s*(\d{4})-(\d{1,2})\s*</p>',
        dotAll: true, caseSensitive: false,
      ).firstMatch(li);
      if (dm == null) continue;
      final am = RegExp(r'<a[^>]+href="([^"]+)"([^>]*)>(.*?)</a>',
              dotAll: true, caseSensitive: false)
          .firstMatch(li);
      if (am == null) continue;
      final href = am.group(1)!;
      if (href == '#' || href.isEmpty || href.contains('index.htm')) continue;

      var title = _pickTitle(am.group(2) ?? '', am.group(3)!);
      title = title.replaceAll(RegExp(r'^\[[^\]]{1,8}\]'), '').trim(); // 去 [党政事务] 前缀
      title = title.replaceAll(RegExp(r'\s+'), ' ');
      if (title.length < 6) continue;
      if (title.length > 80) title = title.substring(0, 80);

      final url = CampusWeb.resolveUrl(href, host);
      out.add(NoticeItem(
        id: _noticeId(url),
        title: title,
        date: '${dm.group(2)}-${dm.group(3)!.padLeft(2, '0')}-${dm.group(1)!.padLeft(2, '0')}',
        url: url,
      ));
    }
    return out;
  }

  /// 学工处：`<p class="day">日</p><p class="month">英文月</p>`（无年份）。
  static List<NoticeItem> _parseXgc(String html, String host) {
    const months = {
      'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
      'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
    };
    final today = DateTime.now();
    final out = <NoticeItem>[];
    for (final li in _splitItems(html)) {
      final dm = RegExp(r'class="[^"]*\bday\b[^"]*"[^>]*>\s*(\d{1,2})', caseSensitive: false)
          .firstMatch(li);
      final mm = RegExp(r'class="[^"]*\bmonth\b[^"]*"[^>]*>\s*([A-Za-z]{3})',
              caseSensitive: false)
          .firstMatch(li);
      final am = RegExp(r'<a[^>]+href="([^"]+)"([^>]*)>(.*?)</a>',
              dotAll: true, caseSensitive: false)
          .firstMatch(li);
      if (dm == null || mm == null || am == null) continue;
      final month = months[mm.group(1)!.toLowerCase()];
      if (month == null) continue;
      final href = am.group(1)!;
      if (href.contains('index.htm')) continue;

      final day = int.parse(dm.group(1)!);
      // 只有「日+月」没有年 → 若该日期晚于今天，判为去年（避免未来日期）
      var year = today.year;
      if (month > today.month || (month == today.month && day > today.day)) {
        year -= 1;
      }

      var title = _pickTitle(am.group(2) ?? '', am.group(3)!);
      title = title.replaceAll(RegExp(r'\s+'), ' ');
      if (title.length < 6) continue;
      if (title.length > 80) title = title.substring(0, 80);

      out.add(NoticeItem(
        id: _noticeId(CampusWeb.resolveUrl(href, host)),
        title: title,
        date: '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}',
        url: CampusWeb.resolveUrl(href, host),
      ));
    }
    return out;
  }

  /// 团委子栏：`<span>完整日期</span><a><em>标题</em></a>`。
  static List<NoticeItem> _parseTwList(String html, String host) {
    final out = <NoticeItem>[];
    for (final li in _splitItems(html)) {
      final m = RegExp(
        r'<span>\s*(\d{4})-(\d{1,2})-(\d{1,2})\s*</span>\s*'
        r'<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>',
        dotAll: true, caseSensitive: false,
      ).firstMatch(li);
      if (m == null) continue;
      final href = m.group(4)!;
      if (href.contains('index.htm')) continue;
      var title = CampusWeb.stripTags(m.group(5)!);
      if (title.length < 6) continue;
      if (title.length > 80) title = title.substring(0, 80);
      final url = CampusWeb.resolveUrl(href, host);
      out.add(NoticeItem(
        id: _noticeId(url),
        title: title,
        date: '${m.group(1)}-${m.group(2)!.padLeft(2, '0')}-${m.group(3)!.padLeft(2, '0')}',
        url: url,
      ));
    }
    return out;
  }

  /// 抓详情（复用教务处那套：标题/日期/正文 Markdown/附件）。
  static Future<NoticeDetail?> fetchDetail({
    required Future<Object?> Function(String, Map<String, String>) fetcher,
    required String detailUrl,
  }) async {
    // 资讯详情页结构与教务处公告一致（都是同一套 CMS）
    return _jwcDetail(fetcher, detailUrl);
  }

  // ---------- 内部工具 ----------

  /// 按 `<li>` 切分（**必须**，否则日期会配错条目）。
  static List<String> _splitItems(String html) => RegExp(r'<li[^>]*>(.*?)</li>',
          dotAll: true, caseSensitive: false)
      .allMatches(html)
      .map((m) => m.group(1)!)
      .toList();

  /// 标题优先级：title 属性 → h2 → em → 纯文本。
  static String _pickTitle(String attrs, String inner) {
    final t = RegExp(r'title="([^"]*)"', caseSensitive: false).firstMatch(attrs);
    if (t != null && t.group(1)!.trim().isNotEmpty) return t.group(1)!.trim();
    for (final tag in ['h2', 'em', 'h3']) {
      final m = RegExp('<$tag[^>]*>(.*?)</$tag>', dotAll: true, caseSensitive: false)
          .firstMatch(inner);
      if (m != null) {
        final s = CampusWeb.stripTags(m.group(1)!);
        if (s.isNotEmpty) return s;
      }
    }
    return CampusWeb.stripTags(inner);
  }

  /// 从 URL 提取短 id。
  ///
  /// 三种形态都要覆盖，否则会退化成「整条 URL 当 id」（曾踩过）：
  ///   ① /info/1129/3309.htm      → 1129_3309
  ///   ② ?wbtreeid=1164&wbnewsid=2564 → 1164_2564
  ///   ③ 兜底取末尾数字
  static String _noticeId(String url) {
    final m1 = RegExp(r'/info/(\d+)/(\d+)\.htm').firstMatch(url);
    if (m1 != null) return '${m1.group(1)}_${m1.group(2)}';
    final t = RegExp(r'wbtreeid=(\d+)').firstMatch(url);
    final n = RegExp(r'wbnewsid=(\d+)').firstMatch(url);
    if (t != null && n != null) return '${t.group(1)}_${n.group(1)}';
    if (n != null) return n.group(1)!;
    final tail = RegExp(r'(\d{3,})').allMatches(url).toList();
    if (tail.isNotEmpty) return tail.last.group(1)!;
    final s = url.replaceAll(RegExp(r'\W+'), '_');
    return s.length > 40 ? s.substring(s.length - 40) : s;
  }

  static int _detectMaxPage(String html) {
    final tp = RegExp(r'totalpage=(\d+)').allMatches(html).map((m) => int.tryParse(m.group(1)!) ?? 0);
    if (tp.isNotEmpty) return tp.reduce((a, b) => a > b ? a : b);
    final nums = RegExp(r'(?:xyyw|xykx|tzgg)/(\d+)\.htm')
        .allMatches(html)
        .map((m) => int.tryParse(m.group(1)!) ?? 0);
    if (nums.isEmpty) return 1;
    return nums.reduce((a, b) => a > b ? a : b);
  }

  /// 详情解析（与 JwcCrawler 同一套逻辑，抽到这里避免循环依赖）。
  static Future<NoticeDetail?> _jwcDetail(
    Future<Object?> Function(String, Map<String, String>) fetcher,
    String detailUrl,
  ) async {
    final html = await CampusWeb.httpGet(fetcher, detailUrl);
    if (html == null) return null;

    var title = '';
    final h1 = RegExp(r'<h1[^>]*>(.*?)</h1>', dotAll: true, caseSensitive: false).firstMatch(html);
    if (h1 != null) title = CampusWeb.stripTags(h1.group(1)!);

    var author = '';
    var date = '';
    final h3 = RegExp(r'<h3[^>]*>(.*?)</h3>', dotAll: true, caseSensitive: false).firstMatch(html);
    if (h3 != null) {
      final t = CampusWeb.stripTags(h3.group(1)!);
      final a = RegExp(r'作者：(.*?)时间：').firstMatch(t);
      if (a != null) author = a.group(1)!.trim();
      final d = RegExp(r'(\d{4}-\d{2}-\d{2})').firstMatch(t);
      if (d != null) date = d.group(1)!;
    }

    var contentHtml = '';
    final c1 = RegExp(r'''<div[^>]*class=["']?v_news_content["']?[^>]*>(.*?)</div>\s*</div>''',
            dotAll: true, caseSensitive: false)
        .firstMatch(html);
    if (c1 != null) {
      contentHtml = c1.group(1)!.trim();
    } else {
      final c2 = RegExp(r'''<div[^>]*id=["']vsb_content_\d+["'][^>]*>(.*?)</div>''',
              dotAll: true, caseSensitive: false)
          .firstMatch(html);
      if (c2 != null) contentHtml = c2.group(1)!.trim();
    }

    final base = Uri.parse(detailUrl);
    final root = '${base.scheme}://${base.host}';
    return NoticeDetail(
      title: title,
      date: date,
      author: author,
      content: CampusWeb.htmlToMarkdown(contentHtml, root),
      attachments: CampusWeb.extractAttachments(
          contentHtml.isEmpty ? html : contentHtml, root),
    );
  }
}