import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../constants/control_config.dart';
import 'jwgl_client.dart' show CampusException;

/// Web 端有状态 CAS 会话代理客户端（B2 对接基础）。
///
/// 浏览器里 `dart:io HttpClient` 不可用，教务会话不能在浏览器内存里持有
/// cookie 罐；改由控制台 `campus_proxy.py` 在服务端按学号持有会话，本类只做
/// 三个端点的薄封装：
///   1. [startLogin]  取验证码图，建立 pending 会话（密码在服务端加密）；
///   2. [submitCaptcha] 回填人工识别的验证码，完成 CAS 登录；
///   3. [request]     带会话代取教务资源；[logout] 注销服务端会话。
///
/// 一期独立会话：会话凭证是服务端自签的 `session_id`，不与 App 设备 token 打通。
/// 本类只负责 HTTP 往返与错误翻译；解析仍复用现有教务 client。
class WebCampusProxy {
  WebCampusProxy._();

  static String get _base => ControlConfig.baseUrl;
  static const Duration _timeout = Duration(seconds: 20);

  /// 启动登录。返回会话 id 与验证码图片 base64（不含 `data:` 前缀）。
  static Future<WebLoginStart> startLogin(
    String username,
    String password, {
    String? service,
  }) async {
    final resp = await http
        .post(
          Uri.parse('$_base/api/v1/campus/session/start'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'username': username,
            'password': password,
            if (service != null) 'service': service,
          }),
        )
        .timeout(_timeout);
    final data = _decode(resp);
    final sid = (data['session_id'] ?? '').toString();
    final captcha = (data['captcha_b64'] ?? '').toString();
    if (sid.isEmpty) {
      throw CampusException('登录会话建立失败，请稍后重试');
    }
    return WebLoginStart(sessionId: sid, captchaB64: captcha);
  }

  /// 回填验证码，完成 CAS 登录并建立教务会话。
  static Future<void> submitCaptcha(String sessionId, String code) async {
    final resp = await http
        .post(
          Uri.parse('$_base/api/v1/campus/session/submit'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'session_id': sessionId, 'code': code}),
        )
        .timeout(_timeout);
    _decode(resp);
  }

  /// 带会话代取资源。响应结构对齐安卓 `CampusResponse`，便于会话适配层复用。
  static Future<WebProxyResponse> request(
    String sessionId,
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    String? bodyB64,
  }) async {
    final resp = await http
        .post(
          Uri.parse('$_base/api/v1/campus/session/fetch'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'session_id': sessionId,
            'url': url,
            'method': method,
            'headers': headers ?? const <String, String>{},
            'body_b64': bodyB64,
          }),
        )
        .timeout(_timeout);
    final data = _decode(resp);
    final b64 = data['body_b64'] as String? ?? '';
    final bytes = b64.isEmpty ? <int>[] : base64Decode(b64);
    return WebProxyResponse(
      statusCode: (data['status'] as num? ?? 0).toInt(),
      url: (data['url'] ?? url).toString(),
      body: utf8.decode(bytes, allowMalformed: true),
      headers: _asHeaderMap(data['headers']),
    );
  }

  /// 注销服务端会话（不调学校 CAS 登出，只清服务端内存罐）。
  static Future<void> logout(String sessionId) async {
    try {
      await http
          .post(
            Uri.parse('$_base/api/v1/campus/session/logout'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'session_id': sessionId}),
          )
          .timeout(_timeout);
    } catch (_) {
      // 注销失败不阻塞本地清理。
    }
  }

  // ---------------------------------------------------------------- 内部

  static Map<String, dynamic> _decode(http.Response resp) {
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(resp.body);
      data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      throw CampusException('服务器返回了非预期内容');
    }

    final err = data['error'];
    if (err is Map && err['message'] != null) {
      final code = (err['code'] ?? '').toString();
      final message = err['message'].toString();
      final relogin = code == 'session_expired';
      throw CampusException(message, needRelogin: relogin);
    }
    if (resp.statusCode >= 500) {
      throw CampusException('访问学校系统失败，请稍后重试');
    }
    return data;
  }

  static Map<String, List<String>> _asHeaderMap(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, List<String>>{};
    raw.forEach((k, v) {
      if (v is List) out[k.toString()] = v.map((e) => e.toString()).toList();
    });
    return out;
  }
}

/// [WebCampusProxy.startLogin] 的返回。
class WebLoginStart {
  const WebLoginStart({required this.sessionId, required this.captchaB64});

  final String sessionId;
  final String captchaB64;
}

/// 代理代取的响应，字段对齐安卓 `CampusResponse`。
class WebProxyResponse {
  const WebProxyResponse({
    required this.statusCode,
    required this.url,
    required this.body,
    this.headers = const {},
  });

  final int statusCode;
  final String url;
  final String body;
  final Map<String, List<String>> headers;

  bool get ok => statusCode >= 200 && statusCode < 300;
  bool get looksLikeLogin => url.toLowerCase().contains('login');
}
