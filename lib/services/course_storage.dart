import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/course_model.dart';
import '../models/course_table.dart';
import 'storage_service.dart';
import 'widget_sync_service.dart';
// 循环依赖是可接受的：course_reminder_service 也 import 本文件，Dart 允许
// 库级循环，只要不在顶层用对方的 const 做初始化。这里只在方法体内调用。
import 'course_reminder_service.dart';

part 'course_presets.dart';

/// 课程表本地存储：用 SharedPreferences 持久化课程列表（自主添加 + 教务导入）
class CourseStorage {
  /// ⚠️ 下面这几个键是**老结构**（一份课表的时代）。多课表改造后它们只用于
  /// **一次性搬家**，搬完**保留不删** —— 万一要回滚，原始数据还在。
  static const String _key = 'course_table_courses';
  static const String _keyBak = 'course_table_courses_bak';

  // ==================== 多份课表（课表档案） ====================
  //
  // 结构：`{ version: 2, activeId: 't_x', tables: [ CourseTable.toJson(), … ] }`
  //
  // 🔴 **对外约定**：下面所有既有方法一律只作用于**当前激活的那一份**，
  //    签名一个字没变。所以课表页 / 首页 / 上课提醒 / 桌面小组件
  //    全都不用改，切表后自动就是新的那份。

  static const String _kTables = 'course_tables_v2';
  static const String _kTablesBak = 'course_tables_v2_bak';

  /// 进程内单调递增序号，只为兜住 id 撞车（见 [_newTableId]）。
  static int _tableSeq = 0;

  /// 生成课表 id。
  ///
  /// 🔴 **必须带自增序号**，不能只用时间戳。Dart 的 `DateTime.now()` 在
  /// Windows 上精度是动态的（0.5ms ~ 15.6ms），同一毫秒内连建两份课表就会
  /// 拿到同一个 id。id 一撞：「切到哪一份」分不清，`deleteTable` 还会把
  /// 两份一起当目标删掉、然后 `next.first` 抛 `Bad state: No element`。
  /// （实际复现过，不是理论风险。）
  static String _newTableId() =>
      't_${DateTime.now().millisecondsSinceEpoch}_${_tableSeq++}';

  /// 仅供测试：连续生成一个 id（时间精度问题只能靠同步连调复现）。
  @visibleForTesting
  static String newTableIdForTest() => _newTableId();

