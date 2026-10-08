import 'dart:convert';
import 'package:http/http.dart' as http;

/// 抓取失败信号 —— **爬虫必须用它把"失败"和"没有内容"分开**。
///
/// 🔴 为什么要有这个异常：抓取函数此前用「返回空列表」表示失败，而空列表
/// 同时也是「这个栏目真的没有内容」。两者在调用方**完全同形**，于是断网时
/// 界面显示「暂无内容」而不是「加载失败」—— 本项目发作次数最多的 bug
/// （累计 6~7 次）就是这一条。
///
/// 约定：
/// - **首页**抓不到 / 解析不出条目 → 抛本异常（整体失败）；
/// - **翻页**过程中的失败 → 不抛，保留已经拿到的部分（「有多少取多少」）。
class CampusFetchException implements Exception {
  final String url;
  final String reason;

  const CampusFetchException(this.url, [this.reason = '']);

  @override
  String toString() =>
      'CampusFetchException($url${reason.isEmpty ? '' : ' · $reason'})';
}

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