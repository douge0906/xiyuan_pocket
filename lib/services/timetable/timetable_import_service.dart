import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/course_model.dart';
import '../../models/course_table.dart';
import '../course_reminder_service.dart';
import '../course_storage.dart';
import '../course_transfer_service.dart';
import '../widget_sync_service.dart';
import 'timetable_models.dart';

/// 在线班级课表「导入到本机」的全部逻辑。
///
/// 产品口径（设计稿 R4）：**导入 = 直接覆盖**，本地同一个班级只保留一份。
/// 这不是「合并」——两版课表逐课合并出第三种结果，用户没法判断哪门课是对的，
/// 下次教务一变又会分叉。所以只有两种结果：覆盖已有那份，或者新建一份。
///
/// 覆盖前必须先算差异（新增/变更/移除），让用户看见「我要丢掉什么」。
/// 差异只用于确认，不参与写入：确认之后整表替换。
class TimetableImportService {
  TimetableImportService._();

  /// 找出本机「同一个班级」的那份课表。
  ///
  /// 判定条件两个都要满足：
  ///   · `kind == kindImported` —— 绝不覆盖用户自己的 `kindOwn` 课表。他可能
  ///     刚好把自己的课表命名成「25电气1班」，覆盖掉就是数据事故。
  ///   · 名字完全相等 —— 不做模糊匹配。「25电气1班」和「25电气1」是两个班。
  static Future<CourseTable?> findLocalTable(String bj) async {
    final name = bj.trim();
    if (name.isEmpty) return null;
    final tables = await CourseStorage.loadTables();
    for (final t in tables) {
      if (t.kind == CourseTable.kindImported && t.name.trim() == name) {
        return t;
      }
    }
    return null;
  }

  /// 把服务端的课程转成本机 [Course]。
  ///
  /// `source` 固定 [CourseSource.imported]：这是**别人的**课表，绝不能标成
  /// server —— 标成 server 的话，用户下次登录自己的教务同步时会被静默删掉
  /// （见 `CourseSource` 的注释）。
  static List<Course> toCourses(List<TimetableCourseItem> items) {
    final out = <Course>[];
    for (final item in items) {
      out.add(Course(
        // id 用「班级+星期+节次+课程名」的稳定指纹，同一份课表重复导入时
        // 不会因为随机 id 而把「同一门课」变成两门。
        id: 'tt_${_stableKey(item)}',
        name: item.name,
        teacher: item.teacher,
        classroom: item.classroom,
        weekday: item.weekday,
        startSlot: item.startSlot,
        endSlot: item.endSlot,
        weeks: item.weeks,
        colorValue: colorForName(item.name),
        source: CourseSource.imported,
      ));
    }
    return out;
  }

  /// 把本机课程转成上传用的形状（从本机课程表导入的路径用）。
  static List<TimetableCourseItem> fromCourses(List<Course> courses) {
    final out = <TimetableCourseItem>[];
    for (final c in courses) {
      // pattern 不是 fixed 的课（每天/工作日）没有确定的星期，上传后会变成
      // 一门「每周一第 N 节」的假课 —— 直接跳过，不让它污染别人看到的课表。
      if (c.pattern != CoursePattern.fixed) continue;
      if (c.weekday < 1 || c.weekday > 7) continue;
      if (c.startSlot < 1) continue;
      out.add(TimetableCourseItem(
        name: c.name.trim(),
        teacher: c.teacher.trim(),
        classroom: c.classroom.trim(),
        weekday: c.weekday,
        startSlot: c.startSlot,
        endSlot: c.endSlot < c.startSlot ? c.startSlot : c.endSlot,
        weeks: c.weeks.trim(),
      ));
    }
    return out;
  }

