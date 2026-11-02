import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../constants/control_config.dart';
import 'control_api.dart';
import 'device_identity.dart';
import 'storage_service.dart';

enum ControlFailureKind {
  offline,
  timeout,
  unauthorized,
  forbidden,
  quota,
  server,
  client,
  unknown,
}

class ControlFailure implements Exception {
  const ControlFailure(this.kind, this.message, {this.status});

  final ControlFailureKind kind;
  final String message;
  final int? status;

  bool get canRetry =>
      kind == ControlFailureKind.offline ||
      kind == ControlFailureKind.timeout ||
      kind == ControlFailureKind.server;

  @override
  String toString() => message;
}

class ResourceFetchResult {
  const ResourceFetchResult({
    this.data,
    this.failure,
    this.syncedAt,
  });

  final Map<String, dynamic>? data;
  final ControlFailure? failure;
  final String? syncedAt;

  bool get offline => failure != null;
}

ControlFailure _failureForStatus(int status, String message) {
  final kind = switch (status) {
    401 => ControlFailureKind.unauthorized,
    403 => ControlFailureKind.forbidden,
    429 => ControlFailureKind.quota,
    >= 500 => ControlFailureKind.server,
    >= 400 => ControlFailureKind.client,
    _ => ControlFailureKind.unknown,
  };
  return ControlFailure(kind, message, status: status);
}

/// 控制端业务层：设备登记 / 断言登录 / 内容下发。
///
/// 只做"可有可无"的事：设备身份、会话、校历/公告/试卷这类内容。
/// **教务、成绩、待办等一切个人数据都不经过这里。**
/// 所有方法失败都返回 null 或 false，调用方据此走缓存或内置兜底。
class ControlService {
  ControlService._();

  static bool _registering = false;
  static DateTime? _lastWarmUp;

  /// 冷启动/回前台预热：设备登记 → 必要时断言登录 → 版本探测。
  ///
  /// 未登录统一认证时整段空转 —— 一次 DNS 都不会发。
  /// 默认 6 小时内不重复（[force] 可绕过，登录成功后用）。
  static Future<void> warmUp({bool force = false}) async {
    final last = _lastWarmUp;
    if (!force && last != null && DateTime.now().difference(last) < const Duration(hours: 6)) {
      return;
    }
    _lastWarmUp = DateTime.now();

    if (!await ControlApi.allowed()) return;
    final token = await ensureDevice();
    if (token == null) return;

    final cfg = await StorageService.loadUserConfig();
    final studentId = cfg.username.trim();
    if (studentId.isNotEmpty && await DeviceIdentity.loadAccessToken() == null) {
      await loginWithStudentId(studentId);
    }
    await fetchVersions();
  }

  /// 确保设备已登记（带签名），返回设备令牌。
  ///
  /// 幂等：已有令牌直接返回；并发调用只发一次注册请求。
  static Future<String?> ensureDevice() async {
    if (!await ControlApi.allowed()) return null;

    final existing = await DeviceIdentity.loadToken();
    if (existing != null && existing.isNotEmpty) return existing;
    if (_registering) return null;

    _registering = true;
    try {
      final identity = await DeviceIdentity.load();
      final info = await PackageInfo.fromPlatform();
      final createdAt = isoTimestamp();

      final signature = identity.signLines([
        ControlConfig.deviceSignPrefix,
        identity.installationId,
        identity.publicKeyEncoded,
        'android',
        '${info.version}+${info.buildNumber}',
        createdAt,
      ]);

      final res = await ControlApi.postJson(
        ControlConfig.pathDeviceRegister,
        {
          'installation_id': identity.installationId,
          'public_key': identity.publicKeyEncoded,
          'platform': 'android',
          'app_version': '${info.version}+${info.buildNumber}',
          'created_at': createdAt,
          'signature': signature,
        },
        withDeviceToken: false,
      );
      final token = res?['token']?.toString();
      if (token == null || token.isEmpty) return null;
      await DeviceIdentity.saveToken(token);
      final serial = res?['device_serial']?.toString();
      if (serial != null) await DeviceIdentity.saveSerial(serial);
      return token;
    } finally {
      _registering = false;
    }
  }

