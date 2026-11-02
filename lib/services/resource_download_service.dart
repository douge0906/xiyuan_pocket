import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'control_service.dart';
import 'resource_store.dart';

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

  /// 保存到 App 文档目录，返回保存路径。
  static Future<String> saveToDocuments(
    ResourceEntry entry,
    String courseName, {
    void Function(int received, int total)? onProgress,
  }) async {
    final path = await documentPath(entry, courseName);
    final existing = File(path);
    if (await existing.exists() && await existing.length() > 0) return path;

    final temp = File('$path.part');
    final error = await ControlService.downloadResourceFile(
      fileId: entry.fileId,
      targetPath: temp.path,
      preview: false,
      onProgress: onProgress,
    );
    if (error != null) {
      if (await temp.exists()) await temp.delete();
      throw error;
    }
    if (await existing.exists()) await existing.delete();
    await temp.rename(path);
    return path;
  }
}
