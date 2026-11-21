import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../constants/control_config.dart';
import 'auth_gate.dart';
import 'device_identity.dart';

/// 控制端请求的唯一出口。
///
/// 三条规矩（与掌上徐工同构，避免"看不见的联网"）：
/// 1. **未登录不发**：本机没存统一认证账号时，请求在发 DNS 之前就返回 null；
/// 2. **失败静默**：超时、断网、非 2xx、解析失败一律返回 null，不弹提示；
/// 3. **只带设备身份**：请求头只有 `Device <token>`，没有用户账号、没有 token 透传。
///
/// 调用方拿到 null 就当"这次没有新内容"，走本地缓存或内置数据。
class ControlApi {
  ControlApi._();

  /// 门禁：控制端启用 + 本机已登录统一认证。
  static Future<bool> allowed() async {
    if (!ControlConfig.enabled) return false;
    return AuthGate.isLoggedIn();
  }

  static Future<Map<String, dynamic>?> getJson(
    String path, {
    Map<String, String>? query,
    bool withDeviceToken = true,
    bool requireLogin = true,
    bool useSessionToken = false,
  }) {
    return _send('GET', path,
        query: query,
        withDeviceToken: withDeviceToken,
        requireLogin: requireLogin,
        useSessionToken: useSessionToken);
  }

  static Future<Map<String, dynamic>?> postJson(
    String path,
    Map<String, dynamic> body, {
    bool withDeviceToken = true,
    bool requireLogin = true,
    bool useSessionToken = false,
  }) {
    return _send('POST', path,
        body: body,
        withDeviceToken: withDeviceToken,
        requireLogin: requireLogin,
        useSessionToken: useSessionToken);
  }

  static Future<Map<String, dynamic>?> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    bool withDeviceToken = true,
    bool requireLogin = true,
    bool useSessionToken = false,
    bool allowRefresh = true,
  }) async {
    if (!ControlConfig.enabled) return null;
    if (requireLogin && !await AuthGate.isLoggedIn()) return null;

    try {
      final base = Uri.parse('${ControlConfig.baseUrl}$path');
      final uri = (query == null || query.isEmpty)
          ? base
          : base.replace(queryParameters: query);

      final headers = <String, String>{'Content-Type': 'application/json'};
      if (useSessionToken) {
        // 会话鉴权：只带 Bearer access，不再并行带 Device 头（Authorization 单值）。
        var access = await DeviceIdentity.loadAccessToken();
        if ((access == null || access.isEmpty) && allowRefresh) {
          // 老用户升级 / 本地会话被清：先用 refresh 换一对新令牌。
          if (await refreshTokens()) {
            access = await DeviceIdentity.loadAccessToken();
          }
        }
        if (access == null || access.isEmpty) return null;
        headers['Authorization'] = 'Bearer $access';
      } else if (withDeviceToken) {
        final token = await DeviceIdentity.loadToken();
        if (token != null && token.isNotEmpty) {
          headers['Authorization'] = 'Device $token';
        }
      }

      final timeout = Duration(seconds: ControlConfig.timeoutSeconds);
      final response = switch (method) {
        'POST' => await http
            .post(uri, headers: headers, body: jsonEncode(body))
            .timeout(timeout),
        _ => await http.get(uri, headers: headers).timeout(timeout),
      };

      // access 只有 15 分钟：过期 / 被撤销时静默续期，再把本次请求重放一次。
      if (response.statusCode == 401 && useSessionToken && allowRefresh) {
        _debugLog('$method $path → HTTP 401，尝试续期');
        if (await refreshTokens()) {
          return _send(method, path,
              body: body,
              query: query,
              withDeviceToken: withDeviceToken,
              requireLogin: requireLogin,
              useSessionToken: true,
              allowRefresh: false);
        }
        _debugLog('$method $path → HTTP 401，续期失败');
        return null;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _debugLog('$method $path → HTTP ${response.statusCode}');
        return null;
      }

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is List) return {'items': decoded};
      return null;
    } catch (e) {
      // 静默：控制端只是"锦上添花"，任何失败都不该影响主流程。
      _debugLog('$method $path 失败：$e');
      return null;
    }
  }

  /// 续期单飞：refresh token 会被服务端轮换，并发续期会让后到的一路拿着
  /// 已作废的旧令牌再换一次，直接 401。共享同一个 Future，只发一次请求。
  static Future<bool>? _refreshing;

  /// 用本地 refresh token 换一对新令牌并落盘。
  ///
  /// 失败（无 refresh / 已过期 / 已撤销 / 网络异常）返回 false，调用方按无会话降级。
  static Future<bool> refreshTokens() {
    final inflight = _refreshing;
    if (inflight != null) return inflight;
    final fut = _refreshOnce().whenComplete(() {
      _refreshing = null;
    });
    _refreshing = fut;
    return fut;
  }

  static Future<bool> _refreshOnce() async {
    try {
      final refresh = await DeviceIdentity.loadRefreshToken();
      if (refresh == null || refresh.isEmpty) return false;
      final res = await _send(
        'POST',
        ControlConfig.pathRefresh,
        body: {'refresh_token': refresh},
        withDeviceToken: false,
        requireLogin: false,
        allowRefresh: false,
      );
      final access = res?['access_token']?.toString();
      final next = res?['refresh_token']?.toString();
      if (access == null || access.isEmpty || next == null || next.isEmpty) {
        return false;
      }
      await DeviceIdentity.saveSession(access, next);
      return true;
    } catch (_) {
      return false;
    }
  }

  static void _debugLog(String message) {
    if (kDebugMode) debugPrint('[control] $message');
  }
}