  /// 断言登录：拿一次性挑战 → 用设备私钥签名 → 换会话令牌。
  ///
  /// 只在完成本机统一认证登录后调用；学号会先转成伪名再上传。
  static Future<bool> loginWithStudentId(
    String studentId, {
    String displayName = '',
  }) async {
    if (studentId.trim().isEmpty) return false;
    final deviceToken = await ensureDevice();
    if (deviceToken == null) return false;

    final challengeRes = await ControlApi.postJson(
      ControlConfig.pathChallenges,
      const {},
    );
    final challengeId = challengeRes?['challenge_id']?.toString() ?? '';
    final challenge = challengeRes?['challenge']?.toString() ?? '';
    if (challengeId.isEmpty || challenge.isEmpty) return false;

    final identity = await DeviceIdentity.load();
    final serial = await DeviceIdentity.loadSerial() ?? '';
    if (serial.isEmpty) return false;

    final alias = DeviceIdentity.studentAlias(studentId);
    final assertedAt = isoTimestamp();
    final signature = identity.signLines([
      ControlConfig.loginSignPrefix,
      challengeId,
      challenge,
      serial,
      studentId,
      alias,
      displayName,
      assertedAt,
    ]);

    final res = await ControlApi.postJson(
      ControlConfig.pathAssertions,
      {
        'challenge_id': challengeId,
        'challenge': challenge,
        'device_serial': serial,
        'student_id': studentId,
        'student_alias': alias,
        'display_name': displayName,
        'asserted_at': assertedAt,
        'signature': signature,
      },
    );
    final access = res?['access_token']?.toString();
    final refresh = res?['refresh_token']?.toString();
    if (access == null || refresh == null) return false;
    await DeviceIdentity.saveSession(access, refresh);
    return true;
  }

  /// 用 refresh token 换新的一对令牌（服务端会轮换旧的）。
  static Future<bool> refreshSession() async {
    final refresh = await DeviceIdentity.loadRefreshToken();
    if (refresh == null || refresh.isEmpty) return false;
    final res = await ControlApi.postJson(
      ControlConfig.pathRefresh,
      {'refresh_token': refresh},
    );
    final access = res?['access_token']?.toString();
    final next = res?['refresh_token']?.toString();
    if (access == null || next == null) return false;
    await DeviceIdentity.saveSession(access, next);
    return true;
  }

  /// 退出本机账号时调用：撤销服务端会话并清本地令牌。
  static Future<void> logout() async {
    if (await DeviceIdentity.loadToken() != null) {
      await ControlApi.postJson(ControlConfig.pathRevoke, const {});
    }
    await DeviceIdentity.clearSession();
  }

  /// 版本探测：只返回各类内容的版本号。
  static Future<Map<String, String>?> fetchVersions() async {
    await ensureDevice();
    final res = await ControlApi.getJson(ControlConfig.pathConfigVersions);
    if (res == null) return null;
    return res.map((key, value) => MapEntry(key, value?.toString() ?? ''));
  }

  /// 最新版本信息（公开接口，未登录也能查）。
  static Future<Map<String, dynamic>?> fetchAppRelease() {
    return ControlApi.getJson(
      ControlConfig.pathAppRelease,
      withDeviceToken: false,
      requireLogin: false,
    );
  }

  /// 提交匿名反馈。
  static Future<bool> submitFeedback(
    String content, {
    String contact = '',
  }) async {
    final text = content.trim();
    if (text.isEmpty) return false;
    final info = await PackageInfo.fromPlatform();
    final res = await ControlApi.postJson(
      ControlConfig.pathFeedback,
      {
        'content': text,
        'contact': contact.trim(),
        'app_version': '${info.version}+${info.buildNumber}',
      },
      withDeviceToken: false,
      requireLogin: false,
    );
    return res?['ok'] == true;
  }

  /// 公告 / 消息列表。
  static Future<List<dynamic>?> fetchMessages() async {
    await ensureDevice();
    final res = await ControlApi.getJson(ControlConfig.pathMessages);
    final items = res?['items'];
    return items is List ? items : null;
  }

  /// 校历数据（学期日历 + 假期 + 周次）。公开接口，未登录也可读取。
  static Future<Map<String, dynamic>?> fetchSchoolCalendar() async {
    final res = await ControlApi.getJson(
      ControlConfig.pathSchoolCalendar,
      requireLogin: false,
    );
    return res?['calendar'] is Map<String, dynamic>
        ? res!['calendar'] as Map<String, dynamic>
        : res;
  }

  /// 试卷库目录。
  static Future<List<dynamic>?> fetchExamPaperFolders() async {
    await ensureDevice();
    final res = await ControlApi.getJson(ControlConfig.pathExamPapers);
    final items = res?['items'];
    return items is List ? items : null;
  }

