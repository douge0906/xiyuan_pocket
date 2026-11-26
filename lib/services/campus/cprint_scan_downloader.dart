import 'dart:io';

import '../cancel_token.dart';
import 'campus_session.dart';
import 'cprint_client.dart';
import 'jwgl_client.dart' show CampusException;
import 'cprint_models.dart';
import 'cprint_scan_storage.dart';

/// 下载失败的原因，界面按 [message] 直接显示。
class CprintDownloadFailure implements Exception {
  const CprintDownloadFailure(this.message, {this.needReauth = false});

  final String message;
  final bool needReauth;

  @override
  String toString() => message;
}

/// 下载云打印扫描件到本机。
///
/// 与资源中心的下载不同，这里没有 CDN、没有配额，就是**一个 GET 直接吐字节**。
/// 但有两个坑必须处理：
///  1. `Scan/Download` 失败时**不返回 302 也不返回非 2xx**，而是 200 +
///     `Content-Type: text/plain` + `Error,下载失败，请重试`。所以判据是
///     content-type 和首字节，不是 statusCode。
///  2. PDF / JPEG 不能走 `CampusResponse.body`（那是
///     `utf8.decode(allowMalformed: true)`，坏字节会被替换成 U+FFFD），
///     必须用 `getBytes`。
class CprintScanDownloader {
  CprintScanDownloader._();

  static const int _errorHeadLimit = 200;

  /// 下载并保存。返回保存后的本地路径。
  ///
  /// 失败抛 [CprintDownloadFailure]；用户取消也抛这个，[message] 为「已取消下载」。
  static Future<String> download(
    CprintScanItem item, {
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    if (item.jobId.isEmpty) {
      throw const CprintDownloadFailure('这份扫描件缺少文件编号，无法下载');
    }
    if (item.isExpired) {
      throw const CprintDownloadFailure('该文件已过期，不可下载');
    }
    final session = CprintClient.session;
    if (session == null) {
      throw const CprintDownloadFailure('登录状态已失效，请重新授权', needReauth: true);
    }

    // 已经有就不重复下载 —— 服务端文件不会变，重下一遍只是浪费流量。
    final existing = (await CprintScanStorage.byJobId())[item.jobId];
    if (existing != null) {
      final f = File(existing.path);
      if (await f.exists() && await f.length() > 0) {
        onProgress?.call(existing.size, existing.size);
        return existing.path;
      }
      await CprintScanStorage.remove(item.jobId);
    }

    onProgress?.call(0, item.fileSize);
    final CampusBytesResponse res;
    try {
      res = await session.getBytes(
        '${CprintClient.host}/api/client/Scan/Download'
        '?dwJobId=${Uri.encodeQueryComponent(item.jobId)}',
      );
    } on CampusException catch (e) {
      throw CprintDownloadFailure(e.message, needReauth: e.needRelogin);
    } catch (e) {
      throw CprintDownloadFailure('下载失败：$e');
    }
    if (cancelToken?.isCancelled == true) {
      throw const CprintDownloadFailure('已取消下载');
    }

    // ① 200 + text/plain + `Error,…` = 站点自己给的失败文案
    final ct = (res.contentType ?? '').toLowerCase();
    if (ct.contains('text/plain') || ct.contains('application/json')) {
      final text = res.headText.trim();
      if (text.startsWith('Error') || text.startsWith('{')) {
        final body = String.fromCharCodes(res.bytes.take(_errorHeadLimit));
        final msg = _extractError(body);
        throw CprintDownloadFailure(
          msg.isEmpty ? '下载失败，请稍后重试' : msg,
          needReauth: body.contains('"code":4') || body.contains('"code": 4'),
        );
      }
    }
    if (!res.ok) {
      throw CprintDownloadFailure('下载失败（HTTP ${res.statusCode}）');
    }
    if (res.bytes.isEmpty) {
      throw const CprintDownloadFailure('下载到的文件是空的，请稍后重试');
    }

    final path =
        await CprintScanStorage.targetPath(item.jobId, item.safeFileName);
    final file = File(path);
    final temp = File('$path.part');
    try {
      await temp.parent.create(recursive: true);
      final sink = temp.openWrite();
      try {
        sink.add(res.bytes);
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (cancelToken?.isCancelled == true) {
        if (await temp.exists()) await temp.delete();
        throw const CprintDownloadFailure('已取消下载');
      }
      if (await file.exists()) await file.delete();
      await temp.rename(path);
    } catch (e) {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } catch (_) {}
      }
      if (e is CprintDownloadFailure) rethrow;
      throw CprintDownloadFailure('保存文件失败：$e');
    }

    await CprintScanStorage.record(
      jobId: item.jobId,
      displayName: item.displayName,
      path: path,
    );
    onProgress?.call(res.bytes.length, res.bytes.length);
    return path;
  }

  /// 从站点返回的纯文本/JSON 里抠出给人看的那一句。
  static String _extractError(String body) {
    final t = body.trim();
    if (t.startsWith('Error,')) {
      return t.substring(6).trim();
    }
    final m = RegExp(r'"message"\s*:\s*"([^"]*)"').firstMatch(t);
    if (m != null && m.group(1)!.isNotEmpty) return m.group(1)!;
    return '';
  }

  /// 删除本机文件（只删本机，不动服务器上的扫描件）。
  static Future<void> deleteLocal(String jobId) =>
      CprintScanStorage.remove(jobId);
}
