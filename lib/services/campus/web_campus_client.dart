import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
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

  /// 测试注入点：用假 client 顶住控制端（离线跑契约测试用）。
  @visibleForTesting
  static http.Client? debugClient;

  /// POST 统一出口：有 [debugClient] 走它，否则用默认 client。
  static Future<http.Response> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('$_base$path');
    final client = debugClient;
    if (client != null) {
      return client
          .post(uri,
              headers: const {'content-type': 'application/json'},
              body: jsonEncode(body))
          .timeout(_timeout);
    }
    return http
        .post(uri,
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(body))
        .timeout(_timeout);
  }

  /// 启动登录。服务端会自动识别验证码，识别成功直接返回 `loggedIn: true`
  /// （`captchaB64` 为空，前端不该再弹验证码）；识别不出来才回传图片交人工。
  static Future<WebLoginStart> startLogin(
    String username,
    String password, {
    String? service,
  }) async {
    final resp = await _post(
      '/api/v1/campus/session/start',
      {
        'username': username,
        'password': password,
        if (service != null) 'service': service,
      },
    );
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
    final resp = await _post('/api/v1/campus/session/submit', {
      'session_id': sessionId,
      'code': code,
    });
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
    final resp = await _post('/api/v1/campus/session/fetch', {
      'session_id': sessionId,
      'url': url,
      'method': method,
      'headers': headers ?? const <String, String>{},
      'body_b64': bodyB64,
    });
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
  /// 三态返回（关键：**不能把「网络故障」当成「登录过期」**）：
  /// - [SessionProbe.alive]：会话仍可用；
  /// - [SessionProbe.expired]：服务端明确回 401（会话真的没了）；
  /// - [SessionProbe.unreachable]：控制端不可达 / 5xx / 超时 —— 会话**不作废**，
  ///   上层应提示「网络异常，请稍后重试」，而不是把用户赶去重新登录。
  static Future<SessionProbe> probe(String sessionId) async {
    try {
      final resp = await _post('/api/v1/campus/session/ping', {
        'session_id': sessionId,
      });
      if (resp.statusCode == 401) return SessionProbe.expired;
      if (resp.statusCode >= 500) return SessionProbe.unreachable;
      final data = _decode(resp);
      return data['ok'] == true ? SessionProbe.alive : SessionProbe.expired;
    } on CampusException catch (e) {
      if (e.needRelogin) return SessionProbe.expired;
      return SessionProbe.unreachable;
    } catch (_) {
      return SessionProbe.unreachable;
    }
  }

  /// 探活（布尔版）。**网络故障也返回 false**，调用方要区分请用 [probe]。
  static Future<bool> ping(String sessionId) async =>
      await probe(sessionId) == SessionProbe.alive;

  /// 探活 + 静默续期。
  ///
  /// 服务端会先用一次 GET 探上游教务罐：还活着就只滑动续期；死了就用登录时
  /// 留下的 TGT 免验证码重建 cookie 罐。**整个过程不需要用户再填验证码**，
  /// 这是对齐 h5「重进不用重新登录」体验的关键。
  ///
  /// 返回：true = 会话可用（可能已静默重建）；false = TGT 也失效，必须重新登录。
  ///
  /// ⚠️ 网络故障（控制端不可达 / 5xx）时返回 [SessionProbe.unreachable]，
  /// **不要**当成过期 —— 否则断网时用户会被反复要求重新登录。
  static Future<SessionProbe> refresh(String sessionId) async {
    try {
      final resp = await _post('/api/v1/campus/session/refresh', {
        'session_id': sessionId,
      });
      if (resp.statusCode == 401) return SessionProbe.expired;
      if (resp.statusCode >= 500) return SessionProbe.unreachable;
      final data = _decode(resp);
      return data['ok'] == true ? SessionProbe.alive : SessionProbe.expired;
    } on CampusException catch (e) {
      if (e.needRelogin) return SessionProbe.expired;
      return SessionProbe.unreachable;
    } catch (_) {
      return SessionProbe.unreachable;
    }
  }

  /// 续期（布尔版）。**网络故障也返回 false**，调用方要区分请用 [refresh]。
  static Future<bool> refreshOk(String sessionId) async =>
      await refresh(sessionId) == SessionProbe.alive;

  /// 注销服务端会话（不调学校 CAS 登出，只清服务端内存罐）。
  static Future<void> logout(String sessionId) async {
    try {
      await _post('/api/v1/campus/session/logout', {
        'session_id': sessionId,
      });
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

/// 会话探活的**三态**结论。
///
/// 为什么不用 bool：旧实现把「控制端不可达 / 5xx / 超时」和「服务端明确回
/// 401 会话过期」都折成 false，于是断网或服务端抖动时，用户会看到
/// 「登录已过期，请重新登录」—— 这正是「登录一段时间后突然提示状态不在」
/// 的真实成因之一。三态之后，只有 [expired] 才允许作废本地会话。
enum SessionProbe {
  /// 会话仍然可用。
  alive,

  /// 服务端明确判定会话已失效（401），需要重新登录。
  expired,

  /// 控制端不可达 / 5xx / 超时：**会话状态未知，不能作废**。
  unreachable,
}

/// [WebCampusProxy.startLogin] 的返回。
class WebLoginStart {  const WebLoginStart({
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