  /// 算差异：把 [incoming] 与 [existing] 按课名配对。
  ///
  /// 同名多门（比如「体育」两节）用**贪心**配对：先按原顺序逐个找，配过的
  /// 划掉。这样既不会把一门课配两次，也不需要 O(n²) 的最优匹配 —— 同名校
  /// 的课在课表里最多两三门，贪心的结果和最优一样。
  static TimetableDiffSummary diff(
    List<Course> existing,
    List<TimetableCourseItem> incoming,
  ) {
    final pool = <int, Course>{for (var i = 0; i < existing.length; i++) i: existing[i]};
    final added = <TimetableDiffEntry>[];
    final changed = <TimetableDiffEntry>[];

    for (final item in incoming) {
      final key = _normName(item.name);
      int? hit;
      for (final entry in pool.entries) {
        if (_normName(entry.value.name) == key) {
          hit = entry.key;
          break;
        }
      }
      if (hit == null) {
        added.add(TimetableDiffEntry(
          kind: 'added',
          name: item.name,
          detail: '${_dayLabel(item.weekday)} ${item.slotLabel}',
        ));
        continue;
      }
      final old = pool.remove(hit)!;
      final changes = <String>[];
      if (old.weekday != item.weekday) {
        changes.add('${_dayLabel(old.weekday)} → ${_dayLabel(item.weekday)}');
      }
      if (old.startSlot != item.startSlot || old.endSlot != item.endSlot) {
        changes.add('第${old.startSlot}-${old.endSlot}节 → ${item.slotLabel}');
      }
      if (old.weeks.trim() != item.weeks.trim()) {
        changes.add('周次 ${old.weeks.trim().isEmpty ? '不限' : old.weeks.trim()} → '
            '${item.weeks.trim().isEmpty ? '不限' : item.weeks.trim()}');
      }
      if (old.classroom.trim() != item.classroom.trim()) {
        changes.add('教室 ${old.classroom.trim().isEmpty ? '未填' : old.classroom.trim()} → '
            '${item.classroom.trim().isEmpty ? '未填' : item.classroom.trim()}');
      }
      if (old.teacher.trim() != item.teacher.trim()) {
        changes.add('教师 ${old.teacher.trim().isEmpty ? '未填' : old.teacher.trim()} → '
            '${item.teacher.trim().isEmpty ? '未填' : item.teacher.trim()}');
      }
      if (changes.isNotEmpty) {
        changed.add(TimetableDiffEntry(
          kind: 'changed',
          name: item.name,
          detail: changes.join('；'),
        ));
      }
    }

    final removed = <TimetableDiffEntry>[];
    for (final c in pool.values) {
      removed.add(TimetableDiffEntry(
        kind: 'removed',
        name: c.name,
        detail: '${_dayLabel(c.weekday)} 第${c.startSlot}-${c.endSlot}节',
      ));
    }

    return TimetableDiffSummary(
      added: added.length,
      changed: changed.length,
      removed: removed.length,
      details: <TimetableDiffEntry>[...added, ...changed, ...removed],
    );
  }

  /// 真正落库。
  ///
  /// 返回 (表 id, 是否新建)。调用方负责弹 toast 与刷新首页。
  ///
  /// 失败时**不动原课表**：只有 [CourseStorage.replaceTableCourses] 返回 true
  /// 才算写成功；新建走 [CourseStorage.createTable]，它内部一次性写整个列表。
  static Future<({String tableId, bool created})> apply({
    required String bj,
    required List<TimetableCourseItem> items,
    required String xnm,
    required String xqm,
  }) async {
    final courses = toCourses(items);
    final semesterStart = CourseStorage.autoSemesterStart(xnm, xqm);
    final existing = await findLocalTable(bj);

    if (existing != null) {
      final ok = await CourseStorage.replaceTableCourses(
        existing.id,
        courses,
        semesterStart: semesterStart,
        semesterStartSource: CourseTable.srcAuto,
      );
      if (!ok) {
        throw StateError('覆盖本机课表失败');
      }
      await CourseStorage.switchTable(existing.id);
      await _afterImport();
      return (tableId: existing.id, created: false);
    }

    final id = await CourseStorage.createTable(
      name: bj.trim().isEmpty ? '在线课表' : bj.trim(),
      courses: courses,
      semesterStart: semesterStart,
      semesterStartSource: CourseTable.srcAuto,
      kind: CourseTable.kindImported,
    );
    await _afterImport();
    return (tableId: id, created: true);
  }

  /// 导入/覆盖之后的三条联动。
  ///
  /// `CourseStorage` 的注释写明「切完要由调用方负责联动」，漏掉的话用户导入
  /// 了一张有早上八点课的课表，上课提醒还是上一张表的。
  static Future<void> _afterImport() async {
    try {
      await CourseReminderService.rescheduleAll();
    } catch (e) {
      if (kDebugMode) debugPrint('[timetable] 重排提醒失败：$e');
    }
    try {
      await WidgetSyncService.syncTodayCourses();
    } catch (e) {
      if (kDebugMode) debugPrint('[timetable] 同步小组件失败：$e');
    }
  }

  /// 表名 → 上传用的班级名。用户导出的课表可能叫「我的课表」，这时候
  /// 应该拿当前系统里的班级名兜底（由页面传进来）。
  static String guessClassName(String tableName) => tableName.trim();

  static String _stableKey(TimetableCourseItem c) {
    final raw = '${c.name}|${c.weekday}|${c.startSlot}|${c.endSlot}|${c.weeks}';
    var hash = 0;
    for (final unit in raw.codeUnits) {
      hash = (hash * 31 + unit) & 0x7FFFFFFF;
    }
    return hash.toRadixString(16);
  }

