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

  /// 启动登录。服务端会自动识别验证码，识别成功直接返回 `loggedIn: true`
  /// （`captchaB64` 为空，前端不该再弹验证码）；识别不出来才回传图片交人工。
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
    return WebLoginStart(
      sessionId: sid,
      captchaB64: captcha,
      loggedIn: data['ok'] == true || captcha.isEmpty,
    );
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

  /// 探活：本地留存的 sid 是否仍是就绪会话。
  ///
  /// 就绪返回 true；不存在 / 过期 / 网络异常一律返回 false，由上层走两步登录。
  static Future<bool> ping(String sessionId) async {
    try {
      final resp = await http
          .post(
            Uri.parse('$_base/api/v1/campus/session/ping'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'session_id': sessionId}),
          )
          .timeout(_timeout);
      if (resp.statusCode == 401) return false;
      final data = _decode(resp);
      return data['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 探活 + 静默续期。
  ///
  /// 服务端会先用一次 GET 探上游教务罐：还活着就只滑动续期；死了就用登录时
  /// 留下的 TGT 免验证码重建 cookie 罐。**整个过程不需要用户再填验证码**，
  /// 这是对齐 h5「重进不用重新登录」体验的关键。
  ///
  /// 返回：true = 会话可用（可能已静默重建）；false = TGT 也失效，必须重新登录。
  static Future<bool> refresh(String sessionId) async {
    try {
      final resp = await http
          .post(
            Uri.parse('$_base/api/v1/campus/session/refresh'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'session_id': sessionId}),
          )
          .timeout(_timeout);
      if (resp.statusCode == 401) return false;
      if (resp.statusCode >= 500) return false;
      final data = _decode(resp);
      return data['ok'] == true;
    } catch (_) {
      return false;
    }
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
  const WebLoginStart({
    required this.sessionId,
    required this.captchaB64,
    this.loggedIn = false,
  });

  final String sessionId;
  final String captchaB64;

  /// 服务端已自动识别验证码并完成登录时 true —— 调用方直接进已登录态，
  /// 不再弹验证码对话框。
  final bool loggedIn;
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
