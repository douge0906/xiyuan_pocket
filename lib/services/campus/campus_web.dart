import 'dart:convert';

/// 校园网抓取的通用工具（开源版 · 客户端直连）。
///
/// 移植自原实现 `crawler/jwc_notice_crawler.py` 的辅助函数，
/// 逻辑**逐条对照翻译**，确保解析结果一致：
///   · `httpGet`         —— 带 UA 的 GET，UTF-8 解码
///   · `resolveUrl`      —— 相对路径 → 绝对 URL（处理 `../`）
///   · `stripTags`       —— 去标签 + 实体反转义 + 压缩空白
///   · `htmlToMarkdown`  —— 正文 HTML → Markdown（保留表格/加粗/列表/链接/图片）
///   · `extractAttachments` —— 从正文提取附件链接
///
/// ⚠️ 为什么不用现成的 HTML 解析库：
///   抓到的 HTML 结构简单且稳定，用正则比引入 HTML 解析库更轻，
///   也避免多一个依赖。
class CampusWeb {
  CampusWeb._();

  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// GET 请求（UTF-8）。失败返回 null，不抛异常阻塞主流程。
  /// [fetcher] 由调用方注入（用项目统一的 http/dio 客户端）。
  static Future<String?> httpGet(
    Future<Object?> Function(String url, Map<String, String> headers) fetcher,
    String url, {
    int timeoutSec = 20,
  }) async {
    try {
      final raw = await fetcher(url, {'User-Agent': userAgent});
      if (raw == null) return null;
      if (raw is String) return raw;
      if (raw is List<int>) return utf8.decode(raw, allowMalformed: true);
      return raw.toString();
    } catch (_) {
      return null;
    }
  }

  /// 相对 URL → 绝对 URL。支持 `http(s)://`、`/abs`、`../rel`、`rel`。
  static String resolveUrl(String href, String baseUrl) {
    if (href.isEmpty) return '';
    final h = href.trim();
    if (h.startsWith('http://') || h.startsWith('https://')) return h;
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    if (h.startsWith('/')) return '$base$h';
    if (h.startsWith('../')) {
      // '../info/1033/x.htm' → 去掉 '../'
      return '$base/${h.replaceFirst(RegExp(r'^\.\./'), '')}';
    }
    return '$base/$h';
  }

  /// HTML 实体反转义。
  static String unescape(String text) => text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');