  static String _normName(String s) {
    return s
        .replaceAll(RegExp(r'[（(][^）)]*[）)]'), '')
        .replaceAll(RegExp(r'\s+'), '')
        .toLowerCase();
  }

  static String _dayLabel(int weekday) {
    const names = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    if (weekday < 1 || weekday > 7) return '周?';
    return names[weekday];
  }

  /// 上传前把课程列表转成请求体里的 courses 字段。
  static List<Map<String, dynamic>> toRequestList(List<TimetableCourseItem> items) =>
      items.map((e) => e.toRequestJson()).toList(growable: false);

  /// 去掉一门课（Step 2 课程核对里用户删掉的那条）。
  static List<TimetableCourseItem> removeAt(
      List<TimetableCourseItem> items, int index) {
    final next = List<TimetableCourseItem>.of(items);
    if (index < 0 || index >= next.length) return items;
    next.removeAt(index);
    return next;
  }

  /// 给一门课换字段（Step 2 里编辑过的那条）。
  static List<TimetableCourseItem> replaceAt(
    List<TimetableCourseItem> items,
    int index,
    TimetableCourseItem item,
  ) {
    final next = List<TimetableCourseItem>.of(items);
    if (index < 0 || index >= next.length) return items;
    next[index] = item;
    return next;
  }

  /// 一门课的「需要确认」的问题标签。
  ///
  /// 只报**客观能判定的**：缺周次、缺教室、同一星期节次撞车。不猜「老师可能
  /// 填错了」——那种判断会给一堆正常课程挂上橙标，用户很快就不看标签了。
  static List<String> issuesOf(
    List<TimetableCourseItem> items,
    int index,
  ) {
    final out = <String>[];
    if (index < 0 || index >= items.length) return out;
    final c = items[index];
    if (c.weeks.trim().isEmpty) out.add('周次待确认');
    if (c.classroom.trim().isEmpty) out.add('缺少教室');
    for (var i = 0; i < items.length; i++) {
      if (i == index) continue;
      final o = items[i];
      if (o.weekday != c.weekday) continue;
      if (o.startSlot <= c.endSlot && c.startSlot <= o.endSlot) {
        out.add('时间重叠');
        break;
      }
    }
    return out;
  }

  /// 整个列表里有多少门课带问题（Step 2 顶部那条橙字用）。
  static int issueCount(List<TimetableCourseItem> items) {
    var n = 0;
    for (var i = 0; i < items.length; i++) {
      if (issuesOf(items, i).isNotEmpty) n++;
    }
    return n;
  }

  /// 解析「本机导出的课表文件」，取其中**当前激活那一份**的课程。
  ///
  /// 认两种 schema：`xiyuan.course.tables`（仅课表）与 `xiyuan.full.bundle`
  /// （课表 + 外观）。第三种 `xiyuan.appearance` 明确拒绝 —— 它压根不含课表，
  /// 用户选错了文件要当场说清楚，而不是给一个空列表让他以为文件坏了。
  static List<TimetableCourseItem> parseFileBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const CourseTransferException('文件是空的');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw const CourseTransferException('文件不是有效的 JSON');
    }
    if (decoded is! Map) {
      throw const CourseTransferException('文件结构不正确');
    }
    final map = Map<String, dynamic>.from(decoded);
    final schema = (map['schema'] ?? '').toString();
    if (schema == CourseTransferService.appearanceSchema) {
      throw const CourseTransferException('这是「仅外观方案」的文件，里面没有课表');
    }
    if (schema != CourseTransferService.schema &&
        schema != CourseTransferService.bundleSchema) {
      throw const CourseTransferException('这不是掌上锡院的课表方案文件');
    }
    final version = (map['version'] as num?)?.toInt() ?? 0;
    if (version != CourseTransferService.formatVersion) {
      throw CourseTransferException('方案版本不支持：$version');
    }

    final rawTables = map['tables'];
    if (rawTables is! List || rawTables.isEmpty) {
      throw const CourseTransferException('方案里没有课表');
    }
    final wanted = (map['activeId'] ?? '').toString();
    var picked = CourseTable.fromJson(rawTables.first);
    if (wanted.isNotEmpty) {
      for (final raw in rawTables) {
        final t = CourseTable.fromJson(raw);
        if (t != null && t.id == wanted) {
          picked = t;
          break;
        }
      }
    }
    if (picked == null || picked.courses.isEmpty) {
      throw const CourseTransferException('这份课表里没有课程');
    }
    final items = fromCourses(picked.courses);
    if (items.isEmpty) {
      throw const CourseTransferException('这份课表里的课都不是固定节次，无法上传');
    }
    return items;
  }
}

/// 一个可取消的等待（给上传用，目前只做 UI 反馈）。
typedef TimetableProgress = void Function(String stage);
