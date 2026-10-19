import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/course_model.dart';
import '../models/course_table.dart';
import 'storage_service.dart';
import 'widget_sync_service.dart';

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
  /// （在线版那边已经实际复现过一次，不是理论风险。）
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
    final all = await _loadAll();
    final t = all.tables.firstWhere((x) => x.id == all.activeId);
    final migrated = _migrateLegacyColors(t.courses);
    if (migrated.length != t.courses.length ||
        !_sameColors(migrated, t.courses)) {
      await saveCourses(migrated);
    }
    return migrated;
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
  static List<CourseConflict> detectConflicts(
    List<Course> existing,
    List<Course> incoming,
  ) {
    final out = <CourseConflict>[];
    for (final s in incoming) {
      for (final l in existing) {
        if (s.weekday != l.weekday) continue;
        if (s.endSlot < l.startSlot || l.endSlot < s.startSlot) continue;
        var overlapWeek = false;
        for (var w = 1; w <= 20; w++) {
          if (s.isActiveOnWeek(w) && l.isActiveOnWeek(w)) {
            overlapWeek = true;
            break;
          }
        }
        if (overlapWeek) out.add(CourseConflict(server: s, local: l));
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
        if (a.weekday != b.weekday) continue;
        if (a.endSlot < b.startSlot || b.endSlot < a.startSlot) continue;
        var overlapWeek = false;
        for (var w = 1; w <= 20; w++) {
          if (a.isActiveOnWeek(w) && b.isActiveOnWeek(w)) {
            overlapWeek = true;
            break;
          }
        }
        if (overlapWeek) out.add(CourseConflict(server: a, local: b));
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

  /// 记为「用户已确认/已跳过」——**不动日期**。
  ///
  /// 用户直接把对话框关掉时也要调它：否则下次打开又弹，成了骚扰。
  static Future<void> markSemesterStartConfirmed() async {
    final all = await _loadAll();
    final idx = all.tables.indexWhere((t) => t.id == all.activeId);
    if (idx < 0) return;
    final next = List<CourseTable>.of(all.tables);
    next[idx] = next[idx].copyWith(semesterStartSource: CourseTable.srcUser);
    await _writeAll(next, all.activeId);
  }

  /// 回退到本周一（教学周以周一为界）
  static DateTime mondayOf(DateTime d) => d.subtract(Duration(days: d.weekday - 1));

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
  static int teachingWeek(DateTime now, DateTime start) {
    final diff = now.difference(start).inDays;
    if (diff < 0) return 1;
    return diff ~/ 7 + 1;
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
  /// **进入 App 自动更新课表**（默认开）。
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
  static CourseColorScheme schemeCache = CourseColorScheme.standard;

  // ---- 课表布局（v1.6.4，仿掌上徐工的「课表网格」组）----

  /// 课节高度（每行高，px）。**0 = 自动**（按可用高度均分，等同改造前行为）。
  static double rowHeightCache = 0;

  /// 时间列宽度（px）。开了「隐藏节次时间」时由 activeTimeColWidth 归零。
  static double timeColWidthCache = 48;

  /// 日期栏（周次 + 一周日期那行）高度（px）。
  static double dateRowHeightCache = 56;

  /// 课表背景图路径的内存缓存（空串 = 无背景图）。理由同上。
  static String backgroundImageCache = '';

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

  /// 隐藏左侧节次时间列 / 隐藏日期栏里的「月/日」。
  static bool hideSectionTimeCache = false;
  static bool hideDateRowCache = false;

  /// 「进入 App 自动更新课表」开关的内存缓存（理由同上）。
  ///
  /// 默认**开**：开源版已经把「手动点按钮导入」这条路去掉了，同步对用户是隐形的；
  /// 默认关的话，大多数人永远不会去设置页打开它，课表就再也不更新了。
  /// 关了也安全 —— 只是不再自动同步，随时可用课表页右上角的刷新键手动同步。
  static bool autoUpdateOnLaunchCache = false;

  static Map<String, dynamic> defaultDisplaySettings() => <String, dynamic>{
        'showGridLines': true,
        'showOtherWeeks': false,
        // v1.5.0：非本周课程颜色清淡度（0.45~0.85，越大越淡；默认比旧观感更清淡）
        'otherWeeksDim': 0.75,
        // v1.6.9：课节色块色彩方案（standard / soft / vivid，默认 = 改造前观感）
        'scheme': 'standard',
        // v1.6.4：课表布局（仿徐工）—— 0 = 课节高度自动（均分）
        'rowHeight': 0,
        'timeColWidth': 48,
        'dateRowHeight': 56,
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
    if (raw == null || raw.isEmpty) return base;
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
    timeColWidthCache = d(s['timeColWidth'], 48).clamp(28, 72);
    dateRowHeightCache = d(s['dateRowHeight'], 56).clamp(36, 88);
    backgroundImageCache = (s['backgroundImage'] ?? '').toString();
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
    hideSectionTimeCache = s['hideSectionTime'] == true;
    hideDateRowCache = s['hideDateRow'] == true;
    autoUpdateOnLaunchCache = s['autoUpdateOnLaunch'] != false;
  }

  static Future<void> saveDisplaySettings(Map<String, dynamic> s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDisplaySettings, jsonEncode(s));
  }
}

/// 「色彩方案」的**整套外观预设**（2026-10-16）。
///
/// 用户要求：方案不能只管配色 —— **圆角 / 内边距 / 块间距 / 边框 / 课节高度 /
/// 网格线 / 非本周淡化 也要跟着方案一起变**，具体数值照参考截图来。
/// 切换方案 = 一键套用这一整套搭配；套完下面的滑杆仍然可以继续微调。
///
/// 数值来源（两张 867×1920 参考截图，按 2.41 密度折 dp）：
///  · 图1 → 方案二：块宽 101px、圆角 ≈20px（≈8.3dp）、块间距 ≈3dp(margin 1.5)、
///    1 节课高 152px（≈63dp）、无边框；
///  · 图2 → 方案三：块宽 110px、圆角 ≈5px（≈2dp）、块间距 ≈1.2dp(margin 0.6)、
///    1 节课高 167px（≈69dp）、细边框。
class SchemePreset {
  const SchemePreset({
    required this.blockRadius,
    required this.blockPad,
    required this.blockMargin,
    required this.blockBorderWidth,
    required this.rowHeight,
    required this.showGridLines,
    required this.gridLineWidth,
    required this.gridLineDepth,
    required this.otherWeeksDim,
  });

  final double blockRadius;
  final double blockPad;
  final double blockMargin;
  final double blockBorderWidth;

  /// 课节高度：0 = 自动均分（沿用改造前行为）。
  final double rowHeight;
  final bool showGridLines;
  final double gridLineWidth;
  final double gridLineDepth;
  final double otherWeeksDim;

  /// 本预设覆盖的显示设置键 —— 也是「自定义优先」的判定范围。
  static const Set<String> keys = <String>{
    'blockRadius',
    'blockPad',
    'blockMargin',
    'blockBorderWidth',
    'rowHeight',
    'showGridLines',
    'gridLineWidth',
    'gridLineDepth',
    'otherWeeksDim',
  };

  /// 展开成 display settings 的补丁（多 key 一起写）。
  Map<String, dynamic> toDisplayPatch() => <String, dynamic>{
        'blockRadius': blockRadius,
        'blockPad': blockPad,
        'blockMargin': blockMargin,
        'blockBorderWidth': blockBorderWidth,
        'rowHeight': rowHeight,
        'showGridLines': showGridLines,
        'gridLineWidth': gridLineWidth,
        'gridLineDepth': gridLineDepth,
        'otherWeeksDim': otherWeeksDim,
      };

  /// 从一份 display settings 里**摘出本预设覆盖的那几个键的当前值**。
  ///
  /// 用途：切换方案时，先把「当前方案自己那套值」原样存下来（见
  /// [CourseStorage.switchScheme]）。
  static Map<String, dynamic> appearanceOf(Map<String, dynamic> display) =>
      <String, dynamic>{
        for (final k in keys)
          if (display.containsKey(k)) k: display[k],
      };

  /// 取某方案的外观预设。
  static SchemePreset of(CourseColorScheme s) {
    switch (s) {
      case CourseColorScheme.standard:
        // 方案一 = 改造前的中性观感，值就是出厂默认（谁手调过也不会被它带跑）
        return const SchemePreset(
          blockRadius: 6,
          blockPad: 3.0,
          blockMargin: 1.8,
          blockBorderWidth: 0.8,
          rowHeight: 0,
          showGridLines: true,
          gridLineWidth: 1.0,
          gridLineDepth: 0.5,
          otherWeeksDim: 0.75,
        );
      case CourseColorScheme.soft:
        // 方案二（复刻图 1）：圆角大、块间距略宽、无边框、课节 63
        return const SchemePreset(
          blockRadius: 8,
          blockPad: 4.5,
          blockMargin: 1.5,
          blockBorderWidth: 0,
          rowHeight: 63,
          showGridLines: true,
          gridLineWidth: 1.0,
          gridLineDepth: 0.3,
          otherWeeksDim: 0.78,
        );
      case CourseColorScheme.vivid:
        // 方案三（复刻图 2）：圆角很小、块几乎贴满、细边框、课节 69
        return const SchemePreset(
          blockRadius: 2,
          blockPad: 4.0,
          blockMargin: 0.6,
          blockBorderWidth: 0.8,
          rowHeight: 69,
          showGridLines: true,
          gridLineWidth: 1.0,
          gridLineDepth: 0.35,
          otherWeeksDim: 0.75,
        );
    }
  }
}