  /// 资源列表请求：保留状态码与网络错误类型，供缓存/离线提示使用。
  static Future<ResourceFetchResult> fetchResourcesResult() async {
    if (!ControlConfig.enabled) {
      return const ResourceFetchResult(
        failure: ControlFailure(
            ControlFailureKind.unknown, '资源服务未启用'),
      );
    }
    final uri = Uri.parse('${ControlConfig.baseUrl}${ControlConfig.pathResources}');
    try {
      final response = await http
          .get(uri)
          .timeout(Duration(seconds: ControlConfig.timeoutSeconds));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        String message = '资源同步失败（HTTP ${response.statusCode}）';
        try {
          final decoded = jsonDecode(utf8.decode(response.bodyBytes));
          if (decoded is Map && decoded['error'] is Map) {
            final m = decoded['error']['message'];
            if (m != null && m.toString().isNotEmpty) message = m.toString();
          }
        } catch (_) {}
        return ResourceFetchResult(
          failure: _failureForStatus(response.statusCode, message),
        );
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        return const ResourceFetchResult(
          failure: ControlFailure(
              ControlFailureKind.unknown, '资源数据格式异常'),
        );
      }
      return ResourceFetchResult(data: decoded, syncedAt: isoTimestamp());
    } on TimeoutException {
      return const ResourceFetchResult(
        failure: ControlFailure(
            ControlFailureKind.timeout, '资源同步超时，请稍后重试'),
      );
    } on SocketException {
      return const ResourceFetchResult(
        failure: ControlFailure(
            ControlFailureKind.offline, '当前无网络，显示上次同步内容'),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[control] 资源同步失败：$e');
      return const ResourceFetchResult(
        failure: ControlFailure(
            ControlFailureKind.unknown, '资源同步失败，请稍后重试'),
      );
    }
  }