  /// 读出全部课表 + 当前激活的 id。
  ///
  /// 抗损坏顺序：主键 → 备份键 → 从老结构搬家 → 空的一份。
  static Future<({List<CourseTable> tables, String activeId})> _loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    for (final raw in [prefs.getString(_kTables), prefs.getString(_kTablesBak)]) {
      final parsed = _parseTables(raw);
      if (parsed != null) return parsed;
    }
    return _migrateLegacy(prefs);
  }

  /// 解析多表 JSON；不像样就返回 null（交给下一顺位）。
  static ({List<CourseTable> tables, String activeId})? _parseTables(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      final arr = j['tables'];
      if (arr is! List) return null;
      final tables = <CourseTable>[];
      for (final e in arr) {
        final t = CourseTable.fromJson(e);
        if (t != null) tables.add(t); // 单份坏掉只跳过它
      }
      if (tables.isEmpty) return null;
      var active = (j['activeId'] ?? '').toString();
      // 激活的那份可能被删了/坏了 → 落到第一份，不能出现「没有激活表」这种状态
      if (!tables.any((t) => t.id == active)) active = tables.first.id;
      return (tables: tables, activeId: active);
    } catch (_) {
      return null;
    }
  }

  /// 老结构 → 一份「我的课表」。只在两个多表键都读不出来时走这里。
  /// 老键**不动**：不删、不改，纯粹读出来复制一份。
  static Future<({List<CourseTable> tables, String activeId})> _migrateLegacy(
      SharedPreferences prefs) async {
    final legacy = _parseCourses(prefs.getString(_key)) ??
        _parseCourses(prefs.getString(_keyBak)) ??
        <Course>[];

    final start = CourseTable.parseYmd(prefs.getString(_kSemesterStart));
    // 老结构里「来源」是个独立键（上一轮才加的）。判定顺序与
    // loadSemesterStartConfirmed 完全一致，避免搬家前后行为不同。
    final src = prefs.getString(_kSemesterStartSource);
    final source = src == _srcUser
        ? CourseTable.srcUser
        : (src == _srcAuto
            ? CourseTable.srcAuto
            : (start == null ? CourseTable.srcAuto : CourseTable.srcUser));

    final t = CourseTable(
      id: _newTableId(),
      name: '我的课表',
      createdAt: DateTime.now(),
      courses: _migrateLegacyColors(legacy),
      semesterStart: start,
      semesterStartSource: source,
    );
    final tables = [t];
    await _writeAll(tables, t.id, prefs);
    return (tables: tables, activeId: t.id);
  }

  /// 一次性迁移：旧饱和调色板 → 复刻 App A 的浅色调色板。
  static List<Course> _migrateLegacyColors(List<Course> courses) =>
      courses.map((c) {
        final nv = migrateCourseColor(c.colorValue);
        return nv == c.colorValue ? c : c.copyWith(colorValue: nv);
      }).toList();

  /// 写回多表。覆盖前先把上一版整体挪进备份键。
  static Future<void> _writeAll(
    List<CourseTable> tables,
    String activeId, [
    SharedPreferences? prefsIn,
  ]) async {
    final prefs = prefsIn ?? await SharedPreferences.getInstance();
    final current = prefs.getString(_kTables);
    final encoded = jsonEncode({
      'version': 2,
      'activeId': activeId,
      'tables': tables.map((t) => t.toJson()).toList(),
    });
    if (current != null && current.isNotEmpty && current != encoded) {
      try {
        await prefs.setString(_kTablesBak, current);
      } catch (_) {}
    }
    await prefs.setString(_kTables, encoded);
  }

  /// 覆盖**当前激活那份**的课程。保存后同步桌面小组件。
  static Future<void> saveCourses(List<Course> courses) async {
    final all = await _loadAll();
    final idx = all.tables.indexWhere((t) => t.id == all.activeId);
    if (idx < 0) return;
    final next = List<CourseTable>.of(all.tables);
    next[idx] = next[idx].copyWith(courses: courses);
    await _writeAll(next, all.activeId);
    unawaited(WidgetSyncService.syncTodayCourses());
  }

  /// 读取**当前激活那份**的课程（含一次性浅色调色板迁移）。
  ///
  /// v2.4.0 抗损坏：逐条解析——单条脏数据只跳过该条，不再整份丢弃。
  static Future<List<Course>> loadCourses() async {
    final snap = await loadActiveSnapshot();
    final t = snap.active;
    final migrated = _migrateLegacyColors(t.courses);
    if (migrated.length != t.courses.length ||
        !_sameColors(migrated, t.courses)) {
      await saveCourses(migrated);
    }
    return migrated;
  }

  /// **同源快照**：当前课表的课程 + 全部课表 + 开学日，一次读出。
  ///
  /// 🔴 为什么需要：[loadCourses] 与 [activeTable] 各自独立读一次存储，
  ///    两次读之间若 activeId 变了 → 课程来自 A 表、而表名/ID 来自 B 表
  ///    （顶栏写着 B 表名，格子画的是 A 表课程）。这里一次读出，杜绝撕裂。
  static Future<({
      List<Course> courses,
      List<CourseTable> tables,
      CourseTable active,
      DateTime? semesterStart,
    })> loadActiveSnapshot() async {
    final all = await _loadAll();
    final active = all.tables.firstWhere(
      (x) => x.id == all.activeId,
      orElse: () => all.tables.first,
    );
    // 开学日取自**当前激活那份课表**（每份课表各有一份），并对齐到周一 ——
    // 与 [loadSemesterStart] 的口径完全一致。
    final d = active.semesterStart;
    return (
      courses: active.courses,
      tables: all.tables,
      active: active,
      semesterStart: d == null ? null : mondayOf(DateTime(d.year, d.month, d.day)),
    );
  }

  static bool _sameColors(List<Course> a, List<Course> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i].colorValue != b[i].colorValue) return false;
    }
    return true;
  }

  // -------------------- 多课表的增删改查 --------------------

  /// 列出全部课表（按创建时间先后）。
  static Future<List<CourseTable>> loadTables() async =>
      (await _loadAll()).tables;

  /// 当前激活的是哪一份。
  static Future<CourseTable> activeTable() async {
    final all = await _loadAll();
    return all.tables.firstWhere((t) => t.id == all.activeId);
  }

  /// 切换当前使用的课表。切完要由调用方负责联动（小组件 / 提醒 / 首页）。
  static Future<bool> switchTable(String id) async {
    final all = await _loadAll();
    if (!all.tables.any((t) => t.id == id)) return false;
    if (all.activeId == id) return true;
    await _writeAll(all.tables, id);
    return true;
  }

  /// 新建一份课表并**立刻切过去**（导入新课表用完就是这个状态）。返回新 id。
  static Future<String> createTable({
    required String name,
    List<Course> courses = const <Course>[],
    DateTime? semesterStart,
    String semesterStartSource = CourseTable.srcAuto,
    /// 课表来源：导入他人/班级的传 [CourseTable.kindImported] —— 这份不会被
    /// 「我的教务」同步写入（2026-10-13 修跨表覆盖）。
    String kind = CourseTable.kindOwn,
  }) async {
    final all = await _loadAll();
    final safeName = name.trim().isEmpty ? '未命名课表' : name.trim();

    // 🔴 只有一份、且那份是**完全空的占位**时，直接改它，不再多造一份。
    //    空占位是首次安装/刚搬完家自动建的，用户从没见过它 —— 不复用的话，
    //    新用户导入第一份课表后会看到两张表（一张空的 + 一张刚导入的）。
    final only = all.tables.length == 1 ? all.tables.first : null;
    if (only != null && only.courses.isEmpty && only.semesterStart == null) {
      final filled = CourseTable(
        id: only.id,
        name: safeName,
        createdAt: only.createdAt,
        courses: List<Course>.of(courses),
        semesterStart: semesterStart,
        semesterStartSource:
            semesterStart == null ? CourseTable.srcAuto : semesterStartSource,
        // 🔴 2026-10-14 修复：此前漏传 kind —— 参数默认 kindOwn，导致
        //    「导入他人课表」也被存成 own，刷新时 resolveSyncTargetId 会认为
        //    当前这份就是「我的课表」，直接把我的教务课表灌进去（用户报告：
        //    新增第二份课表点刷新被同步成账号的课表）。
        kind: kind,
      );
      await _writeAll([filled], filled.id);
      return filled.id;
    }

    final t = CourseTable(
      id: _newTableId(),
      name: safeName,
      createdAt: DateTime.now(),
      courses: List<Course>.of(courses),
      semesterStart: semesterStart,
      semesterStartSource:
          semesterStart == null ? CourseTable.srcAuto : semesterStartSource,
      // 🔴 同上：new 分支也要带上 kind（导入的课表必须标记 imported）
      kind: kind,
    );
    await _writeAll([...all.tables, t], t.id);
    return t.id;
  }

  /// 给一份课表改名。
  static Future<bool> renameTable(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final all = await _loadAll();
    final idx = all.tables.indexWhere((t) => t.id == id);
    if (idx < 0) return false;
    final next = List<CourseTable>.of(all.tables);
    next[idx] = next[idx].copyWith(name: trimmed);
    await _writeAll(next, all.activeId);
    return true;
  }

  /// 删除一份课表。
  ///
  /// **最后一份不许删**；删掉的正好是当前激活那份时，自动切到剩下的第一份。
  static Future<bool> deleteTable(String id) async {
    final all = await _loadAll();
    if (all.tables.length <= 1) return false;
    final next = all.tables.where((t) => t.id != id).toList();
    if (next.length == all.tables.length) return false; // id 不存在
    // 兜底：万一 id 撞车把整列都过滤掉了，宁可拒绝删也不能留下空列表
    if (next.isEmpty) return false;
    final active =
        next.any((t) => t.id == all.activeId) ? all.activeId : next.first.id;
    await _writeAll(next, active);
    return true;
  }

  /// 解析课程 JSON 列表。**空值/整串非法都返回 null**；单条非法只跳过该条。
  ///
  /// 🔴 2026-10-13 修复：原来空值返回 `[]`，导致调用方
  /// `_parseCourses(_key) ?? _parseCourses(_keyBak) ?? <Course>[]`
  /// 的**备份键兜底永远走不到** —— 主键一旦损坏就成了「空课表」，静默丢数据。
  /// 现在空值返回 null，让 ?? 链真正生效。
  static List<Course>? _parseCourses(String? raw) {
    if (raw == null || raw.isEmpty) return null;
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

  /// 冲突课签名（v1.6.0）：用户在冲突弹窗里选择删除的教务课按此签名持久化，
  /// 同步时过滤 —— 否则教务下次仍下发，用户删过的冲突课会复活。
  /// 用业务字段而非 id：id 由导入方生成（imp_ / sync_ 前缀不统一）。
  static String courseConflictKey(Course c) =>
      '${c.name}|${c.teacher}|${c.weekday}|${c.startSlot}|${c.endSlot}|${c.weeks}';

  /// 冲突**组**的签名：组内各课签名**排序后**拼接（与组内顺序无关）。
  ///
  /// 用途：记住「这组冲突用户已经处理过」（含选「都保留」），
  /// 之后进课表页不再重复自动弹冲突提醒（2026-10-16）。
  static String conflictGroupKey(List<Course> group) {
    final parts = group.map(courseConflictKey).toList()..sort();
    return parts.join('&');
  }

  /// 过滤掉「用户已选择删除」的教务课（冲突解决弹窗的落点）。
  static Future<List<Course>> dropIgnored(List<Course> serverCourses) async {
    if (serverCourses.isEmpty) return serverCourses;
    final dropped = await StorageService.loadDroppedCourseKeys();
    if (dropped.isEmpty) return serverCourses;
    return serverCourses
        .where((c) => !dropped.contains(courseConflictKey(c)))
        .toList();
  }

  /// 用教务系统返回的课程替换所有「server」来源的课程，保留「manual」来源
  static Future<List<Course>> mergeServerCourses(List<Course> serverCourses) async {
    final courses = await loadCourses();
    // v1.6.0：先过滤用户此前选择删除的冲突课（否则同步后它们会复活）
    final incoming = await dropIgnored(serverCourses);
    // ⚠️ 空列表直接返回：导入失败/解析失败时若照常「先删后加」，
    //    会把上次成功导入的课表整份清空（用户看到的就是「导入后课表没了」）。
    if (incoming.isEmpty) return courses;
    courses.removeWhere((c) => c.source == CourseSource.server);
    courses.addAll(incoming);
    await saveCourses(courses);
    return courses;
  }

  /// 把教务抓来的课合并进**指定**课表（不是「当前激活那份」）。
  ///
  /// 2026-10-13 新增，配合 [resolveSyncTargetId] 修「同步写错表」的 bug：
  /// 用户导入他人课表并切过去后，同步必须仍然写回**自己的**那份。
  static Future<({List<Course> merged, List<CourseConflict> conflicts})>
      mergeServerCoursesInto(
    String tableId,
    List<Course> serverCourses,
  ) async {
    final all = await _loadAll();
    final idx = all.tables.indexWhere((t) => t.id == tableId);
    if (idx < 0) return (merged: const <Course>[], conflicts: const <CourseConflict>[]);
    final target = all.tables[idx];
    // v1.6.0：先过滤用户此前选择删除的冲突课（否则同步后它们会复活）
    final incoming = await dropIgnored(serverCourses);
    // 空列表直接返回：导入失败/解析失败时不能「先删后加」把课表清空。
    if (incoming.isEmpty) {
      return (merged: target.courses, conflicts: const <CourseConflict>[]);
    }
    // 先把旧的教务课摘掉 —— 剩下的就是「本地课」（手动的），也是冲突排查对象。
    final locals = List<Course>.of(target.courses)
      ..removeWhere((c) => c.source == CourseSource.server);
    // 2026-10-13（任务三）：检出「教务 vs 本地」的时间冲突，随结果带给界面。
    final conflicts = detectConflicts(locals, incoming);
    final courses = List<Course>.of(locals)..addAll(incoming);
    final next = List<CourseTable>.of(all.tables);
    next[idx] = target.copyWith(courses: courses);
    await _writeAll(next, all.activeId);
    // 目标可能不是当前激活那份 —— 但小组件显示的是哪份由它自己决定，
    // 统一通知一次最省事（内容变了就该重算）。
    unawaited(WidgetSyncService.syncTodayCourses());
    return (merged: courses, conflicts: conflicts);
  }

  /// 检出 [incoming]（本次教务课）与 [existing]（本地课）的**时间冲突**。
  ///
  /// 判定：星期相同 + 节次区间有交集 + **存在某一周两门都上**
  /// （周次判定复用 [Course.occursOn]，与课表网格同一口径，不另写一套）。
  /// 两门课「可能在同一个格子」的星期几候选集。
  ///
  /// 「每天」覆盖 1..7，「工作日」覆盖 1..5，固定周课只覆盖自己的 weekday。
  /// 返回交集候选，再由 `occursOn(wd, 1)` 逐项确认（week=1 只是占位，
  /// 真正的周次判定在外面单独做）。
  static Iterable<int> _weekdayCandidates(Course a, Course b) {
    final da = switch (a.pattern) {
      CoursePattern.daily => const <int>[1, 2, 3, 4, 5, 6, 7],
      CoursePattern.workday => const <int>[1, 2, 3, 4, 5],
      CoursePattern.fixed => <int>[a.weekday],
    };
    final db = switch (b.pattern) {
      CoursePattern.daily => const <int>[1, 2, 3, 4, 5, 6, 7],
      CoursePattern.workday => const <int>[1, 2, 3, 4, 5],
      CoursePattern.fixed => <int>[b.weekday],
    };
    return da.where(db.contains);
  }

  static List<CourseConflict> detectConflicts(
    List<Course> existing,
    List<Course> incoming,
  ) {
    final out = <CourseConflict>[];
    for (final s in incoming) {
      for (final l in existing) {
        if (s.endSlot < l.startSlot || l.endSlot < s.startSlot) continue;
        // 2026-11-04 审查修复：改为「星期几有交集」，不再直接比较 weekday 字段。
        // pattern=每日 存 0、工作日 存 -1，固定周课存 1..7 —— 0/-1 与 1..7
        // 永不相等，导致「每天 5-6 节」与「周一 5-6 节」叠在网格上却不报冲突。
        var overlapWeek = false;
        for (final wd in _weekdayCandidates(s, l)) {
          if (s.occursOn(wd, 1) && l.occursOn(wd, 1)) {
            overlapWeek = true;
            break;
          }
        }
        if (!overlapWeek) continue;
        var overlapSlotWeek = false;
        for (var w = 1; w <= weekCountCache; w++) {
          if (s.isActiveOnWeek(w) && l.isActiveOnWeek(w)) {
            overlapSlotWeek = true;
            break;
          }
        }
        if (overlapSlotWeek) out.add(CourseConflict(server: s, local: l));
      }
    }
    return out;
  }

  /// 检出**教务课表自己内部**的重叠（2026-10-13 用户澄清的真实诉求）。
  ///
  /// 和 [detectConflicts] 的区别：那个是「教务 vs 本地手动课」，
  /// 这个是**教务下发的课程互相撞车** —— 比如某个晚上排了两门 9-10 节的课。
  /// 这种情况用户改不了教务，但**必须让他知道**，否则课表上两门叠在一起
  /// 看着像 App 出错。返回的每对里 server / local 两个字段都来自教务课。
  static List<CourseConflict> detectSelfConflicts(List<Course> incoming) {
    final out = <CourseConflict>[];
    for (var i = 0; i < incoming.length; i++) {
      for (var j = i + 1; j < incoming.length; j++) {
        final a = incoming[i];
        final b = incoming[j];
        if (a.endSlot < b.startSlot || b.endSlot < a.startSlot) continue;
        // 2026-11-04 审查修复：同 detectConflicts —— 必须走 occursOn，
        // 否则「每天」与「每周一」在同一格上叠着也不报冲突。
        var overlapWeek = false;
        for (final wd in _weekdayCandidates(a, b)) {
          if (a.occursOn(wd, 1) && b.occursOn(wd, 1)) {
            overlapWeek = true;
            break;
          }
        }
        if (!overlapWeek) continue;
        var overlapSlotWeek = false;
        for (var w = 1; w <= maxTeachingWeek; w++) {
          if (a.isActiveOnWeek(w) && b.isActiveOnWeek(w)) {
            overlapSlotWeek = true;
            break;
          }
        }
        if (overlapSlotWeek) out.add(CourseConflict(server: a, local: b));
      }
    }
    return out;
  }

  /// 按 id 批量删除**指定课表**里的课程（冲突解决用）。
  static Future<List<Course>> removeCoursesFrom(
    String tableId,
    Iterable<String> ids,
  ) async {
    final kill = ids.toSet();
    if (kill.isEmpty) return const <Course>[];
    final all = await _loadAll();
    final idx = all.tables.indexWhere((t) => t.id == tableId);
    if (idx < 0) return const <Course>[];
    final target = all.tables[idx];
    final courses =
        target.courses.where((c) => !kill.contains(c.id)).toList(growable: false);
    final next = List<CourseTable>.of(all.tables);
    next[idx] = target.copyWith(courses: courses);
    await _writeAll(next, all.activeId);
    unawaited(WidgetSyncService.syncTodayCourses());
    return courses;
  }

  /// 当前激活课表的 id。
  static Future<String> activeTableId() async => (await _loadAll()).activeId;

  /// 自动更新 / 手动刷新**应该写哪一份课表**？（2026-10-13）
  ///
  /// 规则（用户要求「同步对应来源的课表」）：
  ///   ① 当前激活的那份是「本人的课表」→ 写它（常见情形，行为与以前一致）；
  ///   ② 激活的不是本人的（在看导入的班级课表）→ 写**唯一那份本人的**；
  ///   ③ 一份「本人的课表」都没有 → 返回 null，调用方提示、**不写任何表**
  ///      （绝不能拿我的教务去覆盖导入的别人的课表）。
  static Future<String?> resolveSyncTargetId() async {
    final all = await _loadAll();
    if (all.tables.isEmpty) return null;
    final own = all.tables.where((t) => t.syncableByMyCampus).toList();
    if (own.isEmpty) return null;
    final active = all.tables.where((t) => t.id == all.activeId).firstOrNull;
    if (active != null && active.syncableByMyCampus) return active.id;
    final owner = all.tables.firstWhere(
      (t) => t.id == all.activeId,
      orElse: () => own.first,
    );
    return owner.syncableByMyCampus ? owner.id : own.first.id;
  }

  // ---------------- 开学日期（教学周基准） ----------------

  /// ⚠️ 老结构里的**全局**开学日键，多课表后只用于搬家，保留不删。
  static const String _kSemesterStart = 'course_semester_start';

  /// 读取**当前激活那份**的开学日期（仅日期，无时分秒）。未设置返回 null。
  /// 统一对齐到周一：教学周以周一为界，历史数据可能存了非周一（9.7 bug 修复）。
  static Future<DateTime?> loadSemesterStart() async {
    final d = (await activeTable()).semesterStart;
    if (d == null) return null;
    return mondayOf(DateTime(d.year, d.month, d.day));
  }

  /// 保存**当前激活那份**的开学日期（仅日期）。
  ///
  /// [byUser]：用户在界面上选的传 true；导入时按学期估的传 false。
  /// 这个区别记在 [CourseTable.semesterStartSource] 里，决定以后要不要
  /// 提醒「请确认第 1 周」——机器填的不能算用户定过。
  static Future<void> saveSemesterStart(DateTime date,
      {bool byUser = false}) async {
    final all = await _loadAll();
    final idx = all.tables.indexWhere((t) => t.id == all.activeId);
    if (idx < 0) return;
    final aligned = mondayOf(DateTime(date.year, date.month, date.day));
    final next = List<CourseTable>.of(all.tables);
    next[idx] = next[idx].copyWith(
      semesterStart: aligned,
      semesterStartSource: byUser ? CourseTable.srcUser : CourseTable.srcAuto,
    );
    await _writeAll(next, all.activeId);
    // 🔴 开学日决定教学周，而教学周决定「今天上哪几门」（单双周！）→
    //    小组件必须重推，否则它会照旧周次渲染，甚至整门课都不该出现。
    unawaited(WidgetSyncService.syncTodayCourses());
    // 🔴 2026-11-04 审查 P1：**上课提醒也必须重排**，而且只能在这里做。
    //    `CourseReminderService.rescheduleAll()` 按 `teachingWeek(day,
    //    semesterStart)` 决定未来 7 天哪几门课要响；开学日一改，原来排的
    //    单双周课就全错。此前的四个调用点没有任何一个稳定地补这一步：
    //      · `CourseProvider.setSemesterStart` 零重排，且未传 byUser；
    //      · `CourseSyncService.sync` 的「目标不是当前表」分支提前 return，
    //        跳过了它自己末尾的兜底重排；
    //      · 课表页导入到**同一张表**（覆盖）时 `_activeTableId` 没变，
    //        走不到「换表才重排」那条；
    //      · 关掉首周对话框只调 `markSemesterStartConfirmed`，不重排。
    //    把它们逐个补一遍等于埋四个漏洞，所以把重排收进这个唯一出口。
    //    成本是一次 unawaited 调用，失败也不影响开学日本身落盘。
    unawaited(CourseReminderService.rescheduleAll());
  }

  /// ⚠️ 老结构里的全局来源键，多课表后只用于搬家（见 _migrateLegacy）。
  static const String _kSemesterStartSource = 'course_semester_start_source';
  static const String _srcUser = 'user';
  static const String _srcAuto = 'auto';

  /// 用户**是否定过**「第 1 周从哪天开始」（**当前激活那份**）。
  ///
  /// 判定：来源 = user → 定过；= auto（机器填的）→ 没定过，该提醒。
  static Future<bool> loadSemesterStartConfirmed() async =>
      (await activeTable()).semesterStartConfirmedByUser;

  /// 记为「用户已确认」——**不动日期**。
  ///
  /// 🔴 2026-11-04 审查 P2：调用点是 `_askSemesterStart`，而那里原来不管
  ///    用户选没选都会调它（点「用默认值」/ 点 × 都返回 null）。于是
  ///    「直接关掉对话框」被永久记成「已确认」，开学日永远是自动估算值，
  ///    真实开学日差 1~2 周时教学周长期算错且不再纠正。现在只有真选了
  ///    日期才会走到这里。
  static Future<void> markSemesterStartConfirmed() async {
    final all = await _loadAll();
    final idx = all.tables.indexWhere((t) => t.id == all.activeId);
    if (idx < 0) return;
    final next = List<CourseTable>.of(all.tables);
    next[idx] = next[idx].copyWith(semesterStartSource: CourseTable.srcUser);
    await _writeAll(next, all.activeId);
  }

  /// 回退到本周一（教学周以周一为界）
  ///
  /// 🔴 先把入参归一到当天零点再回退：调用方的 `DateTime.now()` 带时分秒，
  ///    不归零的话算出来的「周一」也是 20:45 这种时刻，之后 `add(Duration(days: n))`
  ///    一旦跨夏令时就会漂到前一天，`inDays` 也会截断。
  static DateTime mondayOf(DateTime d) =>
      DateTime(d.year, d.month, d.day)
          .subtract(Duration(days: d.weekday - 1));

  /// 根据当前日期估算开学日期：第1学期（秋）**9/7**，第2学期（春）约 2/24，均对齐到周一。
  ///
  /// 🔴 秋季基准是 **9/7 而不是 9/1**（2026-10-08 修正）。9/1 那周不是第 1 周 ——
  /// 学院历年第 1 周都落在 9 月 7 日那一周；用 9/1 会整整**多算一周**
  /// （9/1 常落在周二周三，mondayOf 之后还更靠前），用户看到「第 3 周」其实是第 2 周。
  /// 原来只有「手动导入后的提示」把默认值给成 9/7，自动导入这条路没跟上。
  ///
  /// 8 月（暑假尾）也归入秋季学期，否则 8 月下旬会被算成春季学期第 25+ 周。
  static DateTime defaultSemesterStart(DateTime now) {
    if (now.month >= 8) return mondayOf(DateTime(now.year, 9, 7));
    if (now.month >= 2) return mondayOf(DateTime(now.year, 2, 24));
    return mondayOf(DateTime(now.year - 1, 9, 7));
  }

  /// [defaultSemesterStart] 的**反函数**：按当前日期推出该查哪个学年 / 学期。
  ///
  /// 返回 `(xnm, xqm)`，取值与教务接口一致：
  ///   · xqm = `'3'`  第1学期（秋，9 月开学）
  ///   · xqm = `'12'` 第2学期（春，次年 2 月开学）
  ///   · xnm 是**学年起始年**（2026-2027 学年第2学期 → xnm = `'2026'`）
  ///
  /// 自洽性（写单元测试钉住）：把返回值喂给 [autoSemesterStart]，
  /// 得到的开学日必须与 [defaultSemesterStart] 一致。
  ///
  /// **为什么需要它**：原先「教务导入」面板把默认值写死成「当年 + 第1学期」，
  /// 人手动导入时会自己看下拉框，问题不大；改成自动同步后就没人看了 ——
  /// 2~7 月自动同步会去抓秋季学期的课，再覆盖掉用户正确的课表。
  static (String, String) semesterArgsFor(DateTime now) {
    if (now.month >= 8) return ('${now.year}', '3'); // 秋季学期，学年从今年起
    if (now.month >= 2) return ('${now.year - 1}', '12'); // 春季学期，学年从去年起
    return ('${now.year - 1}', '3'); // 1 月仍属去年秋季学期（寒假）
  }

  /// 计算教学周（第 1 周从开学日期所在周一开始）
  ///
  /// 🔴 2026-11-04 审查 P1：这里原来**没有上限**。用户在「调整开学日期」
  /// 里可以选到 2020-01-01 这种日期，`_selectedWeek` 会算出上百周，而
  /// `PageView` 只有 [kMaxCourseWeeks] 页 —— 于是表头显示「第 132 周」、
  /// 日期列画到 2022 年，格子却停在 `clamp(0, 24)` 的第 25 周。
  /// 现在统一夹到 1..25，与 `course_table_settings_page` 已有的
  /// `teachingWeek(now, start).clamp(1, 25)` 口径一致。
  /// 硬上限（协议边界）。用户能看到的周数见 [weekCountCache]。
  static const int maxTeachingWeek = kMaxCourseWeeks;

  static int teachingWeek(DateTime now, DateTime start) {
    // 两边都归一到当天零点再算：Duration.inDays 是截断取整，
    // 带时分秒的 now 与零点 start 相减会少算一天（跨零点后周次不跳）。
    final diff = DateTime(now.year, now.month, now.day)
        .difference(DateTime(start.year, start.month, start.day))
        .inDays;
    if (diff < 0) return 1;
    // 夹到用户设定的显示周数：开学日久远（如误选 2020 年）时，
    // 算出「第 132 周」会让表头与网格对不上。
    return (diff ~/ 7 + 1).clamp(1, weekCountCache);
  }

  /// 根据学年/学期自动估算开学日期，用于「自动定位」：
  /// 第1学期(xqm=3) → 当年 **9/7**；第2学期(xqm=12) → 学年次年 2/24
  /// （如 2025-2026 第2学期为 2026-02-24）。基准与 [defaultSemesterStart] 一致。
  static DateTime autoSemesterStart(String xnm, String xqm) {
    final year = int.tryParse(xnm) ?? DateTime.now().year;
    if (xqm == '12') return mondayOf(DateTime(year + 1, 2, 24));
    return mondayOf(DateTime(year, 9, 7));
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
    // 🔴 上课时间变了 → 小组件显示的时刻也得跟着变。
    //    之前漏了这一步：改完时间 App 里立刻变，桌面小组件要等下次
    //    「App 回到前台」才更新，用户看到的就是「两边不同步」。
    //    （saveCourses 里早就有这一句，这里当初漏抄了。）
    unawaited(WidgetSyncService.syncTodayCourses());
  }

  // ---------------- 课表显示设置（v1.1.0） ----------------

  /// 课表设置：**网格线**（默认开）、**非本周课程**（默认关）、**背景图**（默认无）、
  /// **进入 App 自动更新课表**（默认关，2026-10-13 起；原为默认开）。
  /// 用 JSON 存而不是独立 key：以后加字段不用改存储格式，缺字段自动补默认值。
  static const String _kDisplaySettings = 'course_display_settings_v1';

  // 🔴 2026-10-13：「进入 App 自动更新课表」**默认关闭**（原来默认开）。
  //    用户明确要求改默认关 —— 自动同步一旦写错表（见 CourseTable.kind），
  //    后果是别人的课表被我的教务覆盖；默认关掉更安全，用户想要自动更新
  //    可在课表设置页手动打开。手动刷新（右上角刷新键）不受影响。

  /// 网格线开关的**内存缓存**：供网格绘制组件（course_grid_widgets）直接读取，
  /// 避免「页面 → 网格 → 单元格」逐层传参。由课表页加载/刷新显示设置时同步更新。
  static bool showGridLinesCache = true;

  /// 「显示非本周课程」开关的内存缓存（理由同 showGridLinesCache）。
  static bool showOtherWeeksCache = false;

  /// 非本周课程的**颜色清淡度**（0.45~0.85，越大越淡：底色向页面背景色混合的
  /// 比例；v1.5.0 新增，默认 0.75 比原来的写死 0.62 更清淡 —— 用户要求）。
  ///
  /// v1.6.9：语义从「向背景色混合」改为**「淡灰的深浅」** —— 非本周课程统一转成
  /// 淡灰色（保留各课原色的明暗差异），这个值越大灰越淡。滑杆标题与取值范围不变。
  static double otherWeeksDimCache = 0.75;

  /// 课节色块**色彩方案**的内存缓存（v1.6.9）：方案一 / 方案二（柔彩）/ 方案三。
  /// 只在渲染期参与颜色转换（见 [courseColorFor]），不改课程数据。
  /// 2026-11-03：默认「方案二」，与 [defaultDisplaySettings] 保持一致。
  static CourseColorScheme schemeCache = CourseColorScheme.soft;

  // ---- 课表布局（v1.6.4，仿掌上徐工的「课表网格」组）----

  /// 课节高度（每行高，px）。**0 = 自动**（按可用高度均分，等同改造前行为）。
  static double rowHeightCache = 0;

  /// 时间列宽度（px）。开了「隐藏节次时间」时由 activeTimeColWidth 归零。
  // 2026-11-04（m20950 #2）：兜底值 48 → 38，与 `defaultDisplaySettings()` 对齐。
  // 48 会让 7 天均分后（每列约 46dp）的课程块窄到放不下教室名。
  static double timeColWidthCache = 38;

  /// 日期栏（周次 + 一周日期那行）高度（px）。
  /// 背景相关设置变化时自增 —— app 外层要据此重算导航栏透明态。
  ///
  /// 为什么需要：`backgroundColorCache` 是**异步加载**的，App 首次 build 时还是
  /// null，导航栏会先渲染成不透明；等缓存加载完又没人通知它重建，
  /// 于是出现「进课表不透明、切走再回来才透明」（2026-10-26）。
  static final ValueNotifier<int> bgRevision = ValueNotifier<int>(0);

  static double dateRowHeightCache = 48;

  /// 课表背景图路径的内存缓存（空串 = 无背景图）。理由同上。
  static String backgroundImageCache = '';

  /// 背景色是否走**同色系渐变**（上浅下深）。
  ///
  /// 纯色背景容易显得平、像一块色纸；渐变让上沿发白、往下逐渐饱和，
  /// 观感接近「白蓝 → 淡蓝」（2026-10-26 用户提议）。
  static bool bgGradientCache = true;

  /// 渐变强度（0~1）：上沿混多少白。1 = 上沿几乎白，0 = 无渐变。
  static double bgGradientStrengthCache = 0.78;

  /// 背景图**蒙层浓度**（0~1）：越大越遮图 → 整张表更"深"。
  /// 用户要「有人想深一点」，所以做成连续可调（2026-10-26）。
  static double backgroundDimCache = 0.72;

  /// 课表**背景色**（ARGB，null = 未设置）。与背景图**二选一**，
  /// 设置页里选色会清图、选图会清色（2026-10-26 用户要求）。
  static int? backgroundColorCache;

  /// 用户可调的「本学期显示几周」（2026-11-04 用户 m19892 #4）。
  ///
  /// 原来固定 25 周（[kMaxCourseWeeks]），而各校一学期普遍只有 19~21 周 ——
  /// 用户看到的是「往后翻 5 页全空」，还找不到地方改。
  /// 现在默认 20 周，可在「课表设置 → 课表布局 → 显示周数」里 16~25 调。
  ///
  /// 注意区分两者：[kMaxCourseWeeks] 是**协议硬上限**（周次解析、越界保护必须
  /// 按它算，教务下发「1-30周」时不能真造 30 页），这里只是**显示周数**。
  static int weekCountCache = kDefaultWeekCount;

  /// 显示周数的合法范围。
  static const int minWeekCount = 16;
  static const int maxWeekCount = kMaxCourseWeeks;

  // ---------------- 课表外观设置（2026-10-13 v1.3.0：全滑杆）----------------
  //
  // 参照掌上徐工的「课程块精细样式组」，全部做成**连续滑杆**（用户要求：
  // 不要再给几档预设，值得调的量都做成调节杆）。全部存进同一个 JSON，
  // 缺字段自动补默认；旧的三档值在 loadDisplaySettings 里一次性换算。

  /// 网格线粗细（0.5~2.5px）与深浅（0~1 连续，越大越深）。
  static double gridLineWidthCache = 1.0;
  static double gridLineDepthCache = 0.5;

  /// 课程块圆角（0~24px 连续）。
  static double blockRadiusCache = 6;

  /// 课程块内边距（0~8px：文字到块边的距离）。
  static double blockPadCache = 3.0;

  /// 课程块块间距（0~6px：块到格子的距离）。
  static double blockMarginCache = 1.8;

  /// 课程块不透明度（0.1~1.0 连续）。
  static double blockOpacityCache = 1.0;

  /// 课程块边框：粗细 0~2px（0 = 无边框）、虚线开关、虚线密度 0.5~2×（越大越密）。
  static double blockBorderWidthCache = 0.8;
  static bool blockBorderDashedCache = false;
  static double blockDashDensityCache = 1.0;

  /// 课程卡内是否显示任课老师 / 教室。
  static bool showTeacherOnCardCache = true;
  static bool showClassroomOnCardCache = true;
  static bool showNameOnCardCache = true;

  /// 今天列高亮（2026-10-29）。
  static bool highlightTodayCache = true;

  /// 课程卡字号倍率（0.85~1.3）、课程名最大行数（1~3）、省略方式。
  static double cardFontScaleCache = 1.0;
  static int cardMaxLinesCache = 2;
  static String cardOverflowCache = 'ellipsis';

  /// 卡片字段顺序：name / teacher / classroom。
  static List<String> cardFieldOrderCache = const ['name', 'classroom', 'teacher'];

  /// 隐藏左侧节次时间列 / 隐藏日期栏里的「月/日」。
  static bool hideSectionTimeCache = false;
  static bool hideDateRowCache = false;

  /// 「进入 App 自动更新课表」开关的内存缓存（理由同上）。
  ///
  /// 默认**关**（2026-10-13 用户要求改，原为默认开）：自动同步一旦写错表
  /// （见 CourseTable.kind），后果是别人的课表被我的教务覆盖；默认关更安全。
  /// 想要自动更新可在课表设置页手动打开；手动刷新（右上角刷新键）不受影响。
  static bool autoUpdateOnLaunchCache = false;

  static Map<String, dynamic> defaultDisplaySettings() => <String, dynamic>{
        'showGridLines': true,
        'showOtherWeeks': false,
        // v1.5.0：非本周课程颜色清淡度（0.45~0.85，越大越淡；默认比旧观感更清淡）
        'otherWeeksDim': 0.75,
        // v1.6.9：课节色块色彩方案（standard / soft / vivid）。
        // 2026-11-03：默认改为「方案二」（soft）—— 方案一偏灰、方案三过艳，
        // 方案二在明暗两种模式下对比度都更稳。老用户由
        // `_schemeDefaultSoft` 一次性迁移（见 loadDisplaySettings）。
        'scheme': 'soft',
        // v1.6.4：课表布局（仿徐工）—— 0 = 课节高度自动（均分）
        'rowHeight': 0,
        // 2026-11-04（用户 m20455 #2）：时间列宽 48 → 38。
        // 7 天均分后每列本来只有 ~46dp，48 的时间列把课程块挤得太窄，
        // 「科教中心313」这类长教室名放不下；38 之后课程块宽了 10dp。
        'timeColWidth': 38,
        'dateRowHeight': 48,
        // 2026-11-04（m19892 #4）：显示周数。各校一学期 19~21 周，
        // 固定 25 周会多出 4~6 页空白，用户也找不到调整入口。
        'weekCount': kDefaultWeekCount,
        'backgroundImage': '',
        'autoUpdateOnLaunch': false,
        // 2026-10-13 新增（默认 = 改之前的观感，老用户升级无感）
        // v1.3.0：三档字段全部换成连续值（旧值在 loadDisplaySettings 里换算）
        'gridLineWidth': 1.0,
        'gridLineDepth': 0.5,
        'blockRadius': 6.0,
        'blockPad': 3.0,
        'blockMargin': 1.8,
        'blockOpacity': 1.0,
        'blockBorderWidth': 0.8,
        'blockBorderDashed': false,
        'blockDashDensity': 1.0,
        'showTeacherOnCard': true,
        'showClassroomOnCard': true,
        'showNameOnCard': true,
        'highlightToday': true,
        'cardFontScale': 1.0,
        // 2026-11-04（用户 m20455 #2）：课程名默认 2 行 → 3 行。
        'cardMaxLines': 3,
        'cardOverflow': 'ellipsis',
        'cardFieldOrder': <String>['name', 'classroom', 'teacher'],
        'hideSectionTime': false,
        'hideDateRow': false,
        // 2026-10-16：**每种色彩方案各自存一套外观值**（切换时互不干扰，
        // 见 [switchScheme]）。空表示三档都还没被改过 → 一律用方案预设。
        'schemeOverrides': <String, dynamic>{},
      };

  /// 切换色彩方案（2026-10-16：**每种方案各自保存自己那套手动调整**）。
  ///
  /// 用户要求：「色彩方案里手动更改不变，指的是**每种方案各自的手动更改不变**」
  /// —— 三档互不干扰：
  ///  · 先把当前这份设置里的外观值**归档到「当前方案」名下**；
  ///  · 再看「目标方案」名下有没有存过 —— 存过就用它（你在该方案下调过的那套），
  ///    没存过就用 [SchemePreset.of] 的出厂预设；
  ///  · 配色 `scheme` 直接换成目标方案。
  ///
  /// 于是「在方案二里把圆角调圆 → 切回方案一 → 再切回方案二」仍然是你调过的那套。
  /// 只有「恢复默认设置」才会把三档一起清空。
  /// 「方案二」= 轻盈一点点（2026-11-04 明确为默认方案）。
  ///
  /// 这**不只是换配色**，它同时是「整套外观预设」：窄时间栏 + 窄日期栏 +
  /// 淡蓝底 + 无网格线，对应 [SchemePreset.of] 的 soft 预设。
  /// 抽成函数是为了让三处用同一份定义：
  ///   · [loadDisplaySettings] 的默认方案迁移
  ///   · 设置页 `_applyScheme` 的点击套用
  ///   · 「恢复默认设置」
  /// 方案二（「轻盈一点点」）的整套外观补丁。
  ///
  /// ⚠️ 只用于**用户主动点方案二**（`_applyScheme`）与**首次默认迁移**。
  ///    迁移侧有一次性标记兜底，不会每次读设置都重放这一套 ——
  ///    否则它带着的 `showGridLines: false` / `backgroundImage: ''` 会
  ///    把用户后来开的网格线、选的背景图统统驳回（2026-11-04 用户 m20128 #2）。
  static Map<String, dynamic> softSchemePatch() => <String, dynamic>{
        ...SchemePreset.of(CourseColorScheme.soft).toDisplayPatch(),
        // 2026-11-04（m20950 #2）：40 → 38，与 `defaultDisplaySettings()` 一致。
        // 之前两处一个 40 一个 38，用户套用方案后时间列会莫名变宽。
        'timeColWidth': 38.0,
        'dateRowHeight': 42.0,
        'backgroundImage': '',
        'showGridLines': false,
      };

  static Map<String, dynamic> switchScheme(
      Map<String, dynamic> display, CourseColorScheme to) {
    final cur = CourseColorScheme.parse(display['scheme']);
    final raw = display['schemeOverrides'];
    final overrides = <String, dynamic>{
      ...(raw is Map
          ? Map<String, dynamic>.from(raw)
          : const <String, dynamic>{}),
      // 当前方案当前这套值，原样归档
      cur.name: SchemePreset.appearanceOf(display),
    };
    final saved = overrides[to.name];
    final target = saved is Map
        ? Map<String, dynamic>.from(saved)
        : SchemePreset.of(to).toDisplayPatch();
    return <String, dynamic>{
      ...display,
      ...target,
      'scheme': to.name,
      'schemeOverrides': overrides,
    };
  }

  static Future<Map<String, dynamic>> loadDisplaySettings() async {
    final prefs = await SharedPreferences.getInstance();
    final base = defaultDisplaySettings();
    final raw = prefs.getString(_kDisplaySettings);
    // 🔴 2026-11-04（用户 m20128 #2 第二层）：全新安装没有存储，
    //    这里若直接 `return base` 会漏掉 `_schemeDefaultSoft` 标记 ——
    //    用户第一次改设置（比如打开网格线）保存后，**下一次读**才触发
    //    「默认方案二」迁移，把他刚改的又驳回一次。表现与「开关自动驳回」
    //    完全一致。所以这里在返回值上直接带上标记（不改存储，等用户改设置
    //    时随整份 map 一起落盘）。
    if (raw == null || raw.isEmpty) {
      return <String, dynamic>{
        ...base,
        ...softSchemePatch(),
        'backgroundColor': base['backgroundColor'] ?? 0xFFC6DDF7,
        'scheme': 'soft',
        // 新用户本就用默认值，没有历史数据要迁 —— 把所有一次性迁移标记
        // 一并带上，否则他第一次保存设置后会被这些「没有标记就改一次」
        // 的老迁移各驳回一次（网格线被强行打开就是其中之一）。
        '_schemeDefaultSoft': true,
        '_gridDefaultOn': true,
        '_cardOrderV2': true,
      };
    }
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final merged = <String, dynamic>{...base, ...j};
      // 2026-10-16：`_custom`（上一版的全局"手调键"清单）已被
      // `schemeOverrides`（每档各存一套）取代 —— 顺手清掉，别留在存储里。
      merged.remove('_custom');
      // v1.1.1 一次性迁移：网格线默认开启。老数据里没有标记时（用户此前测试
      // 关过一次就一直关着，导致课表看不到任何网格线）统一置为开启，只做一次。
      if (merged['_gridDefaultOn'] != true) {
        merged['showGridLines'] = true;
        merged['_gridDefaultOn'] = true;
        await saveDisplaySettings(merged);
      }
      // v1.3.0（2026-10-13）迁移：外观「三档」值 → 「连续滑杆」值。
      // 判据：原数据里没有新键时按旧键换算（新用户两条都不成立、无副作用；
      // 换算结果与旧档位视觉一致，老用户升级无感）。
      if (!j.containsKey('gridLineDepth')) {
        final s = (int.tryParse('${j['gridLineStrength'] ?? 1}') ?? 1).clamp(0, 2);
        merged['gridLineDepth'] = const [0.25, 0.5, 0.75][s];
      }
      if (!j.containsKey('blockPad')) {
        final d = (int.tryParse('${j['blockDensity'] ?? 1}') ?? 1).clamp(0, 2);
        merged['blockPad'] = const [2.0, 3.0, 5.0][d];
        merged['blockMargin'] = const [1.2, 1.8, 2.6][d];
      }
      if (!j.containsKey('blockBorderWidth')) {
        final b = (int.tryParse('${j['blockBorder'] ?? 1}') ?? 1).clamp(0, 2);
        merged['blockBorderWidth'] = b == 0 ? 0.0 : 0.8;
        merged['blockBorderDashed'] = b == 2;
      }
      // 2026-10-30：默认内容顺序改为「课程名 / 教室 / 教师」。
      // 旧默认值等于 name→teacher→classroom 的用户一次性迁移。
      if (merged['_cardOrderV2'] != true) {
        final rawOrder = merged['cardFieldOrder'];
        if (rawOrder is List &&
            rawOrder.join(',') == 'name,teacher,classroom') {
          merged['cardFieldOrder'] = ['name', 'classroom', 'teacher'];
        }
        merged['_cardOrderV2'] = true;
        await saveDisplaySettings(merged);
      }
      // 🔴 2026-11-04 修正（m18409 #4）：默认色彩方案必须真的是「方案二」。
      //
      // 上一版的判据是「存储里没有 `scheme` 键 = 用户没选过」，这**不成立**：
      //   · 2026-11-03 之前 `defaultDisplaySettings()` 的默认值就是方案一；
      //   · 同文件里 `_gridDefaultOn` 等一次性迁移会把整份 merged（含
      //     `'scheme': 'standard'`）**写回存储** —— 于是「从没选过方案」的
      //     老用户，存储里也带着 `scheme: standard`；
      //   · 结果：判据恒 false，默认方案二永远不生效，用户看到的一直是方案一。
      //
      // 现在改用**显式标记** `schemeUserPicked`：只有用户真的点了色卡
      // （`_applyScheme` 里写这个键）才算「选过」。没有标记、且当前不是方案三
      // （方案三只可能是用户主动选的）→ 一律回到方案二预设。
      final picked = merged['schemeUserPicked'] == true;
      // 🔴 2026-11-04（用户 m20128 #2）：迁移必须**只做一次**。
      //    上一版漏了这个判据 —— 于是每次 `loadDisplaySettings()` 都会把
      //    `softSchemePatch()` 再套一遍，而它带着 `showGridLines: false` /
      //    `backgroundImage: ''` ⇒ 用户打开网格线、选了背景图，下次读设置
      //    又被强行关掉/清空（现象：「开关自动驳回」「背景图无法生效」）。
      final migrated = merged['_schemeDefaultSoft'] == true;
      final curScheme = '${merged['scheme'] ?? ''}';
      if (!picked && !migrated && curScheme != 'vivid') {
        final patch = softSchemePatch();
        // 保留用户自己挑过的背景色（方案二预设的淡蓝只在用户没设过时套用）
        if (merged['backgroundColor'] == null) {
          // 2026-11-04（用户 m20128 #2「再次增大首次选中背景色的饱和度」）：
          // 2026-11-04（用户 m20455 #2「默认饱和度调制 20」）：
          // 0xFFE8F1FB（HSV 饱和度 7.6%）→ 0xFFC6DDF7（饱和度 20%，明度 97%）。
          // 色相不变，只是把蓝提到看得出来的浓度 —— 前两版一路抬饱和仍偏灰。
          patch['backgroundColor'] = 0xFFC6DDF7;
        }
        merged.addAll(patch);
        merged['scheme'] = 'soft';
        merged['_schemeDefaultSoft'] = true;
        await saveDisplaySettings(merged);
      }
      return merged;
    } catch (_) {
      return base; // 损坏则回落默认值，不影响课表可用
    }
  }

  /// 把「显示设置」同步进内存缓存（课表页与课表设置页**共用**这一份逻辑）。
  ///
  /// 2026-10-13 v1.3.0：从 `course_table_home_page._loadDisplaySettings` 抽出 ——
  /// 课表设置页改动滑杆时缓存必须**立即**更新（顶部实时预览 + 返回课表都读它），
  /// 不能等返回课表页时才同步。
  static void applyDisplayToCache(Map<String, dynamic> s) {
    double d(Object? v, double fb) => double.tryParse('$v') ?? fb;
    showGridLinesCache = s['showGridLines'] != false;
    showOtherWeeksCache = s['showOtherWeeks'] == true;
    otherWeeksDimCache = d(s['otherWeeksDim'], 0.75).clamp(0.45, 0.85);
    schemeCache = CourseColorScheme.parse(s['scheme']);
    rowHeightCache = d(s['rowHeight'], 0).clamp(0, 120);
    timeColWidthCache = d(s['timeColWidth'], 38).clamp(28, 72);
    dateRowHeightCache = d(s['dateRowHeight'], 48).clamp(36, 88);
    weekCountCache = d(s['weekCount'], kDefaultWeekCount.toDouble())
        .round()
        .clamp(minWeekCount, maxWeekCount);
    // 56 是 2026-10-26 之前的默认值，用户反馈偏高，统一降到 48
    if (dateRowHeightCache == 56) dateRowHeightCache = 48;
    final prevImg = backgroundImageCache;
    final prevColor = backgroundColorCache;
    backgroundImageCache = (s['backgroundImage'] ?? '').toString();
    final bgc = s['backgroundColor'];
    backgroundColorCache = bgc is num ? bgc.toInt() : null;
    backgroundDimCache = d(s['backgroundDim'], 0.72).clamp(0.0, 0.95);
    // 默认开启（用户反馈纯色太平，渐变观感更好）
    bgGradientCache = s['bgGradient'] != false;
    bgGradientStrengthCache =
        d(s['bgGradientStrength'], 0.78).clamp(0.0, 1.0);
    // 只在背景真的变了才通知：否则每次拖滑杆都会重建外层，直接卡
    if (prevImg != backgroundImageCache || prevColor != backgroundColorCache) {
      bgRevision.value++;
    }
    gridLineWidthCache = d(s['gridLineWidth'], 1.0);
    gridLineDepthCache = d(s['gridLineDepth'], 0.5);
    blockRadiusCache = d(s['blockRadius'], 6);
    blockPadCache = d(s['blockPad'], 3.0);
    blockMarginCache = d(s['blockMargin'], 1.8);
    blockOpacityCache = d(s['blockOpacity'], 1.0);
    blockBorderWidthCache = d(s['blockBorderWidth'], 0.8);
    blockBorderDashedCache = s['blockBorderDashed'] == true;
    blockDashDensityCache = d(s['blockDashDensity'], 1.0);
    showTeacherOnCardCache = s['showTeacherOnCard'] != false;
    showClassroomOnCardCache = s['showClassroomOnCard'] != false;
    showNameOnCardCache = s['showNameOnCard'] != false;
    highlightTodayCache = s['highlightToday'] != false;
    cardFontScaleCache =
        (double.tryParse('${s['cardFontScale']}') ?? 1.0).clamp(0.85, 1.3);
    cardMaxLinesCache =
        (int.tryParse('${s['cardMaxLines']}') ?? 2).clamp(1, 3);
    final overflow = (s['cardOverflow'] ?? 'ellipsis').toString();
    cardOverflowCache =
        ['ellipsis', 'clip', 'fade'].contains(overflow) ? overflow : 'ellipsis';
    final rawOrder = s['cardFieldOrder'];
    if (rawOrder is List) {
      final order = rawOrder
          .map((e) => e.toString())
          .where((e) => ['name', 'teacher', 'classroom'].contains(e))
          .toList();
      if (order.length == 3) cardFieldOrderCache = order;
    }
    hideSectionTimeCache = s['hideSectionTime'] == true;
    hideDateRowCache = s['hideDateRow'] == true;
    autoUpdateOnLaunchCache = s['autoUpdateOnLaunch'] != false;
  }

  static Future<void> saveDisplaySettings(Map<String, dynamic> s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDisplaySettings, jsonEncode(s));
  }

  // ---------------- 自定义外观方案（2026-10-29）----------------

  static const String _kAppearancePresets = 'course_appearance_presets_v1';

  /// 可随外观方案保存/导入导出的键；不含本机背景图路径。
  static const List<String> appearanceKeys = [
    'scheme',
    'showGridLines',
    'gridLineWidth',
    'gridLineDepth',
    'showOtherWeeks',
    'otherWeeksDim',
    'highlightToday',
    'rowHeight',
    'timeColWidth',
    'dateRowHeight',
    'hideSectionTime',
    'hideDateRow',
    'blockRadius',
    'blockPad',
    'blockMargin',
    'blockOpacity',
    'blockBorderWidth',
    'blockBorderDashed',
    'blockDashDensity',
    'backgroundColor',
    'bgGradient',
    'bgGradientStrength',
    'backgroundDim',
    'showNameOnCard',
    'showTeacherOnCard',
    'showClassroomOnCard',
    'cardFontScale',
    'cardMaxLines',
    'cardOverflow',
    'cardFieldOrder',
  ];

  static Map<String, dynamic> appearanceOfDisplay(Map<String, dynamic> d) {
    return <String, dynamic>{
      for (final k in appearanceKeys)
        if (d.containsKey(k)) k: d[k],
    };
  }

  static Future<Map<String, Map<String, dynamic>>> loadAppearancePresets() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kAppearancePresets);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, Map<String, dynamic>>{};
      decoded.forEach((key, value) {
        if (value is Map) {
          result[key.toString()] = Map<String, dynamic>.from(value);
        }
      });
      return result;
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveAppearancePresets(
      Map<String, Map<String, dynamic>> presets) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAppearancePresets, jsonEncode(presets));
  }
}
