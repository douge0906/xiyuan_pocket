import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 极简 HTTP 会话（带 cookie jar）—— 客户端直连校园系统的基础设施。
///
/// 为什么不用 `package:http`：它的 `headers` 是多值合并成 ", " 的字符串，
/// 遇到 `Set-Cookie: a=1; Expires=Wed, 21 Oct...` 这种带逗号的 cookie 会解析错乱。
/// `dart:io` 的 `HttpHeaders` 能拿到每个 header 的独立值，最稳。
///
/// 这是**纯 Dart** 实现（不依赖 Flutter），可以用 `dart run` 直接跑端到端测试。
class CampusResponse {
  final int statusCode;
  final String body;
  final String url; // 最终 URL（跟随重定向后）

  const CampusResponse({
    required this.statusCode,
    required this.body,
    required this.url,
  });

  bool get ok => statusCode >= 200 && statusCode < 300;

  /// 是否被弹回登录页（判断会话是否失效）
  bool get looksLikeLogin => url.toLowerCase().contains('login');
}

class CampusSession {
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  final HttpClient _client;
  final Map<String, String> cookies = {};

  /// 单次请求的**总超时**：包括连接、发送、读响应体。
  /// ⚠️ 必须显式设：`HttpClient` 只提供连接超时，若服务器接了连接却不回数据，
  /// 不设总超时会让界面**无限期卡住**。
  final Duration timeout;

  CampusSession({
    this.timeout = const Duration(seconds: 25),
  }) : _client = HttpClient() {
    _client.connectionTimeout = timeout;
    _client.userAgent = defaultUserAgent;
    // 校园系统一律直连，不走系统/环境代理（否则开发机上的死代理会拖垮请求）
    _client.findProxy = (uri) => 'DIRECT';
  }

  void close() => _client.close(force: true);

  /// 导出 cookie（用于持久化会话复用）
  Map<String, String> exportCookies() => Map<String, String>.from(cookies);

  /// 导入 cookie（恢复上次会话）
  void importCookies(Map<String, String> saved) {
    cookies
      ..clear()
      ..addAll(saved);
  }

  String get _cookieHeader =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  void _captureCookies(HttpClientResponse res) {
    res.headers.forEach((name, values) {
      if (name.toLowerCase() != 'set-cookie') return;
      for (final raw in values) {
        final first = raw.split(';').first.trim();
        final eq = first.indexOf('=');
        if (eq <= 0) continue;
        final k = first.substring(0, eq).trim();
        final v = first.substring(eq + 1).trim();
        if (v.isEmpty || v.toLowerCase() == 'deleted') {
          cookies.remove(k);
        } else {
          cookies[k] = v;
        }
      }
    });
  }

  /// 统一入口：把底层的超时 / 网络异常翻译成**用户能看懂**的提示，
  /// 避免界面弹出 `TimeoutException after 0:00:25.000000` 这种天书。
  Future<CampusResponse> _send(
    String method,
    String url, {
    Map<String, String>? form,
    Map<String, String>? headers,
    bool followRedirects = true,
    String? body,
  }) async {
    try {
      return await _sendRaw(method, url,
          form: form,
          headers: headers,
          followRedirects: followRedirects,
          body: body);
    } on TimeoutException {
      throw Exception('连接学校系统超时（${timeout.inSeconds} 秒），请检查网络后重试');
    } on HandshakeException {
      throw Exception('与学校系统的安全连接失败，请确认网络环境后重试');
    } on SocketException catch (e) {
      throw Exception('网络不可达：${e.message}');
    }
  }

  Future<CampusResponse> _sendRaw(
    String method,
    String url, {
    Map<String, String>? form,
    Map<String, String>? headers,
    bool followRedirects = true,
    String? body,
  }) async {
    // ⚠️ 必须**手动**跟重定向：dart:io 自动跟随时，中间 302 响应里下发的
    //    Set-Cookie（CAS/教务的会话就藏在这一步）会拿不到。
    var currentUrl = url;
    for (var hop = 0; hop < 8; hop++) {
      final uri = Uri.parse(currentUrl);
      final req = await _client
          .openUrl(hop == 0 ? method : 'GET', uri)
          .timeout(timeout);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, defaultUserAgent);
      if (cookies.isNotEmpty) {
        req.headers.set(HttpHeaders.cookieHeader, _cookieHeader);
      }
      headers?.forEach((k, v) => req.headers.set(k, v));

      // 表单/正文只挂在第一跳上（302 之后按浏览器惯例退化为 GET）
      if (hop == 0) {
        if (form != null) {
          req.headers.contentType = ContentType(
              'application', 'x-www-form-urlencoded',
              charset: 'utf-8');
          req.add(utf8.encode(_encodeForm(form)));
        } else if (body != null) {
          req.add(utf8.encode(body));
        }
      }

      final res = await req.close().timeout(timeout);
      _captureCookies(res);

      final location = res.headers.value(HttpHeaders.locationHeader);
      final isRedirect =
          res.statusCode >= 300 && res.statusCode < 400 && location != null;
      if (isRedirect && followRedirects) {
        await res.drain<void>().timeout(timeout); // 消费响应体，避免占住连接
        currentUrl = uri.resolve(location).toString();
        continue;
      }

      final text =
          await res.transform(utf8.decoder).join().timeout(timeout);
      return CampusResponse(
        statusCode: res.statusCode,
        body: text,
        url: currentUrl,
      );
    }
    return CampusResponse(statusCode: 310, body: '', url: currentUrl);
  }

  static String _encodeForm(Map<String, String> form) => form.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');

  Future<CampusResponse> get(
    String url, {
    Map<String, String>? headers,
    bool followRedirects = true,
  }) =>
      _send('GET', url, headers: headers, followRedirects: followRedirects);

  Future<CampusResponse> postForm(
    String url,
    Map<String, String> form, {
    Map<String, String>? headers,
    bool followRedirects = true,
  }) =>
      _send('POST', url,
          form: form, headers: headers, followRedirects: followRedirects);

  /// 取 JSON（解析失败返回 null）
  static Map<String, dynamic>? tryJson(String body) {
    try {
      final v = jsonDecode(body);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// 取 JSON 的**通用形态**：顶层可能是 `{...}` 也可能是 `[...]`。
  ///
  /// 正方多数模块返回 `{items:[...]}`，但部分模块（如教材预订）直接返回数组；
  /// 用 [tryJson] 会把数组判成「非预期内容」而丢掉全部数据。
  static Object? tryJsonAny(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
}
