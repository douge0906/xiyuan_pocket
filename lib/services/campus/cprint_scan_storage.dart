import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 一条「已下载到本机」的扫描件记录。
///
/// 只存定位文件所需的字段 —— 列表本身仍以服务端 [CprintScanItem] 为准，
/// 这份索引只回答一个问题：**这个 dwJobId 在本机有没有文件、在哪。**
class CprintLocalFile {
  const CprintLocalFile({
    required this.jobId,
    required this.displayName,
    required this.path,
    required this.size,
    required this.savedAt,
  });

  final String jobId;
  final String displayName;
  final String path;
  final int size;
  final String savedAt;

  Map<String, dynamic> toJson() => {
        'jobId': jobId,
        'displayName': displayName,
        'path': path,
        'size': size,
        'savedAt': savedAt,
      };

  static CprintLocalFile? fromJson(Map<String, dynamic> json) {
    final jobId = (json['jobId'] ?? '').toString();
    final path = (json['path'] ?? '').toString();
    final name = (json['displayName'] ?? '').toString();
    if (jobId.isEmpty || path.isEmpty || name.isEmpty) return null;
    return CprintLocalFile(
      jobId: jobId,
      displayName: name,
      path: path,
      size: (json['size'] as num?)?.toInt() ?? 0,
      savedAt: (json['savedAt'] ?? '').toString(),
    );
  }
}

/// 云打印扫描件的本机文件索引。
///
/// 落盘位置：`<文档目录>/cprint_scan/<dwJobId>-<文件名>`。
/// App 没有任何存储权限，也不写公共 Download 目录 —— 用户要拿出去只能走
/// 系统分享面板（见 `cprint_scan_downloader.dart`）。
class CprintScanStorage {
  CprintScanStorage._();

  static Future<Directory> dir() async {
    final root = await getApplicationDocumentsDirectory();
    final d = Directory('${root.path}/cprint_scan');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<File> _manifest() async {
    final d = await dir();
    return File('${d.path}/.index.json');
  }

  /// 文件名：`<jobId>-<安全文件名>`。
  ///
  /// 带 jobId 前缀是为了同一份扫描件改名后不会覆盖旧文件，也不会因为
  /// 两个文件同名而互相踩掉。
  static Future<String> targetPath(String jobId, String safeName) async {
    final d = await dir();
    return '${d.path}/$jobId-$safeName';
  }

  static Future<List<CprintLocalFile>> list() async {
    final manifest = await _manifest();
    if (!await manifest.exists()) return const [];
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! List) return const [];
      final items = <CprintLocalFile>[];
      for (final raw in decoded) {
        if (raw is! Map) continue;
        final item = CprintLocalFile.fromJson(Map<String, dynamic>.from(raw));
        if (item == null) continue;
        final f = File(item.path);
        // 盘上文件被清理掉的条目直接丢弃，避免「列表说有、点开没有」。
        if (await f.exists() && await f.length() > 0) items.add(item);
      }
      items.sort((a, b) => b.savedAt.compareTo(a.savedAt));
      return items;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _write(List<CprintLocalFile> items) async {
    final manifest = await _manifest();
    await manifest.parent.create(recursive: true);
    await manifest.writeAsString(
        jsonEncode(items.map((e) => e.toJson()).toList()));
  }

  /// 按 jobId 查本机是否已有文件（用来在列表上显示「已下载」）。
  static Future<Map<String, CprintLocalFile>> byJobId() async {
    final map = <String, CprintLocalFile>{};
    for (final item in await list()) {
      map[item.jobId] = item;
    }
    return map;
  }

  static Future<void> record({
    required String jobId,
    required String displayName,
    required String path,
  }) async {
    final existing = await list();
    final cleaned = existing.where((e) => e.jobId != jobId).toList();
    final size = await File(path).length();
    cleaned.insert(
      0,
      CprintLocalFile(
        jobId: jobId,
        displayName: displayName,
        path: path,
        size: size,
        savedAt: DateTime.now().toIso8601String(),
      ),
    );
    await _write(cleaned);
  }

  /// 删除本机文件并从索引里摘掉（只影响本机，不影响服务器上的扫描件）。
  static Future<void> remove(String jobId) async {
    final existing = await list();
    for (final item in existing.where((e) => e.jobId == jobId)) {
      final f = File(item.path);
      if (await f.exists()) await f.delete();
    }
    await _write(existing.where((e) => e.jobId != jobId).toList());
  }

  /// 按当前列表清理孤儿文件：服务器上已删除/过期的扫描件，本机文件保留，
  /// 但不占索引；索引里 path 已不存在的条目在 [list] 里已被丢弃。
  static Future<void> pruneIndex() async {
    await _write(await list());
  }

  /// 退出登录时清空（文件也删）。
  static Future<void> clear() async {
    final d = await dir();
    if (await d.exists()) {
      await d.delete(recursive: true);
    }
  }
}
