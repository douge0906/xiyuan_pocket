import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/course_model.dart';
import 'widget_sync_service.dart';

/// 课程表本地存储：用 SharedPreferences 持久化课程列表（自主添加 + 教务导入）
class CourseStorage {
  static const String _key = 'course_table_courses';
  static const String _keyBak = 'course_table_courses_bak';

  /// 读取全部课程（含一次性浅色调色板迁移）。
  ///
  /// v2.4.0 抗损坏：逐条解析——单条脏数据只跳过该条，不再整份丢弃；
  /// 整串损坏时回退备份，避免「一条脏数据 + 全量覆盖 = 课表清空」。
  static Future<List<Course>> loadCourses() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    var courses = _parseCourses(raw);
    if (courses == null) {
      // 主数据损坏 → 回退备份
      final bak = _parseCourses(prefs.getString(_keyBak));
      if (bak != null) {
        courses = bak;
        if (bak.isNotEmpty) {
          try {
            await prefs.setString(_key, jsonEncode(bak.map((c) => c.toJson()).toList()));
          } catch (_) {}
        }
      } else {
        return [];
      }
    }
    // 一次性迁移：旧饱和调色板 → 复刻 App A 的浅色调色板
    var changed = false;
    final migrated = courses.map((c) {
      final nv = migrateCourseColor(c.colorValue);
      if (nv != c.colorValue) {
        changed = true;
        return c.copyWith(colorValue: nv);
      }
      return c;
    }).toList();
    if (changed) await saveCourses(migrated);
    return migrated;
  }

  /// 解析课程 JSON 列表。整串非法返回 null；单条非法只跳过该条。
  static List<Course>? _parseCourses(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final out = <Course>[];
      for (final e in decoded) {
        try {
          if (e is Map<String, dynamic>) {
            out.add(Course.fromJson(e));
          } else if (e is Map) {
            out.add(Course.fromJson(Map<String, dynamic>.from(e)));
          }
        } catch (err) {
          debugPrint('跳过损坏的课程记录: $err');
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// 覆盖保存全部课程。保存后同步桌面小组件（今日课表）数据。
  static Future<void> saveCourses(List<Course> courses) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getString(_key);
    final encoded = jsonEncode(courses.map((c) => c.toJson()).toList());
    if (current != null && current.isNotEmpty && current != encoded) {
      try {
        await prefs.setString(_keyBak, current);
      } catch (_) {}
    }
    await prefs.setString(_key, encoded);
    // v2.2.13：课程变更后刷新桌面小组件（静默，失败不影响主流程）
    unawaited(WidgetSyncService.syncTodayCourses());
  }

  /// 新增或更新一门课程
  static Future<List<Course>> upsertCourse(Course course) async {
    final courses = await loadCourses();
    final idx = courses.indexWhere((c) => c.id == course.id);
    if (idx >= 0) {
      courses[idx] = course;
    } else {
      courses.add(course);
    }
    await saveCourses(courses);
    return courses;
  }

  /// 删除一门课程
  static Future<List<Course>> deleteCourse(String id) async {
    final courses = await loadCourses();
    courses.removeWhere((c) => c.id == id);
    await saveCourses(courses);
    return courses;
  }

  /// 用教务系统返回的课程替换所有「server」来源的课程，保留「manual」来源
  static Future<List<Course>> mergeServerCourses(List<Course> serverCourses) async {
    final courses = await loadCourses();
    // ⚠️ 空列表直接返回：导入失败/解析失败时若照常「先删后加」，
    //    会把上次成功导入的课表整份清空（用户看到的就是「导入后课表没了」）。
    if (serverCourses.isEmpty) return courses;
    courses.removeWhere((c) => c.source == CourseSource.server);
    courses.addAll(serverCourses);
    await saveCourses(courses);
    return courses;
  }

  // ---------------- 开学日期（教学周基准） ----------------

  static const String _kSemesterStart = 'course_semester_start';

  /// 读取开学日期（仅日期，无时分秒）。未设置返回 null。
  /// 统一对齐到周一：教学周以周一为界，历史数据可能存了非周一（9.7 bug 修复）。
  static Future<DateTime?> loadSemesterStart() async {
    final prefs = await SharedPreferences.getInstance();
    final iso = prefs.getString(_kSemesterStart);
    if (iso == null) return null;
    final d = DateTime.tryParse(iso);
    if (d == null) return null;
    return mondayOf(DateTime(d.year, d.month, d.day));
  }

  /// 保存开学日期（仅日期）
  static Future<void> saveSemesterStart(DateTime date) async {
    final prefs = await SharedPreferences.getInstance();
    final y = date.year;
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    await prefs.setString(_kSemesterStart, '$y-$m-$d');
  }

  /// 回退到本周一（教学周以周一为界）
  static DateTime mondayOf(DateTime d) => d.subtract(Duration(days: d.weekday - 1));

  /// 根据当前日期估算开学日期：第1学期（秋）约 9/1，第2学期（春）约 2/24，均对齐到周一。
  /// 8 月（暑假尾）归入秋季学期 9/1，否则 8 月下旬会被算成春季学期第 25+ 周（bug 修复）。
  static DateTime defaultSemesterStart(DateTime now) {
    if (now.month >= 8) return mondayOf(DateTime(now.year, 9, 1));
    if (now.month >= 2) return mondayOf(DateTime(now.year, 2, 24));
    return mondayOf(DateTime(now.year - 1, 9, 1));
  }

  /// 计算教学周（第 1 周从开学日期所在周一开始）
  static int teachingWeek(DateTime now, DateTime start) {
    final diff = now.difference(start).inDays;
    if (diff < 0) return 1;
    return diff ~/ 7 + 1;
  }

  /// 根据学年/学期自动估算开学日期，用于「自动定位」：
  /// 第1学期(xqm=3) → 当年 9/1；第2学期(xqm=12) → 学年次年 2/24（如 2025-2026 第2学期为 2026-02-24）。
  static DateTime autoSemesterStart(String xnm, String xqm) {
    final year = int.tryParse(xnm) ?? DateTime.now().year;
    if (xqm == '12') return mondayOf(DateTime(year + 1, 2, 24));
    return mondayOf(DateTime(year, 9, 1));
  }

  /// 当前学期开始日的 ISO 字符串（供单双周判断使用）。
  /// [cached] 为页面内存中的开学日期，缺省时回退本地存储，再回退默认估算。
  /// 统一了课程表页与主页两处重复实现（代码审查报告前端第 6 项）。
  static Future<String> semesterStartIso([DateTime? cached]) async {
    final s = cached ??
        await loadSemesterStart() ??
        defaultSemesterStart(DateTime.now());
    return '${s.year}-${s.month.toString().padLeft(2, '0')}-${s.day.toString().padLeft(2, '0')}';
  }

  // ---------------- 节次时刻表（供「课程结束自动完成」判定） ----------------

  /// 默认节次→结束时刻表（与 course_grid_widgets.dart 的 kDefaultCourseBlocks 末段一致）。
  static const Map<int, String> _defaultSlotEnd = {
    1: '08:45', 2: '09:40', 3: '10:55', 4: '11:50',
    5: '14:30', 6: '15:25', 7: '16:40', 8: '17:35',
    9: '19:30', 10: '20:25', 11: '21:20', 12: '22:25',
  };

  /// 读取节次→结束时刻表：优先用户自定义时间块（取每块 time 的末段），未设置回退默认。
  static Future<Map<int, String>> loadSlotEndMap() async {
    final map = Map<int, String>.of(_defaultSlotEnd);
    try {
      final blocks = await loadTimeBlocks();
      if (blocks != null) {
        for (final b in blocks) {
          final start = (b['start'] as num?)?.toInt();
          final end = (b['end'] as num?)?.toInt();
          final time = (b['time'] as String?) ?? '';
          final parts = time.split('\n');
          final last = parts.length > 1 ? parts[1].trim() : '';
          if (start == null || end == null || !last.contains(':')) continue;
          for (var s = start; s <= end && s <= 12; s++) {
            map[s] = last;
          }
        }
      }
    } catch (_) {
      // 解析失败用默认表
    }
    return map;
  }

  // ---------------- 上课时间块（可自定义） ----------------

  static const String _kTimeBlocks = 'course_time_blocks';

  /// 读取自定义上课时间块；未设置返回 null（页面回退默认表）。
  static Future<List<Map<String, dynamic>>?> loadTimeBlocks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kTimeBlocks);
    if (raw == null || raw.isEmpty) return null;
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => e as Map<String, dynamic>).toList();
    } catch (_) {
      return null;
    }
  }

  /// 保存自定义上课时间块（已序列化为 JSON 列表）。
  static Future<void> saveTimeBlocks(List<Map<String, dynamic>> blocks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTimeBlocks, jsonEncode(blocks));
  }

  // ---------------- 课表显示设置（v1.1.0） ----------------

  /// 显示设置：**网格线**（默认开）、**非本周课程**（默认关）、**背景图**（默认无）。
  /// 用 JSON 存而不是独立 key：以后加字段不用改存储格式，缺字段自动补默认值。
  static const String _kDisplaySettings = 'course_display_settings_v1';

  /// 网格线开关的**内存缓存**：供网格绘制组件（course_grid_widgets）直接读取，
  /// 避免「页面 → 网格 → 单元格」逐层传参。由课表页加载/刷新显示设置时同步更新。
  static bool showGridLinesCache = true;

  /// 「显示非本周课程」开关的内存缓存（理由同 showGridLinesCache）。
  static bool showOtherWeeksCache = false;

  /// 课表背景图路径的内存缓存（空串 = 无背景图）。理由同上。
  static String backgroundImageCache = '';

  static Map<String, dynamic> defaultDisplaySettings() => <String, dynamic>{
        'showGridLines': true,
        'showOtherWeeks': false,
        'backgroundImage': '',
      };

  static Future<Map<String, dynamic>> loadDisplaySettings() async {
    final prefs = await SharedPreferences.getInstance();
    final base = defaultDisplaySettings();
    final raw = prefs.getString(_kDisplaySettings);
    if (raw == null || raw.isEmpty) return base;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final merged = <String, dynamic>{...base, ...j};
      // v1.1.1 一次性迁移：网格线默认开启。老数据里没有标记时（用户此前测试
      // 关过一次就一直关着，导致课表看不到任何网格线）统一置为开启，只做一次。
      if (merged['_gridDefaultOn'] != true) {
        merged['showGridLines'] = true;
        merged['_gridDefaultOn'] = true;
        await saveDisplaySettings(merged);
      }
      return merged;
    } catch (_) {
      return base; // 损坏则回落默认值，不影响课表可用
    }
  }

  static Future<void> saveDisplaySettings(Map<String, dynamic> s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDisplaySettings, jsonEncode(s));
  }
}