  /// 去标签 + 反转义 + 压缩空白（用于标题等短文本）。
  static String stripTags(String html) {
    var t = html.replaceAll(RegExp(r'<[^>]+>'), '');
    t = unescape(t);
    return t.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// 正文 HTML → Markdown。保留表格、加粗、列表、链接、图片。
  ///
  /// 正文 HTML → Markdown；[resolve] 用于把相对链接转绝对。
  static String htmlToMarkdown(String html, String baseUrl) {
    if (html.trim().isEmpty) return '';
    var s = html;

    // 去掉脚本与样式、注释
    s = s.replaceAll(RegExp(r'<(script|style)[^>]*>.*?</\1>', dotAll: true, caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

    // 表格优先整体转换
    s = s.replaceAllMapped(
      RegExp(r'<table.*?</table>', dotAll: true, caseSensitive: false),
      (m) => _tableToMd(m.group(0)!, baseUrl),
    );

    // 标题
    for (var i = 1; i <= 6; i++) {
      s = s.replaceAllMapped(
        RegExp('<h$i[^>]*>(.*?)</h$i>', dotAll: true, caseSensitive: false),
        (m) => '\n\n${'#' * (i + 1 <= 6 ? i + 1 : 6)} ${_inlineMd(m.group(1)!, baseUrl)}\n\n',
      );
    }

    // 换行与块级
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'</(p|div|section|blockquote)>', caseSensitive: false), '\n\n');
    s = s.replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '\n- ');
    s = s.replaceAll(RegExp(r'</li>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'</?(ul|ol)[^>]*>', caseSensitive: false), '\n');

    // 图片 → 加粗 → 链接
    s = s.replaceAllMapped(
      RegExp(r'''<img[^>]+src=["']([^"']+)["'][^>]*/?>''', caseSensitive: false),
      (m) => '\n\n![](${resolveUrl(m.group(1)!, baseUrl)})\n\n',
    );
    s = s.replaceAllMapped(
      RegExp(r'<(strong|b)[^>]*>(.*?)</\1>', dotAll: true, caseSensitive: false),
      (m) => '**${m.group(2)}**',
    );
    s = s.replaceAllMapped(
      RegExp(r'''<a[^>]+href=["']([^"']+)["'][^>]*>(.*?)</a>''', dotAll: true, caseSensitive: false),
      (m) {
        final txt = stripTags(m.group(2)!);
        final url = resolveUrl(m.group(1)!, baseUrl);
        return '[${txt.isEmpty ? url : txt}]($url)';
      },
    );

    // 去掉剩余标签 + 反转义
    var text = s.replaceAll(RegExp(r'<[^>]+>'), '');
    text = unescape(text);

    // 规整空行
    final out = <String>[];
    var blank = 0;
    for (final raw in text.split('\n')) {
      final ln = raw.trimRight();
      if (ln.trim().isEmpty) {
        blank++;
        if (blank <= 1) out.add('');
      } else {
        blank = 0;
        out.add(ln.trim());
      }
    }
    var md = out.join('\n').trim();
    md = md.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return md;
  }

  /// 内联 HTML → Markdown 内联文本（表格单元格用）。
  static String _inlineMd(String html, String baseUrl) {
    var s = html;
    s = s.replaceAllMapped(
      RegExp(r'''<img[^>]+src=["']([^"']+)["'][^>]*/?>''', caseSensitive: false),
      (m) => '![](${resolveUrl(m.group(1)!, baseUrl)})',
    );
    s = s.replaceAllMapped(
      RegExp(r'<(strong|b)[^>]*>(.*?)</\1>', dotAll: true, caseSensitive: false),
      (m) => '**${m.group(2)}**',
    );
    s = s.replaceAllMapped(
      RegExp(r'''<a[^>]+href=["']([^"']+)["'][^>]*>(.*?)</a>''', dotAll: true, caseSensitive: false),
      (m) {
        final txt = stripTags(m.group(2)!);
        final url = resolveUrl(m.group(1)!, baseUrl);
        return '[${txt.isEmpty ? url : txt}]($url)';
      },
    );
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    s = unescape(s);
    s = s.replaceAll('\r', ' ').replaceAll('\n', ' ').replaceAll('|', r'\|');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// `<table>` → Markdown 表格。
  static String _tableToMd(String table, String baseUrl) {
    final rows = RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true, caseSensitive: false)
        .allMatches(table)
        .map((m) => m.group(1)!)
        .toList();
    final mdRows = <List<String>>[];
    var maxCols = 0;
    for (final r in rows) {
      final cells = RegExp(r'<t[dh][^>]*>(.*?)</t[dh]>', dotAll: true, caseSensitive: false)
          .allMatches(r)
          .map((m) => _inlineMd(m.group(1)!, baseUrl))
          .map((c) => c.isEmpty ? ' ' : c)
          .toList();
      if (cells.isEmpty) continue;
      if (cells.length > maxCols) maxCols = cells.length;
      mdRows.add(cells);
    }
    if (mdRows.isEmpty) return '';
    final lines = <String>[];
    for (var i = 0; i < mdRows.length; i++) {
      final cells = List<String>.from(mdRows[i]);
      while (cells.length < maxCols) {
        cells.add(' ');
      }
      lines.add('| ${cells.join(' | ')} |');
      if (i == 0) {
        lines.add('|${' --- |' * maxCols}');
      }
    }
    return '\n\n${lines.join('\n')}\n\n';
  }

  /// 从正文提取附件（常见文档扩展名）。
  static List<Map<String, String>> extractAttachments(String html, String baseUrl) {
    final out = <Map<String, String>>[];
    final seen = <String>{};
    for (final m in RegExp(r'''<a[^>]+href=["']([^"']+)["'][^>]*>(.*?)</a>''',
            dotAll: true, caseSensitive: false)
        .allMatches(html)) {
      final href = m.group(1)!;
      final name = stripTags(m.group(2)!).trim();
      final lower = '${href.toLowerCase()}$name'.toLowerCase();
      const exts = ['.doc', '.docx', '.xls', '.xlsx', '.pdf', '.zip', '.rar', '.ppt', '.pptx'];
      if (!exts.any(lower.contains)) continue;
      final url = resolveUrl(href, baseUrl);
      if (url.isNotEmpty && name.isNotEmpty && seen.add(url)) {
        out.add({'name': name, 'url': url});
      }
    }
    return out;
  }
}