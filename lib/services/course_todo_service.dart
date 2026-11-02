import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/course_model.dart';
import '../models/todo.dart';
import '../repositories/todo_repository.dart';
import 'course_storage.dart';
import '../widgets/course_grid_widgets.dart' show CourseBlock, kDefaultCourseBlocks;

/// 「课程 → 待办」联动服务。
///
/// 课表页会把「今日课程」同步为待办（标题 `【课程】课程名`，id `course_<courseId>_<yyyymmdd>`）。
/// 本服务负责反向联动：**课程结束后把对应的待办自动划掉（标记完成）**。
///
/// 判定完全由「课程自身数据」推导，不依赖任何新增字段，因此对历史待办同样生效：
///   课程待办 id → 反查课程 → 用节次结束时刻表算出结束时间 → 早于当前时间即完成。
class CourseTodoService {
  CourseTodoService._();

  /// 同步串行锁：首页启动（整周）与切日期（单日）可能**同时**触发同步，
  /// 两边各自读到的「已有 id 快照」都还没包含对方刚写的记录 → 会重复插入
  /// 同一条待办（列表出现两条一模一样的东西）。这里用一条 Future 链把
  /// 所有同步排队，串行执行。
  static Future<void> _syncLock = Future<void>.value();

  static Future<T> _exclusive<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final prev = _syncLock;
    _syncLock = prev.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// 课程待办 id 约定：**日期必须补零**。
  ///
  /// 旧写法 `year+month+day` 会撞号：2026-01-12 与 2026-11-02 都得到
  /// 「2026112」。撞号后 `completeMany(ids)` 按 id 批量完成，会把**未来日期**
  /// 的课程待办一起划掉 —— 表现为「未来日期却显示课程已完成」。
  static String courseTodoId(Course c, DateTime day) {
    final m = day.month.toString().padLeft(2, '0');
    final d = day.day.toString().padLeft(2, '0');
    return 'course_${c.id}_${day.year}$m$d';
  }

  /// 「id + 日期」复合键：判断某条待办是否已存在时必须同时看日期，
  /// 否则历史库里同 id 不同日期的记录会互相干扰。
  static String _idOn(String id, DateTime day) {
    final m = day.month.toString().padLeft(2, '0');
    final d = day.day.toString().padLeft(2, '0');
    return '$id@${day.year}$m$d';
  }

  // ─────────────────────────────────────────────────────────────
  // 「用户主动删除」抑制集合
  // ─────────────────────────────────────────────────────────────

  /// 用户删掉的课程待办，键与同步层完全同一套：[_idOn]。
  ///
  /// 🔴 为什么需要（2026-11-02 用户报告「课程待办删不掉」）：
  ///    课程待办的唯一真相是**课表** —— [syncCoursesForDate] 每次加载都会
  ///    比对「这天有这门课」与「库里有这条待办」，缺了就补一条。
  ///    于是用户滑删后：`_deleteTodo` → `delete` → `_load()` →
  ///    `syncCoursesForDate` → 库里没有 → **立刻重建**。
  ///    用户看到的就是「删了又回来，永远删不掉」。
  ///
  ///    退课是另一回事（走 `dropped_course_keys`，会影响课表显示）；
  ///    这里只表达「这节课我不想要这条待办」。
  ///
  /// ⚠️ 撤销删除 / 用户重新添加时必须 [unsuppress]，否则「撤销」失效。
  static const String _kSuppressed = 'course_todo_suppressed_v1';

  /// 内存缓存：避免每次同步都读一遍 SharedPreferences。
  static Set<String>? _suppressedCache;

  static Future<Set<String>> _loadSuppressed() async {
    final cached = _suppressedCache;
    if (cached != null) return cached;
    try {
      final sp = await SharedPreferences.getInstance();
      _suppressedCache =
          (sp.getStringList(_kSuppressed) ?? const <String>[]).toSet();
    } catch (_) {
      _suppressedCache = <String>{};
    }
    return _suppressedCache!;
  }

  /// 判断某条课程待办是否被用户主动删除过。
  static Future<bool> isSuppressed(String id, DateTime day) async =>
      (await _loadSuppressed()).contains(_idOn(id, day));

