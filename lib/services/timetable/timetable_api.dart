import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../constants/control_config.dart';
import '../control_service.dart';

/// 班级课表在线库的请求层。
///
/// 为什么不复用 [ControlApi]：那一层的契约是「失败静默返回 null」——它服务的
/// 是内容下发（公告、校历）这类可有可无的东西，失败就当没有。课表上传不一样：
/// 用户填错了上传者名称、少选了学期，服务端会回一句**具体的中文原因**，
/// 这条原因必须原样显示给他，否则他只知道「失败了」，不知道怎么改。
///
/// 所以这里自己发请求，把 `{"error":{"code","message"}}` 里的 message 带出来。
class TimetableApi {
  TimetableApi._();

  /// 一次请求的结果。`ok == false` 时 [message] 一定有值。
  static Future<TimetableResult> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    if (!ControlConfig.enabled) {
      return const TimetableResult(ok: false, message: '课表服务没有开启');
    }
    final token = await ControlService.ensureDevice();
    if (token == null || token.isEmpty) {
      return const TimetableResult(
        ok: false,
        message: '设备还没注册好，请检查网络后重试',
      );
    }

    try {
      final base = Uri.parse('${ControlConfig.baseUrl}$path');
      final uri =
          (query == null || query.isEmpty) ? base : base.replace(queryParameters: query);
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Device $token',
      };
      final wait = timeout ?? const Duration(seconds: 20);

      final response = switch (method) {
        'POST' => await http
            .post(uri, headers: headers, body: jsonEncode(body ?? const {}))
            .timeout(wait),
        'DELETE' => await http.delete(uri, headers: headers).timeout(wait),
        _ => await http.get(uri, headers: headers).timeout(wait),
      };

      final text = utf8.decode(response.bodyBytes, allowMalformed: true);
      final decoded = _tryDecode(text);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (decoded is Map<String, dynamic>) {
          final data = decoded['data'];
          return TimetableResult(
            ok: true,
            data: data is Map<String, dynamic> ? data : decoded,
          );
        }
        return TimetableResult(ok: true, data: <String, dynamic>{});
      }

      // 服务端统一信封：{"error":{"code","message"},"request_id":...}
      final message = _messageOf(decoded) ??
          '请求失败（HTTP ${response.statusCode}）';
      if (kDebugMode) {
        debugPrint('[timetable] $method $path → ${response.statusCode} $message');
      }
      return TimetableResult(ok: false, message: message);
    } on TimeoutException {
      return const TimetableResult(ok: false, message: '连接课表服务超时，请检查网络');
    } on http.ClientException {
      return const TimetableResult(ok: false, message: '连不上课表服务，请检查网络');
    } catch (e) {
      if (kDebugMode) debugPrint('[timetable] $method $path 失败：$e');
      return const TimetableResult(ok: false, message: '课表服务暂时不可用');
    }
  }

  static dynamic _tryDecode(String text) {
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  static String? _messageOf(dynamic decoded) {
    if (decoded is! Map) return null;
    final error = decoded['error'];
    if (error is Map) {
      final msg = (error['message'] ?? '').toString().trim();
      if (msg.isNotEmpty) return msg;
      final code = (error['code'] ?? '').toString().trim();
      if (code.isNotEmpty) return code;
    }
    final detail = decoded['detail'];
    if (detail is Map) {
      final msg = (detail['message'] ?? '').toString().trim();
      if (msg.isNotEmpty) return msg;
    }
    return null;
  }

  // ---------------------------------------------------------------- 检索

  /// 按学年学期 + 可选筛选检索班级。
  static Future<TimetableResult> search({
    required String xnm,
    required String xqm,
    String jgmc = '',
    String zymc = '',
    String bj = '',
    String keyword = '',
  }) {
    return _send('POST', '/api/v1/timetables/search', body: {
      'xnm': xnm,
      'xqm': xqm,
      'jgmc': jgmc,
      'zymc': zymc,
      'bj': bj,
      'keyword': keyword,
    });
  }

  /// 某班级下全部已发布课表（多版本）。
  static Future<TimetableResult> classDetail(String classKey) {
    // class_key 里可能含 `|` 和中文，必须整个编码，不能被 Uri 当成路径分段。
    return _send(
      'GET',
      '/api/v1/timetables/class/${Uri.encodeComponent(classKey)}',
    );
  }

  // ---------------------------------------------------------------- 上传

  static Future<TimetableResult> createUpload(Map<String, dynamic> payload) {
    return _send(
      'POST',
      '/api/v1/timetables/uploads',
      body: payload,
      // 200 门课的 JSON 比一个班级列表大，给足时间。
      timeout: const Duration(seconds: 40),
    );
  }

  static Future<TimetableResult> myUploads() {
    return _send('GET', '/api/v1/timetables/uploads/mine');
  }

  static Future<TimetableResult> revokeUpload(int id) {
    return _send('DELETE', '/api/v1/timetables/uploads/$id');
  }

  static Future<TimetableResult> resubmit(int id, Map<String, dynamic> payload) {
    return _send(
      'POST',
      '/api/v1/timetables/uploads/$id/resubmit',
      body: payload,
      timeout: const Duration(seconds: 40),
    );
  }

  // ---------------------------------------------------------------- 收藏

  static Future<TimetableResult> favorites() {
    return _send('GET', '/api/v1/timetables/favorites');
  }

  static Future<TimetableResult> addFavorite(String classKey) {
    return _send(
        'POST', '/api/v1/timetables/favorites/${Uri.encodeComponent(classKey)}');
  }

  static Future<TimetableResult> removeFavorite(String classKey) {
    return _send(
        'DELETE', '/api/v1/timetables/favorites/${Uri.encodeComponent(classKey)}');
  }
}

/// 请求结果。[ok] 为假时 [message] 是给人看的中文。
@immutable
class TimetableResult {
  const TimetableResult({required this.ok, this.data, this.message = ''});

  final bool ok;
  final Map<String, dynamic>? data;
  final String message;

  List<Map<String, dynamic>> listOf(String key) {
    final raw = data?[key];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
  }
}
