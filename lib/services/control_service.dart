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

    if (!await ControlApi.allowed()) return;
    final token = await ensureDevice();
    if (token == null) return;
    // 🔴 v1.0.9：时间戳必须**成功之后**才写。
    //    此前写在请求之前 → 第一次因断网失败，就把预热冻结满 6 小时，
    //    冷启动与回前台全部被跳过，只有「登录成功」那条 force 路径能救。
    _lastWarmUp = DateTime.now();

    final cfg = await StorageService.loadUserConfig();
    final studentId = cfg.username.trim();
    if (studentId.isNotEmpty && await DeviceIdentity.loadAccessToken() == null) {
      await loginWithStudentId(studentId);
    }
    await fetchVersions();
  }

  /// 确保设备已登记（带签名），返回设备令牌。
  ///
  /// 幂等：已有令牌直接返回；并发调用**共享同一次注册 Future**。
  ///
  /// 🔴 v1.0.9：此前用 `_registering` 布尔 + `return null` 做并发闸门 ——
  ///    注释写着「并发调用只发一次注册请求」，实际是第二个调用者**立刻拿到 null**，
  ///    上层把它翻译成「请先登录统一认证后再下载」，已登录用户也会被这么提示。
  ///    现在改成共享 Future（与 `net_mode.dart` 的 `_inflight` 同一套写法）。
  static Future<String?>? _registering;

  static Future<String?> ensureDevice() {
    _registering ??= _ensureDeviceOnce().whenComplete(() {
      // 失败不缓存：下次调用重新尝试（成功时 token 已落盘，会走上面的短路）。
      _registering = null;
    });
    return _registering!;
  }

  static Future<String?> _ensureDeviceOnce() async {
    if (!await ControlApi.allowed()) return null;

    final existing = await DeviceIdentity.loadToken();
    if (existing != null && existing.isNotEmpty) return existing;

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
    } catch (_) {
      // 注册失败保持静默：这是后台预热路径，不该弹任何提示。
      return null;
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
      // 🔴 v1.0.9：必须走 ensureDevice() 而不是直读本地 token。
      //    直读时新装设备/首次上传的 token 还没注册过（warmUp 是 unawaited），
      //    必然报「设备未登录，无法上传」——服务端注册链路根本没被触发。
      final token = await ensureDevice();
      if (token == null || token.isEmpty) {
        return '设备注册失败，请检查网络后重试';
      }

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
      // 🔴 v1.0.9：流本身也要超时。此前只有 `client.send` 那一次有 12 秒超时，
      //    响应头到达后如果服务端卡住不发字节，`await for` 会永远挂着 ——
      //    而上层的「正在保存」对话框 `barrierDismissible: false`，
      //    用户只能杀进程。这里给每一块数据之间也加超时（不限制总时长，
      //    大文件仍然可以慢慢下完）。
      await for (final chunk in response.stream.timeout(
        Duration(seconds: ControlConfig.timeoutSeconds),
        onTimeout: (sinkStream) => sinkStream.addError(
          TimeoutException('下载数据流中断'),
        ),
      )) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      // 🔴 2026-11-04 审查 P1：此前「流正常结束」就当成成功，从不和
      //    Content-Length 对账。服务端用 FileResponse 一次性 sendfile，
      //    中途被掐（切网、锁屏、nginx 超时）时 Dart 侧常常是 stream 正常
      //    done 而不是抛错 → 这里返回 null（成功）→ 上层把 .part rename 成
      //    正式文件 → 缓存判定只认「文件非空」，于是一个截断的坏 PDF 会被
      //    **永久命中**：预览一直是坏文件，「保存到本机」连请求都不发就弹
      //    「已保存到…」。必须在这里发现并拒绝。
      if (total > 0 && received != total) {
        if (kDebugMode) {
          debugPrint('[control] 下载不完整：收到 $received / 应为 $total');
        }
        return const ControlFailure(
            ControlFailureKind.server, '下载不完整，请重试');
      }
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
