import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/course_table.dart';
import 'course_storage.dart';

/// 课表方案导出 / 导入。
///
/// 文件格式刻意做成独立于本地存储的稳定结构：
/// ```json
/// {
///   "schema": "xiyuan.course.tables",
///   "version": 1,
///   "exportedAt": "2026-10-28T20:00:00",
///   "activeId": "t_xxx",
///   "tables": [CourseTable.toJson(), ...]
/// }
/// ```
/// 导入走 [CourseStorage.createTable]，因此会自动复用空占位课表、
/// 生成新 id，不覆盖本机已有课表。
class CourseTransferService {
  CourseTransferService._();

  static const String schema = 'xiyuan.course.tables';
  static const int formatVersion = 1;
  static const int maxTables = 20;
  static const int maxCourses = 2000;

  static Future<int> exportTables() async {
    final tables = await CourseStorage.loadTables();
    if (tables.isEmpty) throw const CourseTransferException('本机还没有课表');
    final activeId = await CourseStorage.activeTableId();

    final payload = <String, dynamic>{
      'schema': schema,
      'version': formatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'activeId': activeId,
      'tables': tables.map((t) => t.toJson()).toList(),
    };

    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(':', '')
        .replaceAll('-', '');
    final file = File('${dir.path}/xiyuan_course_tables_$stamp.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      encoding: utf8,
    );

    await Share.shareXFiles(
      [XFile(file.path)],
      text: '掌上锡院 · 课程表方案',
    );
    return tables.length;
  }

  static Future<int> importTables() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return 0;

    final pickedFile = picked.files.single;
    final bytes = pickedFile.bytes ??
        (pickedFile.path == null
            ? null
            : await File(pickedFile.path!).readAsBytes());
    if (bytes == null) throw const CourseTransferException('无法读取文件');

    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw const CourseTransferException('文件不是有效的 JSON');
    }
    if (decoded is! Map) throw const CourseTransferException('文件结构不正确');

    final map = Map<String, dynamic>.from(decoded);
    if (map['schema'] != schema) {
      throw const CourseTransferException('不是掌上锡院的课表方案文件');
    }
    final version = (map['version'] as num?)?.toInt() ?? 0;
    if (version != formatVersion) {
      throw CourseTransferException('方案版本不支持：$version');
    }

    final rawTables = map['tables'];
    if (rawTables is! List || rawTables.isEmpty) {
      throw const CourseTransferException('方案里没有课表');
    }
    if (rawTables.length > maxTables) {
      throw const CourseTransferException('课表数量超过上限');
    }

    final tables = <CourseTable>[];
    var courseCount = 0;
    for (final raw in rawTables) {
      final table = CourseTable.fromJson(raw);
      if (table == null) continue;
      courseCount += table.courses.length;
      if (courseCount > maxCourses) {
        throw const CourseTransferException('课程数量超过上限');
      }
      tables.add(table);
    }
    if (tables.isEmpty) throw const CourseTransferException('没有可导入的课表');

    final idMap = <String, String>{};
    for (final table in tables) {
      final newId = await CourseStorage.createTable(
        name: table.name,
        courses: table.courses,
        semesterStart: table.semesterStart,
        semesterStartSource: table.semesterStartSource,
        kind: table.kind,
      );
      idMap[table.id] = newId;
    }

    final wanted = (map['activeId'] ?? '').toString();
    final mapped = idMap[wanted];
    if (mapped != null) {
      await CourseStorage.switchTable(mapped);
    }
    if (kDebugMode) {
      debugPrint('[course transfer] imported ${tables.length} tables');
    }
    return tables.length;
  }
}

class CourseTransferException implements Exception {
  const CourseTransferException(this.message);
  final String message;

  @override
  String toString() => message;
}
