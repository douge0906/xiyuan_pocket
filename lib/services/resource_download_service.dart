import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'cancel_token.dart';
import 'control_service.dart';
import 'resource_store.dart';

class DownloadedResource {
  const DownloadedResource({
    required this.fileId,
    required this.uploadId,
    required this.courseName,
    required this.name,
    required this.path,
    required this.kind,
    required this.size,
    required this.savedAt,
  });

  final int fileId;
  final int uploadId;
  final String courseName;
  final String name;
  final String path;
  final ResourceKind kind;
  final int size;
  final String savedAt;

  ResourceEntry get entry => ResourceEntry(
        name: name,
        kind: kind,
        fileId: fileId,
        uploadId: uploadId,
        size: size,
      );

  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'uploadId': uploadId,
        'courseName': courseName,
        'name': name,
        'path': path,
        'kind': kind.code,
        'size': size,
        'savedAt': savedAt,
      };

  static DownloadedResource? fromJson(Map<String, dynamic> json) {
    final path = (json['path'] ?? '').toString();
    final name = (json['name'] ?? '').toString();
    final kind = ResourceKind.tryFromCode((json['kind'] ?? '').toString());
    if (path.isEmpty || name.isEmpty || kind == null) return null;
    return DownloadedResource(
      fileId: (json['fileId'] as num?)?.toInt() ?? 0,
      uploadId: (json['uploadId'] as num?)?.toInt() ?? 0,
      courseName: (json['courseName'] ?? '').toString(),
      name: name,
      path: path,
      kind: kind,
      size: (json['size'] as num?)?.toInt() ?? 0,
      savedAt: (json['savedAt'] ?? '').toString(),
    );
  }
}

/// 资源下载与缓存：预览走 cache，用户下载走文档目录。
/// 阅读器优先复用已下载到文档目录的文件，离线也能打开。
class ResourceDownloadService {
  ResourceDownloadService._();

  static String safeName(String name) =>
      name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  static Future<String> cachePath(ResourceEntry entry) async {
    final root = await getApplicationCacheDirectory();
    return '${root.path}/resources/${entry.fileId}/${safeName(entry.name)}';
  }

  static Future<String> savedPath(
      ResourceEntry entry, String courseName) async {
    final root = await getApplicationDocumentsDirectory();
    return '${root.path}/resource_center/${safeName(courseName)}/'
        '${safeName(entry.name)}';
  }

  static Future<String> documentPath(
      ResourceEntry entry, String courseName) async {
    final path = await savedPath(entry, courseName);
    final dir = File(path).parent;
    if (!await dir.exists()) await dir.create(recursive: true);
    return path;
  }

  /// 阅读前找本地文件：文档目录优先，其次预览缓存。
  static Future<String?> findLocal(
      ResourceEntry entry, String courseName) async {
    if (entry.fileId <= 0) return null;
    for (final path in [
      await savedPath(entry, courseName),
      await cachePath(entry),
    ]) {
      final file = File(path);
      if (await file.exists() && await file.length() > 0) return path;
    }
    return null;
  }

  /// 确保预览文件存在。返回本地路径，失败抛 ControlFailure。
  static Future<String> ensureCached(
    ResourceEntry entry,
    String courseName, {
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    if (entry.fileId <= 0) {
      throw Exception('这份资源缺少文件编号');
    }
    final local = await findLocal(entry, courseName);
    if (local != null) return local;

    final path = await cachePath(entry);
    final temp = File('$path.part');
    final error = await ControlService.downloadResourceFile(
      fileId: entry.fileId,
      targetPath: temp.path,
      preview: true,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
    if (error != null) {
      if (await temp.exists()) await temp.delete();
      throw error;
    }
    if (await File(path).exists()) await File(path).delete();
    await temp.rename(path);
    return path;
  }

  /// 本机已下载资源的清单（用于“我的下载”）。
  static Future<String> _manifestPath() async {
    final root = await getApplicationDocumentsDirectory();
    return '${root.path}/resource_center/.downloads.json';
  }

  static Future<List<DownloadedResource>> listDownloads() async {
    final manifest = File(await _manifestPath());
    if (!await manifest.exists()) return const [];
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! List) return const [];
      final items = <DownloadedResource>[];
      for (final raw in decoded) {
        if (raw is! Map) continue;
        final item = DownloadedResource.fromJson(
            Map<String, dynamic>.from(raw));
        if (item == null) continue;
        final file = File(item.path);
        if (await file.exists() && await file.length() > 0) {
          items.add(item);
        }
      }
      items.sort((a, b) => b.savedAt.compareTo(a.savedAt));
      return items;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _recordDownload(
    ResourceEntry entry,
    String courseName,
    String path,
  ) async {
    final manifest = File(await _manifestPath());
    await manifest.parent.create(recursive: true);
    final existing = await listDownloads();
    final cleaned = existing.where((e) => e.path != path).toList();
    cleaned.insert(
      0,
      DownloadedResource(
        fileId: entry.fileId,
        uploadId: entry.uploadId,
        courseName: courseName,
        name: entry.name,
        path: path,
        kind: entry.kind,
        size: await File(path).length(),
        savedAt: DateTime.now().toIso8601String(),
      ),
    );
    await manifest.writeAsString(
        jsonEncode(cleaned.map((e) => e.toJson()).toList()));
  }

  static Future<void> deleteDownload(DownloadedResource item) async {
    final file = File(item.path);
    if (await file.exists()) await file.delete();
    final manifest = File(await _manifestPath());
    if (await manifest.exists()) {
      final remaining =
          (await listDownloads()).where((e) => e.path != item.path).toList();
      await manifest.writeAsString(
          jsonEncode(remaining.map((e) => e.toJson()).toList()));
    }
  }

  /// 保存到 App 文档目录，返回保存路径。
  static Future<String> saveToDocuments(
    ResourceEntry entry,
    String courseName, {
    bool force = false,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    final path = await documentPath(entry, courseName);
    final existing = File(path);
    if (!force && await existing.exists() && await existing.length() > 0) {
      await _recordDownload(entry, courseName, path);
      return path;
    }

    final temp = File('$path.part');
    final error = await ControlService.downloadResourceFile(
      fileId: entry.fileId,
      targetPath: temp.path,
      preview: false,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
    if (error != null) {
      if (await temp.exists()) await temp.delete();
      throw error;
    }
    if (await existing.exists()) await existing.delete();
    await temp.rename(path);
    await _recordDownload(entry, courseName, path);
    return path;
  }
}
