import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/course_table.dart';
import 'course_reminder_service.dart';
import 'course_storage.dart';
import 'widget_sync_service.dart';

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

  /// 「完整方案」的 schema（2026-11-04，用户 m20128 #2）。
  ///
  /// 用户原话：「我的外观方案导出导入和课表方案有点重复。仅保留一个可以
  /// 全量控制各项参数的方案。」——此前是两份文件、两个入口，各带走一半，
  /// 用户换手机要导两次、还容易只导一半。现在合成一份：
  /// 课表（含每张表的学期开学日）+ 当前显示/外观设置 + 已存外观方案。
  /// 读的时候两个 schema 都认，老文件照样能导入。
  static const String bundleSchema = 'xiyuan.full.bundle';

  /// 「仅外观」的 schema（2026-11-04，用户 m20455 #3）。
  ///
  /// 用户原话：「导出方案功能改为导出课表/仅导出外观」——导出侧拆成两路，
  /// 导入侧仍只有一路（三种 schema 全认），不需要用户先判断文件是哪一种。
  static const String appearanceSchema = 'xiyuan.appearance';
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

  /// 导出「完整方案」：课表 + 外观 + 已存外观方案，一个文件全带走。
  static Future<int> exportBundle() async {
    final tables = await CourseStorage.loadTables();
    final activeId = await CourseStorage.activeTableId();
    final display = await CourseStorage.loadDisplaySettings();
    final presets = await CourseStorage.loadAppearancePresets();

    final payload = <String, dynamic>{
      'schema': bundleSchema,
      'version': formatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'activeId': activeId,
      'tables': tables.map((t) => t.toJson()).toList(),
      'appearance': CourseStorage.appearanceOfDisplay(display),
      'appearancePresets': presets,
    };

    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(':', '')
        .replaceAll('-', '');
    final file = File('${dir.path}/xiyuan_bundle_$stamp.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      encoding: utf8,
    );
    await Share.shareXFiles(
      [XFile(file.path)],
      text: '掌上锡院 · 完整方案（课表 + 外观）',
    );
    return tables.length;
  }

  /// 导出「仅外观」：当前显示/外观设置 + 已存外观方案，不含课表。
  ///
  /// 2026-11-04（用户 m20455 #3）：换主题、调完配色想同步到另一台手机时，
  /// 不该连课表一起带走（会覆盖对方已有的课表）。
  static Future<int> exportAppearance() async {
    final display = await CourseStorage.loadDisplaySettings();
    final presets = await CourseStorage.loadAppearancePresets();

    final payload = <String, dynamic>{
      'schema': appearanceSchema,
      'version': formatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'appearance': CourseStorage.appearanceOfDisplay(display),
      'appearancePresets': presets,
    };

    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(':', '')
        .replaceAll('-', '');
    final file = File('${dir.path}/xiyuan_appearance_$stamp.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      encoding: utf8,
    );
    await Share.shareXFiles(
      [XFile(file.path)],
      text: '掌上锡院 · 仅外观方案',
    );
    return payload['appearance'] is Map ? (payload['appearance'] as Map).length : 0;
  }

  /// 导入「完整方案」；也兼容只有课表的旧文件。
  ///
  /// 返回 `(tables: 导入课表数, appearance: 是否带入外观)`。
  static Future<({int tables, bool appearance})> importBundle() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) {
      return (tables: 0, appearance: false);
    }
    final pickedFile = picked.files.first;
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

    final sch = '${map['schema'] ?? ''}';
    if (sch != schema && sch != bundleSchema && sch != appearanceSchema) {
      throw const CourseTransferException('不是掌上锡院的方案文件');
    }
    final version = (map['version'] as num?)?.toInt() ?? 0;
    if (version != formatVersion) {
      throw CourseTransferException('方案版本不支持：$version');
    }

    // ---- 外观（完整方案才有）----
    var appliedAppearance = false;
    final appearance = map['appearance'];
    if (appearance is Map) {
      final patch = Map<String, dynamic>.from(appearance);
      if (patch.isNotEmpty) {
        final display = await CourseStorage.loadDisplaySettings();
        final merged = <String, dynamic>{...display, ...patch};
        // 用户主动导入 = 明确选了这套外观，打上标记防止默认方案覆盖回去
        merged['schemeUserPicked'] = true;
        await CourseStorage.saveDisplaySettings(merged);
        CourseStorage.applyDisplayToCache(merged);
        appliedAppearance = true;
      }
    }
    final presets = map['appearancePresets'];
    if (presets is Map && presets.isNotEmpty) {
      final existing = await CourseStorage.loadAppearancePresets();
      final merged = <String, Map<String, dynamic>>{...existing};
      presets.forEach((k, v) {
        if (v is Map) merged['$k'] = Map<String, dynamic>.from(v);
      });
      await CourseStorage.saveAppearancePresets(merged);
      appliedAppearance = true;
    }

    // ---- 课表 ----
    final rawTables = map['tables'];
    if (rawTables is! List || rawTables.isEmpty) {
      // 2026-11-04（用户 m20455 #3）：只导外观的文件没有 tables —— 这不是错误。
      // 只要前面成功应用了外观就按「仅外观」成功返回。
      if (appliedAppearance) {
        await CourseReminderService.rescheduleAll();
        await WidgetSyncService.syncTodayCourses();
        return (tables: 0, appearance: true);
      }
      throw const CourseTransferException('方案里没有课表，也没有外观');
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
    if (mapped != null) await CourseStorage.switchTable(mapped);

    await CourseReminderService.rescheduleAll();
    await WidgetSyncService.syncTodayCourses();
    return (tables: tables.length, appearance: appliedAppearance);
  }

  static Future<int> importTables() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return 0;

    // 用 `.first` 而不是 `.single`：后端允许一次选中多个文件时，`.single`
    // 会抛 StateError，被外层 catch 成「导入失败，请确认文件来自掌上锡院」，
    // 文案完全指错方向。
    final pickedFile = picked.files.first;
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
    // 🔴 导入后必须联动：`CourseStorage.createTable/switchTable` 的注释明确写了
    // 「切完要由调用方负责联动（小组件 / 提醒 / 首页）」，此前没做 ——
    // 用户导入一张带早上 8 点课的课表，上课提醒却还是上一张表的，或者干脆没有。
    await CourseReminderService.rescheduleAll();
    await WidgetSyncService.syncTodayCourses();
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
