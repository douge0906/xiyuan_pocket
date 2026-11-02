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
  }) {
    return _send('GET', path,
        query: query,
        withDeviceToken: withDeviceToken,
        requireLogin: requireLogin);
  }

  static Future<Map<String, dynamic>?> postJson(
    String path,
    Map<String, dynamic> body, {
    bool withDeviceToken = true,
    bool requireLogin = true,
  }) {
    return _send('POST', path,
        body: body,
        withDeviceToken: withDeviceToken,
        requireLogin: requireLogin);
  }

  static Future<Map<String, dynamic>?> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    bool withDeviceToken = true,
    bool requireLogin = true,
  }) async {
    if (!ControlConfig.enabled) return null;
    if (requireLogin && !await AuthGate.isLoggedIn()) return null;

    try {
      final base = Uri.parse('${ControlConfig.baseUrl}$path');
      final uri = (query == null || query.isEmpty)
          ? base
          : base.replace(queryParameters: query);

      final headers = <String, String>{'Content-Type': 'application/json'};
      if (withDeviceToken) {
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

  static void _debugLog(String message) {
    if (kDebugMode) debugPrint('[control] $message');
  }
}
