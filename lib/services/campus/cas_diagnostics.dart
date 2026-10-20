import 'dart:io';

/// 统一认证连通性诊断（2026-10-20）。
///
/// 用来回答一个具体问题：「App 说连不上，但浏览器能登录」到底卡在哪一步。
/// 分别探测登录页与验证码接口 —— 这两个地址的可用性经常不一致
/// （学校 WAF 可能只挡接口，不挡 HTML 页面）。
class CasDiagnostics {
  CasDiagnostics._();

  static const String casBase = 'https://wxcas.cwxu.edu.cn';
  static const String loginPage = '$casBase/lyuapServer/login';
  static const String kaptcha = '$casBase/lyuapServer/kaptcha';

  static Future<List<CasProbe>> run() async {
    final results = <CasProbe>[];
    for (final item in <({String label, String url})>[
      (label: '登录页面', url: loginPage),
      (label: '验证码接口', url: kaptcha),
    ]) {
      results.add(await _probe(item.label, item.url));
    }
    return results;
  }

  static Future<CasProbe> _probe(String label, String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..userAgent = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';
    final started = DateTime.now();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.acceptHeader, 'text/html,application/json,*/*');
      final res = await req.close().timeout(const Duration(seconds: 8));
      final body = await res.transform(const SystemEncoding().decoder).join();
      final ms = DateTime.now().difference(started).inMilliseconds;
      final looksHtml = body.trimLeft().startsWith('<');
      return CasProbe(
        label: label,
        ok: res.statusCode == 200,
        detail: 'HTTP ${res.statusCode} · ${ms}ms'
            '${res.statusCode == 200 ? (looksHtml ? ' · 返回网页' : ' · 返回数据') : ''}',
      );
    } on SocketException catch (e) {
      return CasProbe(label: label, ok: false, detail: '无法连接：${e.message}');
    } on HandshakeException catch (e) {
      return CasProbe(label: label, ok: false, detail: 'TLS 握手失败：${e.message}');
    } catch (e) {
      return CasProbe(label: label, ok: false, detail: '失败：$e');
    } finally {
      client.close(force: true);
    }
  }
}

class CasProbe {
  const CasProbe({required this.label, required this.ok, required this.detail});

  final String label;
  final bool ok;
  final String detail;
}