  /// 上传资源到控制台审核。返回 null 表示成功，返回字符串表示失败原因。
  ///
  /// [paperFiles] 教材 PDF 或试卷；[answerFiles] 只用于试卷的随卷答案。
  /// 一次提交总大小不得超过 80MB。
  static Future<String?> uploadResource({
    required String courseName,
    required String bookName,
    required String area,
    String note = '',
    String contributor = '',
    required List<PlatformFile> paperFiles,
    List<PlatformFile> answerFiles = const [],
    void Function(int sent, int total, int fileIndex, int totalFiles)?
        onProgress,
  }) async {
    final allFiles = [...paperFiles, ...answerFiles];
    if (allFiles.isEmpty) return '请选择文件';
    http.Client? uploadClient;
    const maxTotal = 80 * 1024 * 1024;
    final totalSize = allFiles.fold<int>(0, (sum, f) => sum + f.size);
    if (totalSize > maxTotal) {
      return '文件总大小 ${(totalSize / 1024 / 1024).toStringAsFixed(1)}MB，'
          '超过 80MB 上限';
    }
    try {
      if (!await ControlApi.allowed()) return '未登录统一认证，无法上传';
      final token = await DeviceIdentity.loadToken();
      if (token == null || token.isEmpty) return '设备未登录，无法上传';

      final uri = Uri.parse(
          '${ControlConfig.baseUrl}${ControlConfig.pathResourceUploads}');
      final request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Device $token'
        ..fields['course_name'] = courseName.trim()
        ..fields['book_name'] = bookName.trim()
        ..fields['area'] = area
        ..fields['note'] = note.trim()
        ..fields['contributor'] = contributor.trim();

      Future<void> addFile(String field, PlatformFile file) async {
        final path = file.path;
        if (path == null || path.isEmpty) return;
        request.files.add(
          await http.MultipartFile.fromPath(field, path, filename: file.name),
        );
      }

      for (final file in paperFiles) {
        await addFile('files', file);
      }
      for (final file in answerFiles) {
        await addFile('answer_files', file);
      }
      if (request.files.isEmpty) return '没有可上传的文件';

      final byteStream = request.finalize();
      final total = request.contentLength;
      final streamed = http.StreamedRequest('POST', uri);
      streamed.headers.addAll(request.headers);
      streamed.contentLength = total;

      final sizes = allFiles.map((f) => f.size).toList();
      final cumulative = <int>[];
      var running = 0;
      for (final size in sizes) {
        running += size;
        cumulative.add(running);
      }
      var sent = 0;
      var lastIndex = 0;
      byteStream.listen(
        (chunk) {
          sent += chunk.length;
          while (lastIndex < cumulative.length - 1 &&
              sent > cumulative[lastIndex]) {
            lastIndex++;
          }
          onProgress?.call(
            sent,
            total,
            (lastIndex + 1).clamp(1, allFiles.length),
            allFiles.length,
          );
          streamed.sink.add(chunk);
        },
        onDone: streamed.sink.close,
        onError: streamed.sink.addError,
      );

      final client = uploadClient = http.Client();
      final response = await client
          .send(streamed)
          .timeout(const Duration(seconds: 300));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (kDebugMode) {
          debugPrint('[control] 资源上传失败：HTTP ${response.statusCode}');
        }
        try {
          final body = await response.stream.bytesToString();
          final decoded = jsonDecode(body);
          if (decoded is Map) {
            final error = decoded['error'];
            if (error is Map && (error['message'] ?? '').toString().isNotEmpty) {
              return error['message'].toString();
            }
          }
        } catch (_) {}
        return '上传失败（HTTP ${response.statusCode}）';
      }
      onProgress?.call(total, total, allFiles.length, allFiles.length);
      try {
        final body = await response.stream.bytesToString();
        final decoded = jsonDecode(body);
        if (decoded is Map && decoded['ok'] == true) {
          return null;
        }
      } catch (_) {}
      return '上传失败，服务未返回成功状态';
    } on TimeoutException {
      return '上传超时，已保留文件，可重试';
    } on SocketException {
      return '当前无网络，已保留文件，联网后可重试';
    } catch (e) {
      if (kDebugMode) debugPrint('[control] 资源上传异常：$e');
      return '上传失败，请检查网络后重试';
    } finally {
      uploadClient?.close();
    }
  }

  /// 我的上传记录与贡献/下载统计。
  static Future<Map<String, dynamic>?> fetchMyUploads() async {
    await ensureDevice();
    return ControlApi.getJson('/api/v1/resource-uploads/mine');
  }

  /// 下载审核通过的资源到本机路径。返回 null 表示成功。
  ///
  /// [preview] = true 时用于阅读缓存，不占每日下载额度；保存到本机才计数。
  static Future<ControlFailure?> downloadResourceFile({
    required int fileId,
    required String targetPath,
    bool preview = false,
    void Function(int received, int total)? onProgress,
  }) async {
    if (!ControlConfig.enabled) {
      return const ControlFailure(
          ControlFailureKind.unknown, '资源服务未启用');
    }
    final token = await ensureDevice();
    if (token == null || token.isEmpty) {
      return const ControlFailure(
          ControlFailureKind.unauthorized, '请先登录统一认证后再下载');
    }
    final uri = Uri.parse(
        '${ControlConfig.baseUrl}/api/v1/resources/files/$fileId'
        '?mode=${preview ? 'preview' : 'download'}');
    final request = http.Request('GET', uri)
      ..headers['Authorization'] = 'Device $token';
    final client = http.Client();
    IOSink? sink;
    try {
      final response = await client
          .send(request)
          .timeout(Duration(seconds: ControlConfig.timeoutSeconds));
      if (response.statusCode != 200) {
        String message = '下载失败（HTTP ${response.statusCode}）';
        try {
          final body = await response.stream.bytesToString();
          final decoded = jsonDecode(body);
          if (decoded is Map && decoded['error'] is Map) {
            final m = decoded['error']['message'];
            if (m != null && m.toString().isNotEmpty) message = m.toString();
          }
        } catch (_) {}
        return _failureForStatus(response.statusCode, message);
      }
      final total = response.contentLength ?? 0;
      final file = File(targetPath);
      await file.parent.create(recursive: true);
      sink = file.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      return null;
    } on TimeoutException {
      return const ControlFailure(
          ControlFailureKind.timeout, '下载超时，请检查网络后重试');
    } on SocketException {
      return const ControlFailure(
          ControlFailureKind.offline, '当前无网络，无法下载');
    } catch (e) {
      if (kDebugMode) debugPrint('[control] 资源下载异常：$e');
      return const ControlFailure(
          ControlFailureKind.unknown, '下载失败，请稍后重试');
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close();
    }
  }

  /// 健康检查（调试用；正常流程不调用）。
  static Future<bool> ping() async {
    final res = await ControlApi.getJson(ControlConfig.pathHealth);
    return res != null;
  }

  /// 带时区偏移的 ISO 时间串（服务端要求签名时间在 ±5 分钟内）。
  static String isoTimestamp() {
    final now = DateTime.now();
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year.toString().padLeft(4, '0')}-${two(now.month)}-${two(now.day)}'
        'T${two(now.hour)}:${two(now.minute)}:${two(now.second)}'
        '$sign${two(abs.inHours)}:${two(abs.inMinutes % 60)}';
  }
}