  /// 登记「用户删掉了这条课程待办」。
  ///
  /// 顺手自清理：只保留今天及以后的键 —— 过去的日期不会再被同步，
  /// 过期键留着只会让集合无限增长。
  static Future<void> suppress(String id, DateTime day) async {
    final set = await _loadSuppressed();
    set.add(_idOn(id, day));
    final n = DateTime.now();
    final todayDay = DateTime(n.year, n.month, n.day);
    set.removeWhere((k) {
      final at = k.indexOf('@');
      if (at < 0) return true;
      final raw = k.substring(at + 1);
      if (raw.length != 8) return true;
      final y = int.tryParse(raw.substring(0, 4));
      final m = int.tryParse(raw.substring(4, 6));
      final d = int.tryParse(raw.substring(6, 8));
      if (y == null || m == null || d == null) return true;
      return DateTime(y, m, d).isBefore(todayDay);
    });
    await _saveSuppressed(set);
  }

  /// 解除抑制：用户撤销删除，或重新手动添加了同一天的同一条。
  static Future<void> unsuppress(String id, DateTime day) async {
    final set = await _loadSuppressed();
    if (set.remove(_idOn(id, day))) {
      await _saveSuppressed(set);
    }
  }

  static Future<void> _saveSuppressed(Set<String> set) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(_kSuppressed, set.toList()..sort());
    } catch (_) {
      // 存不下就只留内存态：本次会话仍生效，重启后会重建一条待办。
      // 不能因此抛异常打断删除流程。
    }
  }

  /// 仅供测试：清空内存缓存。
  @visibleForTesting
  static void debugResetSuppressedCache() => _suppressedCache = null;

  /// 去重键：**日期 + 标题 + 描述**。
  ///
  /// 必须带日期 —— 同一门课同节次在不同日期的 title/description 完全一样，
  /// 不带日期会把「另一天的同一节课」误判成重复，导致那天没有待办。
  static String _keyOf(DateTime day, String title, String desc) {
    final m = day.month.toString().padLeft(2, '0');
    final d = day.day.toString().padLeft(2, '0');
    return '${day.year}$m$d|$title|$desc';
  }

  /// 旧版（未补零）id，仅用于**迁移**：把历史数据改名成新 id。
  static String legacyCourseTodoId(Course c, DateTime day) =>
      'course_${c.id}_${day.year}${day.month}${day.day}';

  /// 把指定日期的所有课程同步成当天待办（去重）。
  ///
  /// 首页切到任意日期时调用，保证「有课的日期」都能看到对应课程待办，
  /// 不再要求用户先进课表页才生成。
  static Future<int> syncCoursesForDate(DateTime day) {
    return _exclusive(() => _syncCoursesForDateInner(day));
  }

  static Future<int> _syncCoursesForDateInner(DateTime day) async {
    try {
      final courses = await CourseStorage.loadCourses();
      if (courses.isEmpty) return 0;
      final start = await CourseStorage.loadSemesterStart() ??
          CourseStorage.defaultSemesterStart(day);
      final blocks = await _blocks();
      final existing = await TodoRepository.instance.getByDate(day);
      return await _syncDay(
        courses: courses,
        start: start,
        blocks: blocks,
        day: day,
        existingIds: existing.map((t) => _idOn(t.id, day)).toSet(),
        existingKeys: existing
            .map((t) => _keyOf(day, t.title, t.description ?? ''))
            .toSet(),
        suppressed: await _loadSuppressed(),
      );
    } catch (_) {
      return 0;
    }
  }

  /// 单日同步内核：课程/时间块/已有待办只准备一次，循环复用。
  static Future<int> _syncDay({
    required List<Course> courses,
    required DateTime start,
    required List<CourseBlock> blocks,
    required DateTime day,
    required Set<String> existingIds,
    required Set<String> existingKeys,
    required Set<String> suppressed,
  }) async {
    final week = CourseStorage.teachingWeek(day, start);
    final dayCourses =
        courses.where((c) => c.occursOn(day.weekday, week)).toList();
    if (dayCourses.isEmpty) return 0;
    var added = 0;
    final pending = <Todo>[];
    for (final c in dayCourses) {
      final id = courseTodoId(c, day);
      final legacyId = legacyCourseTodoId(c, day);
      final idKey = _idOn(id, day);
      final legacyKey = _idOn(legacyId, day);
      final slotText = '第${c.startSlot}-${c.endSlot}节';
      final marker = '【课程】${c.name}';
      // 去重键带日期 + 落库字段（title + description）
      final key = _keyOf(day, marker, '${c.classroom} · $slotText');
      // 旧 id（未补零）迁移：把**同一天**的旧记录改成新 id。
      //
      // ⚠️ 旧 id 有歧义（2026112 既可能是 01-12 也可能是 11-02），
      //    所以必须**同时校验日期**，否则会误改别人那天的待办。
      // ⚠️ 不能「删了重建」：过去日期的课程待办已经被自动划掉（completed），
      //    重建会把完成状态弄丢 —— 这里直接**改 id**，保留完成状态与重复规则。
      if (legacyId != id && existingIds.contains(legacyKey)) {
        final all = await TodoRepository.instance.getAll();
        final renamed = <Todo>[];
        final toDelete = <Todo>[];
        for (final old in all.where((t) =>
            t.id == legacyId &&
            t.date.year == day.year &&
            t.date.month == day.month &&
            t.date.day == day.day)) {
          // 🔴 改名时**不继承** legacy 行的完成态。
          //
          // 旧 id 未补零会撞号（`course_5_2026112` 既是 01-12 又是 11-02），
          // 库里可能有多行同 id 的脏数据，其中某一行带着 `completed=true`
          // （那是历史上被误划的）。若原样继承，脏完成态会被搬进**新 id**
          // 这条权威记录 → 用户看到「明日课程莫名已完成」，且
          // `autoCompleteFinishedCourses` 看到它已完成就跳过 → 永远修不好。
          //
          // 正确做法：完成态由 [Todo.completedDay] 按天归属，
          // 迁移时只保留「这一行自己那天确实完成过」的信息。
          final keepDone = old.completedDay == old.dayKey;
          // ⚠️ keepDone == false 时必须 clearCompletedDay：只传
          //    `completedDay: null` 是「保留旧值」→ 脏完成态会被搬进新 id。
          renamed.add(old.copyWith(
            id: id,
            completed: keepDone,
            completedDay: keepDone ? old.dayKey : null,
            clearCompletedDay: !keepDone,
          ));
          toDelete.add(old);
        }
        if (renamed.isNotEmpty) {
          // ⚠️ 按 (id, 日期) 去重：同 id 同日期可能有多行（历史 add() 盲追加
          //    造成），addMany 会**静默丢掉除最后一条外的所有行** →
          //    其中一条的完成态就消失了。保留「完成过」的那一条。
          final byKey = <String, Todo>{};
          for (final t in renamed) {
            final k = t.compositeKey;
            final prev = byKey[k];
            if (prev == null || (t.completed && !prev.completed)) {
              byKey[k] = t;
            }
          }
          await TodoRepository.instance.addMany(byKey.values.toList());
          for (final old in toDelete) {
            // ⚠️ 必须按 id + 日期删：库里可能有**同 id 不同日期**的记录，
            //    用只按 id 的 delete 会连带删掉另一日期的待办。
            await TodoRepository.instance.deleteOn(old);
          }
        }
        existingIds.remove(legacyKey);
        // 改名后新 id 已存在 → 标记为「已有」，避免再插一条重复的。
        existingIds.add(idKey);
      }
      if (existingIds.contains(idKey) || existingKeys.contains(key)) {
        continue;
      }
      // 🔴 用户主动删除过这条 → 不要重建（否则「删了又回来」）。
      if (suppressed.contains(idKey)) continue;
      DateTime? reminder;
      for (final b in blocks) {
        if (c.startSlot >= b.start && c.startSlot <= b.end) {
          final parts = b.time.split(String.fromCharCode(10));
          final hm = parts.isNotEmpty ? parts.first.trim().split(':') : const [];
          if (hm.length == 2) {
            final h = int.tryParse(hm[0]);
            final m = int.tryParse(hm[1]);
            if (h != null && m != null) {
              reminder = DateTime(day.year, day.month, day.day, h, m);
            }
          }
          break;
        }
      }
      pending.add(Todo(
        id: id,
        title: marker,
        description: '${c.classroom} · $slotText',
        date: DateTime(day.year, day.month, day.day),
        reminderTime: reminder,
        completed: false,
      ));
      existingIds.add(idKey);
      existingKeys.add(key);
      added++;
    }
    // 一次性写入：逐条 add 会 N 次读全表+写全表，7 天课程同步时明显卡顿。
    await TodoRepository.instance.addMany(pending);
    return added;
  }

  /// 同步某一天所在周的全部 7 天课程待办。
  ///
  /// 课程、时间块、已有待办**只读一次**，循环 7 天复用 —— 之前一周要读 7 遍
  /// 课程表和待办表，拖动周次条时每切一天就重读一遍，卡顿明显。
  static Future<int> syncCoursesForWeek(DateTime anchor) {
    return _exclusive(() => _syncCoursesForWeekInner(anchor));
  }

  static Future<int> _syncCoursesForWeekInner(DateTime anchor) async {
    try {
      final courses = await CourseStorage.loadCourses();
      if (courses.isEmpty) return 0;
      final start = await CourseStorage.loadSemesterStart() ??
          CourseStorage.defaultSemesterStart(anchor);
      final blocks = await _blocks();
      final all = await TodoRepository.instance.getAll();
      // ⚠️ 必须带日期：历史库里存在**同 id 不同日期**的课程待办
      //    （旧 id 未补零会撞号 + 旧版 add 不去重）。
      //    只按 id 判存在 → 别的日期先有记录，当天这条就**不会生成**，
      //    表现为「有课却没有待办」。
      final existingIds = all.map((t) => _idOn(t.id, t.date)).toSet();
      final existingKeys = all
          .map((t) => _keyOf(t.date, t.title, t.description ?? ''))
          .toSet();
      // 周同步一次读够，别在 7 天循环里读 7 遍。
      final suppressed = await _loadSuppressed();
      final day = DateTime(anchor.year, anchor.month, anchor.day);
      final monday = day.subtract(Duration(days: day.weekday - 1));
      var total = 0;
      for (var i = 0; i < 7; i++) {
        total += await _syncDay(
          courses: courses,
          start: start,
          blocks: blocks,
          day: monday.add(Duration(days: i)),
          existingIds: existingIds,
          existingKeys: existingKeys,
          suppressed: suppressed,
        );
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static Future<List<CourseBlock>> _blocks() async {
    final raw = await CourseStorage.loadTimeBlocks();
    if (raw == null || raw.isEmpty) return kDefaultCourseBlocks;
    return raw.map(CourseBlock.fromJson).toList();
  }

  /// 修复**脏数据**：未来日期的课程待办被错误标成「已完成」。
  ///
  /// 🔴 为什么会脏：早期版本的课程待办 id 未补零（`course_5_2026112`
  ///    既可能是 01-12 也可能是 11-02），批量完成按 id 匹配时会把
  ///    **未来日期**那条一起划掉。这条脏数据一旦写进库里，
  ///    [autoCompleteFinishedCourses] 只处理「未完成」的记录 → **永远修不回来**，
  ///    用户切到未来日期就会看到早上的课显示成已完成。
  ///
  /// 现在每次同步/加载时都做一次**自愈**：把日期在今天之后、
  /// 却被标完成的课程待办重置为未完成。
  static Future<int> repairFutureCompletedCourses({DateTime? now}) async {
    try {
      final n = now ?? DateTime.now();
      final today = DateTime(n.year, n.month, n.day);
      final all = await TodoRepository.instance.getAll();
      final bad = all
          .where((t) =>
              t.completed &&
              t.id.startsWith('course_') &&
              DateTime(t.date.year, t.date.month, t.date.day).isAfter(today))
          .toList();
      if (bad.isEmpty) return 0;

      // 🔴 按 **(id, 日期)** 定位写回。
      //    原来用 `update()`，而 update 是「按 id 首个匹配」→ 库里有同 id
      //    不同日期的两行时，会把**别的行**整行覆盖（含它的 date！），
      //    结果：真正要修的未来行永远修不好，反而把历史记录改没了。
      var fixed = 0;
      for (final t in bad) {
        // 完成态按天归属：未来日期的「已完成」既清 completed 也清 completedDay。
        await TodoRepository.instance.updateOn(
          t.copyWith(completed: false, clearCompletedDay: true),
        );
        fixed++;
      }
      return fixed;
    } catch (_) {
      return 0;
    }
  }

  /// 课程待办**改期**：同步改 id + 日期，保住 id 与 date 的绑定。
  ///
  /// 🔴 为什么必须改 id（2026-10-31）：
  ///    课程待办 id 是**派生**的（`course_<课程id>_<yyyyMMdd>`），日期就在 id 里。
  ///    用户把课程待办改到别的日期时，如果只改 `date` 不改 `id`：
  ///      · `autoCompleteFinishedCourses` 用「id ↔ 课程 + 日期」反查，
  ///        id 里还写着旧日期 → 匹配不上 → 这条**永远不会被自动完成**；
  ///      · 新一天的同步按「日期 + 标题 + 描述」去重，会把这条被改过的
  ///        当成「那天已同步」→ **那天的课程待办不会生成**；
  ///      · 再切回旧日期，同步又把日期改回去 → **用户的编辑被静默回滚**。
  ///
  /// 所以改期必须同时改 id，让三者始终自洽。
  static Future<bool> moveCourseTodo(Todo original, Todo updated) async {
    try {
      final courseId = _courseIdOf(original.id);
      if (courseId == null) return false; // 不是课程待办 → 不处理
      final target =
          DateTime(updated.date.year, updated.date.month, updated.date.day);
      final oldDay =
          DateTime(original.date.year, original.date.month, original.date.day);
      if (target == oldDay) {
        // 日期没变 → 走普通更新即可（不动 id）。
        return await TodoRepository.instance.update(updated);
      }
      final newId = 'course_${courseId}_${target.year}'
          '${target.month.toString().padLeft(2, '0')}'
          '${target.day.toString().padLeft(2, '0')}';

      // 新 id 已存在（同一天同课程已有记录）→ 放弃改期，避免覆盖。
      final all = await TodoRepository.instance.getAll();
      final clash = all.any((t) =>
          t.id == newId &&
          t.date.year == target.year &&
          t.date.month == target.month &&
          t.date.day == target.day);
      if (clash) return false;

      // 提醒时间跟着日期平移（保持时分不变）。
      final reminder = updated.reminderTime == null
          ? null
          : DateTime(target.year, target.month, target.day,
              updated.reminderTime!.hour, updated.reminderTime!.minute);

      // 先写新记录，再删旧记录：顺序反了会在中间态丢数据。
      // ⚠️ 写的是**完整的 updated**（含标题/描述/优先级等所有改动），
      //    不能只写日期 —— 否则调用方后续再 update 会找不到旧记录，
      //    其余字段的修改就丢了。
      await TodoRepository.instance.add(updated.copyWith(
        id: newId,
        date: target,
        reminderTime: reminder,
        clearReminder: reminder == null,
        // 改期后完成态按新日期归属（旧完成态属于旧日期，不该带过去）。
        completed: false,
        clearCompletedDay: true,
      ));
      await TodoRepository.instance.deleteOn(original);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// **一次性历史数据迁移**：清理课程待办里的同 id 撞号脏数据。
  ///
  /// 🔴 背景（2026-10-31）：
  ///    课程待办 id 是**派生**的（`course_<课程id>_<yyyyMMdd>`），旧版本没补零，
  ///    `2026-01-12` 与 `2026-11-02` 会撞成同一个 `course_5_2026112`；
  ///    再叠加旧 `add()` 的盲追加，库里可能存在**同 id 不同日期**的多行。
  ///    这类脏数据会引发：查看明日待办时课程被默认完成、完成态延续到今日、
  ///    删除一条连带删掉另一天、勾选一条改到另一天。
  ///
  ///    本次迁移做三件事：
  ///    1. 把未补零的 legacy id 按**行自身的日期**改写成补零 id；
  ///    2. 同 (新 id, 日期) 的重复行合并成一条（保留已完成的那条）；
  ///    3. 给每条课程待办回填 `completedDay`（完成态归属日），
  ///       未来日期却是「已完成」的**一律重置**（这正是老 bug 的产物）。
  ///
  /// 迁移幂等：跑过一次后再跑不会有新变化（返回 0）。
  static Future<int> migrateCourseTodoHistory({DateTime? now}) async {
    try {
      final n = now ?? DateTime.now();
      final today = DateTime(n.year, n.month, n.day);
      final all = await TodoRepository.instance.getAll();
      if (all.isEmpty) return 0;

      // 1) legacy id → 补零 id（按**行自身日期**算，不按 id 里解析的日期 ——
      //    撞号的 id 本身就有歧义，只有行日期是可信的）。
      final renamed = <Todo>[];
      for (final t in all) {
        if (!t.id.startsWith('course_')) continue;
        final courseId = _courseIdOf(t.id);
        if (courseId == null) continue;
        final padded = courseTodoId(_fakeCourse(courseId), t.date);
        if (padded == t.id) continue;
        renamed.add(t.copyWith(id: padded));
      }

      var changed = 0;
      if (renamed.isNotEmpty) {
        // 2) 按 (新 id, 日期) 去重：保留「已完成」的那条。
        final byKey = <String, Todo>{};
        for (final t in renamed) {
          final k = t.compositeKey;
          final prev = byKey[k];
          if (prev == null || (t.completed && !prev.completed)) {
            byKey[k] = t;
          }
        }
        await TodoRepository.instance.addMany(byKey.values.toList());
        // 删掉旧的 legacy 行（按 id + 日期精确删）。
        for (final t in all) {
          if (!t.id.startsWith('course_')) continue;
          final courseId = _courseIdOf(t.id);
          if (courseId == null) continue;
          if (courseTodoId(_fakeCourse(courseId), t.date) == t.id) continue;
          await TodoRepository.instance.deleteOn(t);
        }
        changed += byKey.length;
      }

      // 3) 回填 completedDay + 重置未来脏完成态。
      final current = await TodoRepository.instance.getAll();
      for (final t in current) {
        if (!t.id.startsWith('course_')) continue;
        final isFuture =
            DateTime(t.date.year, t.date.month, t.date.day).isAfter(today);
        if (isFuture && t.completed) {
          // 未来日期却被标完成 = 老 bug 的产物，一律重置。
          await TodoRepository.instance.updateOn(
            t.copyWith(completed: false, clearCompletedDay: true),
          );
          changed++;
          continue;
        }
        if (t.completed && t.completedDay == null) {
          // 回填完成归属日：这条完成属于它自己那天。
          await TodoRepository.instance.updateOn(
            t.copyWith(completedDay: t.dayKey),
          );
          changed++;
        }
      }
      return changed;
    } catch (_) {
      return 0;
    }
  }

  /// 从课程待办 id 里取出「课程 id」部分。
  ///
  /// id 形如 `course_<课程id>_<日期串>`。课程 id 本身可能含下划线，
  /// 所以从**末尾**倒着找最后一段下划线来切分。
  static String? _courseIdOf(String todoId) {
    if (!todoId.startsWith('course_')) return null;
    final rest = todoId.substring('course_'.length);
    final idx = rest.lastIndexOf('_');
    if (idx <= 0) return null;
    return rest.substring(0, idx);
  }

  /// 造一个只用来算 id 的占位课程（只需要 [Course.id]）。
  static Course _fakeCourse(String id) => Course(
        id: id,
        name: '',
        weekday: 1,
        startSlot: 1,
        endSlot: 1,
        colorValue: 0,
      );

  /// 自动完成「今天已结束的课程」对应的待办，返回本次划掉的条数。
  /// 任何异常都静默返回 0，绝不影响主页渲染。
  static Future<int> autoCompleteFinishedCourses({DateTime? now}) async {
    try {
      final n = now ?? DateTime.now();
      final today = DateTime(n.year, n.month, n.day);
      final all = await TodoRepository.instance.getAll();
      final pending = all
          .where((t) => !t.completed && t.id.startsWith('course_'))
          .toList();
      if (pending.isEmpty) return 0;

      final courses = await CourseStorage.loadCourses();
      if (courses.isEmpty) return 0;
      final start = await CourseStorage.loadSemesterStart() ??
          CourseStorage.defaultSemesterStart(today);
      final endMap = await CourseStorage.loadSlotEndMap();

      // (id, 该待办自己的日期)：批量完成时按这一对精确匹配。
      //
      // ⚠️ 这里**不能用 Map<id, day>**：历史库里存在同 id 不同日期的记录
      //    （旧 id 未补零会撞号），Map 会让后一条覆盖前一条的日期 →
      //    前一条永远划不掉，或划错那条。用 List 保留每一对。
      final finished = <({String id, DateTime day})>[];
      for (final t in pending) {
        // 只处理「今天及更早」的课程待办；未来日期不处理。
        final d = DateTime(t.date.year, t.date.month, t.date.day);
        if (d.isAfter(today)) continue;
        Course? course;
        for (final c in courses) {
          if (courseTodoId(c, d) == t.id || legacyCourseTodoId(c, d) == t.id) {
            course = c;
            break;
          }
        }
        if (course == null) continue;
        // 二次确认：这门课确实在这一天有课，且**这天不晚于今天**。
        // 否则宁可漏划，也不误划未来日期。
        final week = CourseStorage.teachingWeek(d, start);
        if (!course.occursOn(d.weekday, week)) continue;
        final hhmm = endMap[course.endSlot];
        if (hhmm == null) continue;
        final parts = hhmm.split(':');
        final h = int.tryParse(parts[0]);
        final m = parts.length > 1 ? int.tryParse(parts[1]) : null;
        if (h == null || m == null) continue;
        final end = DateTime(d.year, d.month, d.day, h, m);
        if (end.isBefore(n)) finished.add((id: t.id, day: d));
      }
      if (finished.isEmpty) return 0;
      return await TodoRepository.instance.completeManyWithDays(finished);
    } catch (_) {
      return 0;
    }
  }
}
