import 'dart:convert';
import 'package:http/http.dart' as http;

/// 给爬虫用的 HTTP 抓取器（开源版）。
///
/// 为什么单独一层：
///   `campus_web.dart` 里的爬虫函数需要 `(url, headers) async => body` 形式的注入，
///   而项目里同时存在 `http`（简单请求）与 `dio`（带 cookie 的会话）两种客户端。
///   这里统一用 `http` 做**无状态抓取**（抓公开页面不需要 cookie），
///   保持与爬虫逻辑解耦、便于测试。
class CampusHttpFetcher {
  CampusHttpFetcher._();

  /// 默认 UA（与浏览器一致，避免被站点按「无 UA」拦截）。
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 抓一个页面（返回 UTF-8 文本）。失败返回 null。
  static Future<String?> get(String url, [Map<String, String>? headers]) async {
    try {
      final resp = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': userAgent,
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9',
          ...?headers,
        },
      ).timeout(const Duration(seconds: 20));

      if (resp.statusCode != 200) return null;
      // 站点多用 UTF-8；用 allowMalformed 避免个别坏字节导致整体失败
      return utf8.decode(resp.bodyBytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// 供爬虫注入的 fetcher 形态（`(url, headers) async => body`）。
  ///
  /// 用法：`CampusInfoCrawler.fetchList(fetcher: CampusHttpFetcher.inject, ...)`
  static Future<Object?> inject(String url, Map<String, String> headers) =>
      get(url, headers);
}