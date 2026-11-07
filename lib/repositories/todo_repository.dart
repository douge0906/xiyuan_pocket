import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show DateTimeComponents;
import 'package:shared_preferences/shared_preferences.dart';

import '../database/todo_database.dart';
import '../models/todo.dart';
import '../services/notification_service.dart';

/// 一条待办要排的**一个**通知。
///
/// 为什么需要「一个待办 → 多条通知」：重复待办交给系统按周/按天自己推进，
/// 而系统的一条重复通知只能表达「每周的某一个星期 X」。用户选「每周一三五」
/// 时就必须拆成三条，各自绑定自己的星期。
@immutable
class TodoReminderPlan {
  const TodoReminderPlan({required this.id, required this.when, this.match});

  /// 通知 id（见 [TodoRepository.reminderIdsFor]）。
  final int id;

  /// 首次触发时刻；有 [match] 时系统会自己推到下一个匹配点。
  final DateTime when;

  /// 重复规则；null = 一次性。
  final DateTimeComponents? match;
}

/// 待办业务仓库（唯一入口）。
///
/// 职责：
/// - 对上层（页面 / 后台入口）暴露高层 CRUD 语义；
/// - 内部编排 [TodoDatabase]（持久化）与 [NotificationService]（通知）；
/// - 保证「数据落库」与「通知调度」始终一致（新增即排、完成即取消、删除即取消等）。
///
/// 约束：
/// - 页面**不得**直接操作数据库或通知，一律经本仓库；
/// - 通知 id 恒等于 [Todo.notifyId]（由 id 确定性推导），
///   因此 schedule / cancel 永远命中同一条通知。
///   例外：重复待办按星期拆成多条时 id = `notifyId + 星期 * 1000`，
///   见 [reminderIdsFor]。
class TodoRepository {
  TodoRepository._();
  static final TodoRepository instance = TodoRepository._();

  final TodoDatabase _db = TodoDatabase.instance;

  /// 写操作串行锁。
  ///
  /// 🔴 为什么必须有：所有写方法都是「readAll → 改内存列表 → writeAll」，
  ///    两个并发写（典型：课程待办同步的 addMany 与用户手动新增同时进来）
  ///    会各自读到同一份快照，后写者把前写者的记录整个覆盖 —— 丢一条待办
  ///    且无任何报错。course_todo_service.dart 的 _syncLock 是同一套做法。
  static Future<void> _writeLock = Future<void>.value();

  static Future<T> _exclusive<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final prev = _writeLock;
    _writeLock = prev.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// 本仓库「已排上」的待办通知 id 集合（持久化）。
  ///
  /// 为什么要记录：Android 重启/强停后 AlarmManager 会清空定时任务，App 启动需要
  /// 重排一次；重排前必须先把上轮可能残留（对应待办已被删除）的通知清掉，否则会
  /// 留下永远无法取消的「幽灵提醒」。
  ///
  /// v2.4.0 修复：此前用的是 [NotificationService.cancelAll]（全局清空），会把
  /// 上课提醒（id 段 100000..100140）一并清掉，导致待办重排后上课提醒静默消失。
  /// 现改为「只精确取消本仓库排过的 id」，与上课提醒彻底隔离。
  static const String _kScheduledIds = 'todo_scheduled_notify_ids';

  /// 「开启待办提醒」全局开关（通知与提醒页）。
  ///
  /// 默认 true = 默认开启。开关只门控「是否真正把通知排进系统」，
  /// 不改 [Todo.reminderTime]：关闭时新建的待办仍带提醒时刻，只是不响；
  /// 重新打开后走一次 [rescheduleAll] 就能把已有待办全部补排回来。
  static const String _kTodoReminderEnabled = 'todo_reminder_enabled';

  static Future<bool> todoReminderEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kTodoReminderEnabled) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setTodoReminderEnabled(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kTodoReminderEnabled, value);
    } catch (_) {
      // 偏好写入失败不应阻塞提醒排程
    }
  }

  // ---------------------------------------------------------------------------
  // 身份键：id **不够用**，必须用 (id, 日期)
  // ---------------------------------------------------------------------------

  /// 定位一条待办在库中的下标。
  ///
  /// 🔴 为什么不能只按 id（2026-10-31）：
  ///    课程待办的 id 是**派生**出来的（`course_<课程id>_<yyyyMMdd>`），
  ///    历史版本没补零时 `2026-01-12` 与 `2026-11-02` 会撞成同一个
  ///    `course_5_2026112`。库里一旦存在**同 id 不同日期**的两行，
  ///    任何「按 id 首个匹配」的写路径都会改到**别的行**上：
  ///      · 勾选明日课程 → 改成了 1 月 12 日那行；
  ///      · 删明日课程 → 连带删掉另一天的历史记录；
  ///      · 「自愈未来脏数据」→ 把未来行的日期写到别的行上，
  ///        结果未来行永远修不好、反而把历史记录改没了。
  ///
  ///    真正的身份是 **(id, 日期)** —— 见 [Todo.compositeKey]。
  static int _indexOf(List<Todo> list, Todo todo) {
    return list.indexWhere((t) =>
        t.id == todo.id && _sameDay(t.date, todo.date));
  }

  // ---------------------------------------------------------------------------
  // 查询
  // ---------------------------------------------------------------------------

  /// 全部待办。
  Future<List<Todo>> getAll() => _db.readAll();

  /// 指定日期的待办。
  ///
  /// 🔴 用 [Todo.occursOn] 而不是「date 精确相等」：重复待办的 date 只是
  ///    **起始日**，按精确匹配会让它在次日从列表里消失。
  ///    课程待办是非重复的，occursOn 与精确匹配等价，不受影响。
  Future<List<Todo>> getByDate(DateTime day) async {
    final all = await _db.readAll();
    return all.where((t) => t.occursOn(day)).toList();
  }

  // ---------------------------------------------------------------------------
  // 写入 —— 每个方法都保证「库」与「通知」同步
  // ---------------------------------------------------------------------------

  /// 新增待办：落库 + （若设置了将来的提醒且未完成）立即创建通知。
  Future<void> add(Todo todo) => _exclusive(() async {
    final list = await _db.readAll();
    // 同 **(id, 日期)** 覆盖而不是追加：任何并发/重试都不该产生两条一样的待办。
    // ⚠️ 不能只按 id：同 id 不同日期是**两条不同的待办**（见 [_indexOf] 注释）。
    final idx = _indexOf(list, todo);
    if (idx >= 0) {
      list[idx] = todo;
    } else {
      list.add(todo);
    }
    await _db.writeAll(list);
    await _syncNotification(todo);
  });

  /// 批量新增：一次读表、一次写表、逐条排通知。
  ///
  /// 为什么要批量：课程待办同步一次可能要写十几条（7 天 × 每天几门课），
  /// 逐条 add() 就是 N 次「读全表 + 写全表」+ N 次通知排程 → 首屏明显卡顿。
  Future<void> addMany(List<Todo> todos) => _exclusive(() async {
    if (todos.isEmpty) return;
    final list = await _db.readAll();
    // ⚠️ 索引键必须是 **(id, 日期)** 而不是 id：
    //    同 id 不同日期是两条不同的待办，按 id 建索引会让后一条**静默覆盖**
    //    前一条（同 id 撞号时会把「另一天的完成态」搬进新记录）。
    final indexByKey = <String, int>{
      for (var i = 0; i < list.length; i++) list[i].compositeKey: i
    };
    final added = <Todo>[];
    for (final todo in todos) {
      final key = todo.compositeKey;
      final idx = indexByKey[key];
      if (idx == null) {
        indexByKey[key] = list.length;
        list.add(todo);
      } else {
        list[idx] = todo;
      }
      added.add(todo);
    }
    await _db.writeAll(list);
    for (final t in added) {
      await _syncNotification(t);
    }
  });

  /// 批量标记完成（**按 id + 日期**精确匹配）。
  ///
  /// ⚠️ 为什么必须带日期：历史课程待办 id 是**未补零**的
  /// （`course_5_2026112` 既可能是 01-12 也可能是 11-02），只按 id 匹配
  /// 会把**未来日期**的那条一起划掉 —— 表现为「未来日期却显示课程已完成」。
  /// 这里额外校验日期，确保只动当天那条。
  Future<int> completeManyWithDays(
          List<({String id, DateTime day})> targets) =>
      _exclusive(() async {
    if (targets.isEmpty) return 0;
    final list = await _db.readAll();
    final hit = <Todo>[];
    var changed = 0;
    for (var i = 0; i < list.length; i++) {
      final t = list[i];
      // 找到 (id, 日期) 完全匹配的那一条才动。
      // 找出匹配的那一天（(id, 日期) 复合键）。
      DateTime? matchedDay;
      for (final x in targets) {
        if (x.id == t.id && _sameDay(t.date, x.day)) {
          matchedDay = x.day;
          break;
        }
      }
      if (matchedDay == null) continue;
      if (t.completed) continue;
      // 🔴 完成态**按天归属**：记录「这条完成属于哪一天」。
      //    这样即使库里存在同 id 不同日期的两行，完成态也天然隔离，
      //    不会「查看明日待办时课程默认完成、状态延续到今日」。
      list[i] = t.copyWith(
        completed: true,
        completedDay: Todo.dayKeyOf(matchedDay),
      );
      hit.add(list[i]);
      changed++;
    }
    if (changed == 0) return 0;
    await _db.writeAll(list);
    for (final t in hit) {
      await _cancelAllFor(t);
    }
    return changed;
  });

  /// 编辑待办：落库 + 先取消旧通知再按最新提醒时间重排。
  /// 因 notifyId 由 id 推导、id 不随编辑改变，取消/重排命中同一 id，天然幂等。
  ///
  /// 返回 false = 库里没有匹配记录，调用方应当提示用户而不是假装成功。
  Future<bool> update(Todo input) => _exclusive(() async {
    // 🔴 把「已完成的待办」改成每天 / 每周时，completed 必须一起清掉。
    //
    // 编辑走 base.copyWith 且刻意不传 completed（那是正确做法，避免把完成态
    // 冲掉），于是「已完成 → 改成每日」会留下 completed: true 的重复待办：
    //   · planReminders 第一行 `if (base == null || todo.completed) return []`
    //     → 通知全部撤销；
    //   · 而 isDoneOn 对重复待办改读 completedDates（空）→ 列表显示未完成。
    // 用户得到一条「看起来没打勾、但永远不提醒」的待办，下拉刷新也不自愈。
    // 放在仓库层而不是弹窗里：任何写入路径都必须过这一关。
    final todo = (input.isRepeating && input.completed)
        ? input.copyWith(completed: false, clearCompletedDay: true)
        : input;
    final list = await _db.readAll();
    // ⚠️ 按 (id, 日期) 定位：只按 id 会命中**另一天**的同 id 行，
    //    把整行（含 date / completed）写到它头上。
    var idx = _indexOf(list, todo);
    if (idx < 0 && !todo.id.startsWith('course_')) {
      // 普通待办的 id 是一次性生成的唯一串，**日期可以被用户改**。
      // 日期一改，(id, 日期) 复合键就变了，按复合键必然找不到 ——
      // 这里退回按 id 单键定位。课程待办不能这么退：它的 id 里编着日期，
      // 单键命中可能落到撞号的历史行上（见 [_indexOf] 注释），改期走
      // CourseTodoService.moveCourseTodo。
      idx = list.indexWhere((t) => t.id == todo.id);
    }
    if (idx < 0) {
      debugPrint('[TodoRepository] update 未命中：${todo.compositeKey}');
      return false;
    }
    list[idx] = todo;
    await _db.writeAll(list);
    // 改时间：先取消旧通知，再按新状态重建（不重复创建，同 id 覆盖）。
    // 取消要用 _cancelAllFor：重复待办可能按星期拆成好几条。
    await _cancelAllFor(todo);
    await _syncNotification(todo);
    return true;
  });

  /// 按 **(id, 日期)** 精确更新：找不到就跳过，**不会**写到别的行上。
  ///
  /// 用于「自愈脏数据」这类按天定位的写入。
  ///
  /// 🔴 2026-11-04 审查 P1：原先这里**完全不碰通知**，而
  ///    `course_todo_service.dart:393/533/541`（`repairFutureCompletedCourses`
  ///    等自愈路径）正是用它把「被误标完成」的待办改回未完成。标记完成时
  ///    `_syncNotification` 已经把提醒 cancel 掉了，这里恢复后不重排 →
  ///    那条待办**永远不再响**，直到下一次 `rescheduleAll()`（可能几天后）。
  ///    现与 [update] 保持一致：先撤干净再按新状态重排。
  Future<void> updateOn(Todo todo) => _exclusive(() async {
    final list = await _db.readAll();
    final idx = _indexOf(list, todo);
    if (idx < 0) return;
    list[idx] = todo;
    await _db.writeAll(list);
    await _cancelAllFor(todo);
    await _syncNotification(todo);
  });

  /// 删除待办：删库 + 取消通知。
  Future<void> delete(Todo todo) => _exclusive(() async {
    final list = await _db.readAll();
    // ⚠️ 按 (id, 日期) 删：只按 id 会把**另一天**的同 id 历史记录一起删掉
    //    （用户删一条今天的课程，明天的记录凭空消失）。
    final before = list.length;
    list.removeWhere((t) =>
        t.id == todo.id && _sameDay(t.date, todo.date));
    // 没命中就别写盘：整表回写 N 条 JSON 只为了把一模一样的内容再存一遍
    // （deleteOn 一直是这样判断的，这里补齐口径）。
    if (list.length == before) return;
    await _db.writeAll(list);
    await _cancelAllFor(todo);
  });

  /// 按 **id + 日期** 精确删除。
  ///
  /// 🔴 为什么需要：课程待办 id 历史上未补零（`course_5_2026112` 既是 01-12
  ///    也是 11-02），库里可能存在**同 id 不同日期**的记录。
  ///    用只按 id 的 [delete] 会把另一日期的待办连带删掉
  ///    （历史已完成记录凭空消失）。
  Future<void> deleteOn(Todo todo) => _exclusive(() async {
    final list = await _db.readAll();
    final before = list.length;
    list.removeWhere((t) =>
        t.id == todo.id &&
        t.date.year == todo.date.year &&
        t.date.month == todo.date.month &&
        t.date.day == todo.date.day);
    if (list.length == before) return;
    await _db.writeAll(list);
    await _cancelAllFor(todo);
  });

  /// 切换完成态：落库 + 完成则取消通知 / 未完成且提醒在将来则重排。
  /// 返回更新后的待办，便于调用方做乐观 UI 校正。
  Future<Todo> toggleComplete(Todo todo) => _exclusive(() async {
    final list = await _db.readAll();
    // ⚠️ 按 (id, 日期) 定位：点明日那行却改到 1 月那行是真实发生过的问题。
    final idx = _indexOf(list, todo);
    if (idx < 0) return todo;
    final cur = list[idx];
    // 完成态**按天记录**（[Todo.completedDay]）：即使 id 撞号，
    // 也不会把「某天的完成」带到「另一天」。
    // 🔴 取消完成必须用 clearCompletedDay：copyWith 的 completedDay
    //    是 `?? this.completedDay` —— 传 null 表示「不改」，不是「清空」。
    //    之前写 `completedDay: null` 等于没清，isDoneOn 仍读回旧日期 →
    //    用户点完成后**再也取消不掉**（2026-11-02 用户报告）。
    final updated = cur.copyWith(
      completed: !cur.completed,
      completedDay: cur.completed ? null : cur.dayKey,
      clearCompletedDay: cur.completed,
    );
    list[idx] = updated;
    await _db.writeAll(list);
    await _syncNotification(updated);
    return updated;
  });

  /// 切换**某一天**的完成态（2026-10-18，重复任务用）。
  ///
  /// 非重复任务等价于 [toggleComplete]；重复任务只翻转当天在
  /// [Todo.completedDates] 里的记录，不影响其它日期。
  Future<Todo> toggleCompleteOn(Todo todo, DateTime day) => _exclusive(() async {
    final list = await _db.readAll();
    // ⚠️ 按 (id, 日期) 定位：同 id 不同日期时不能改到别的行。
    final idx = _indexOf(list, todo);
    if (idx < 0) return todo;
    final cur = list[idx];
    final Todo updated;
    if (cur.isRepeating) {
      final key = Todo.dayKeyOf(day);
      final dates = List<String>.from(cur.completedDates);
      if (!dates.remove(key)) dates.add(key);
      updated = cur.copyWith(completedDates: dates);
    } else {
      // 完成态按天记录（[Todo.completedDay]）→ 完成「明天」不会影响「今天」。
      final willComplete = !cur.isDoneOn(day);
      // 🔴 取消完成必须 clearCompletedDay（同 toggleComplete 的注释）：
      //    传 completedDay: null 是「保留旧值」，会让取消操作静默失效。
      updated = cur.copyWith(
        completed: willComplete,
        completedDay: willComplete ? Todo.dayKeyOf(day) : null,
        clearCompletedDay: !willComplete,
      );
    }
    list[idx] = updated;
    await _db.writeAll(list);
    await _syncNotification(updated);
    return updated;
  });

  /// 重排所有「未完成且提醒在将来」的待办通知。
  ///
  /// Android 在重启 / 强制停止后会清除 AlarmManager 定时任务，需在
  /// App 启动时、以及开机后（BootReceiver → background 入口）补排一次。
  ///
  /// v2.4.0：只精确取消「本仓库排过的 + 当前待办对应」的 id，再逐条重建，
  /// **不会**再误清上课提醒等其它模块的通知（见 [_kScheduledIds] 注释）。
  /// 全量重排，返回**真正排上**的条数（2026-11-02 改为有返回值）。
  ///
  /// ## 为什么要把返回值交出来
  ///
  /// 原来这里是 `Future<void>`，而 `_syncNotification()` 内部
  /// `NotificationService.schedule()` 的 `bool` 返回值**被直接丢弃**——
  /// 于是「精确闹钟、闹钟模式、非精确」三级降级全失败时，
  /// 整个 App 里没有任何一处知道「这条提醒其实没排上」。
  /// 用户看到的现象就是「待办列表里明明有提醒时间，但就是不响」，
  /// 而我们连一句「排程失败」的日志都没有。
  ///
  /// 现在返回 `(scheduled, failed)` 计数，供首页与设置页展示真实数字。
  Future<({int scheduled, int failed})> rescheduleAll() => _exclusive(() async {
        final all = await _db.readAll();
        final tracked = await _loadScheduledIds();
        // current 必须展开到「按星期拆出来的那几条」，否则旧的星期通知会被
        // 当成「别人的 id」留下来继续响。
        final currentIds = <int>{
          for (final t in all) ...reminderIdsFor(t),
        };
        // 先清：上轮残留（tracked）+ 本轮将要重建（current），保证无重复、无幽灵。
        for (final id in {...tracked, ...currentIds}) {
          await NotificationService.cancel(id);
        }
        await _saveScheduledIds({});
        // 再建：仅「未完成且还有下一次提醒」的会被真正排上。
        var scheduled = 0;
        var failed = 0;
        final todoOn = await todoReminderEnabled();
        for (final t in all) {
          final ok = await _syncNotification(t);
          final wanted = todoOn && planReminders(t, DateTime.now()).isNotEmpty;
          if (ok) {
            if (wanted) scheduled++;
          } else if (wanted) {
            // 本该有提醒却没排上 —— 这才是真正需要报警的情况。
            failed++;
          }
        }
        return (scheduled: scheduled, failed: failed);
      });

  /// 申请通知 + 精确闹钟权限，返回通知权限是否授予。
  Future<bool> ensureNotificationPermission() =>
      NotificationService.requestPermission();

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  /// 读取「已排上的待办通知 id」集合。任何异常都返回空集合（不影响主流程）。
  Future<Set<int>> _loadScheduledIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kScheduledIds);
      if (raw == null || raw.isEmpty) return {};
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => (e as num).toInt()).toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveScheduledIds(Set<int> ids) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kScheduledIds, jsonEncode(ids.toList()));
    } catch (_) {
      // 记录失败不影响提醒本身
    }
  }

  /// 取消待办通知，并把它从「已排上」集合里移除（幂等）。
  Future<void> _cancelNotification(int id) async {
    await NotificationService.cancel(id);
    final ids = await _loadScheduledIds();
    if (ids.remove(id)) await _saveScheduledIds(ids);
  }

  /// 这条待办会用到的**全部**通知 id。
  ///
  /// 重复待办按星期拆成多条（系统一条重复通知只能表达「每周某一个星期 X」），
  /// id = `notifyId + 星期 * 1000`。
  ///
  /// 📐 **2026-11-04 审查修正**：原为 `+ 星期 * 1_000_000`，注释还写
  ///    「加最多 700 万既不会溢出 int」——**这是错的**。`notifyId` 上限是
  ///    int32 的 2147483647，`base + 7*1e6` 可到 2154483647 > 2147483647，
  ///    而插件 Java 侧 `NotificationDetails.java:132` 的 `id` 是 `Integer`，
  ///    越界值会抛 `ClassCastException` 并被三级降级无声吞掉 → 按 base 均匀
  ///    分布估算约 **2.6% 的每周待办**会缺一个星期的提醒。
  ///    现改为 1000 步长（7 天只需 7000 个 id），并配合
  ///    `Todo.stableNotifyId` 收窄到 0x4FFFFFFF，余量 8 亿。
  ///
  /// 📐 **2026-11-04 第二次审查 P1**：这里还在按**当前** `repeatType` 推断
  ///    id 集，于是「每周 → 每天」之后有漏网：
  ///    改之前 `reminderIdsFor` 返回 `[base+1000, base+3000, base+5000]`；
  ///    改成 daily 之后只返回 `[base]`，而 [planReminders] 的 daily 分支也
  ///    只产 `id: base` —— 取消循环 `for (id in ids) if (!keep.contains(id))`
  ///    只遍历 `ids`（= 当前的 [reminderIdsFor]），旧的三个星期 id 根本不在
  ///    集合里，永远进不了 `_cancelNotification`。用户改成「每天」后，
  ///    周一/三/五那 3 条旧闹钟照样响。
  ///    [rescheduleAll] 的 `currentIds` 同源，`tracked`（上次真正排成功的 id）
  ///    也救不了历史上失败过的那几条。
  ///
  ///    修法：**不再推断，直接给满**。weekly 最多用 7 个槽（星期 1..7），
  ///    所以固定返回 `base + {1..7} × 1000` 再加 base 本身。多 cancel 几个
  ///    不存在的 id 是幂等的（插件 `cancel` 对不存在的 id 静默返回），
  ///    代价可以忽略，换来的是「任何状态迁移之后的残留都能清干净」。
  @visibleForTesting
  List<int> reminderIdsFor(Todo todo) {
    final base = todo.notifyId;
    return <int>[base, for (var d = 1; d <= 7; d++) base + d * 1000];
  }

  /// 把一条待办换算成「要排几条通知、各自什么时候、是否交给系统重复」。
  ///
  /// 三条规矩：
  /// 1. **非重复**走一次性绝对时刻（沿用 [nextReminderFor] 的口径）；
  /// 2. **每天**用 `DateTimeComponents.time`，系统自己每天推进 —— App 不必活着；
  /// 3. **每周**按每个星期各排一条 `dayOfWeekAndTime`。
  ///
  /// 唯一退回一次性的情形是**提醒跨了零点**（`dueAt − 提前量` 落到前一天）：
  /// 系统的重复组件是按「本地墙钟时分」对齐的，表达不了这种跨日偏移。
  @visibleForTesting
  List<TodoReminderPlan> planReminders(Todo todo, DateTime now) {
    final base = todo.reminderTime;
    if (base == null || todo.completed) return const [];
    if (!todo.isRepeating) {
      final one = nextReminderFor(todo, now);
      if (one == null) return const [];
      return [TodoReminderPlan(id: todo.notifyId, when: one)];
    }

    final due = todo.dueAt;
    final lead = due == null ? Duration.zero : due.difference(base);
    final dueH = due?.hour ?? base.hour;
    final dueM = due?.minute ?? base.minute;
    // 用一个固定日期的正午做基准算「提醒的墙钟时刻」—— 若跨到前一天，day != 1。
    final wall = DateTime(2000, 1, 2, dueH, dueM).subtract(lead);
    if (wall.day != 2) {
      final one = nextReminderFor(todo, now);
      if (one == null) return const [];
      return [TodoReminderPlan(id: todo.notifyId, when: one)];
    }

    if (todo.repeatType != 'daily') {
      // weekly
      final days = todo.repeatDays.toSet().toList()..sort();
      if (days.isEmpty) {
        // 「每周」却没勾任何星期 —— 脏数据，按一次性排，别再静默不排。
        final one = nextReminderFor(todo, now);
        if (one == null) return const [];
        return [TodoReminderPlan(id: todo.notifyId, when: one)];
      }
      final today = DateTime(now.year, now.month, now.day);
      final doneToday = todo.isDoneOn(today);
      final out = <TodoReminderPlan>[];
      for (final d in days) {
        if (d < DateTime.monday || d > DateTime.sunday) continue;
        var day = today;
        for (var i = 0; i < 8 && day.weekday != d; i++) {
          day = day.add(const Duration(days: 1));
        }
        final at = DateTime(day.year, day.month, day.day, wall.hour, wall.minute);
        // 🔴 「今天这一周已经勾完成」时不能再用 dayOfWeekAndTime ——
        //    系统的重复组件只保留时分与星期，日期被丢弃（Java 侧用 now 的年月日
        //    加 when 的时分重建），所以今天 08:00 依然会响。
        //    退化成一次性、推到下一周的同一时刻；App 下次启动/回前台
        //    rescheduleAll 会把它重新升回重复计划。
        final skipToday = doneToday && day == today;
        final when = skipToday ? at.add(const Duration(days: 7)) : at;
        out.add(TodoReminderPlan(
          // 🔴 2026-11-04 审查 P1：这里原为 `* 1000000`，与
          // [reminderIdsFor] 必须**逐字一致**，否则 cancel 的 id 与
          // schedule 的 id 不是同一个 → 旧通知取消不掉（幽灵通知）。
          id: todo.notifyId + d * 1000,
          when: when,
          match: skipToday ? null : DateTimeComponents.dayOfWeekAndTime,
        ));
      }
      return out;
    }

    // daily
    final one = nextReminderFor(todo, now);
    if (one == null) return const [];
    // 🔴 同上：今天已经勾完成，而 nextReminderFor 只是「跳过今天」返回明天，
    //    用 DateTimeComponents.time 排下去系统仍然会在今天 wall 时刻响一次。
    //    这种情况下改成一次性排程；App 下次启动/回前台会重建每日重复。
    final doneToday = todo.isDoneOn(DateTime(now.year, now.month, now.day));
    return [
      TodoReminderPlan(
        id: todo.notifyId,
        when: one,
        match: doneToday ? null : DateTimeComponents.time,
      ),
    ];
  }

  /// 取消这条待办可能占用的**全部**通知（含按星期拆出来的那几条）。
  Future<void> _cancelAllFor(Todo todo) async {
    for (final id in reminderIdsFor(todo)) {
      await _cancelNotification(id);
    }
  }

  /// 依据待办当前状态，创建或取消其提醒通知（幂等）。
  /// - 未完成 + 有下一次提醒时刻 → 创建/覆盖通知；
  /// - 其余情况（已完成 / 无提醒 / 之后不再发生）→ 取消通知。
  /// 排/取消一条提醒，返回**是否真的排上**（取消也算成功）。
  ///
  /// 2026-11-02：原来返回 `void`，`schedule()` 的 bool 被吞掉，
  /// 三级降级全失败时无人知晓 —— 见 [rescheduleAll] 的说明。
  ///
  /// 2026-11-04：改为按 [planReminders] 排，重复待办交给系统自己推进
  /// （修「重复待办只响一次」）。
  Future<bool> _syncNotification(Todo todo) async {
    // 🔴 「开启待办提醒」关闭时：撤掉这条待办的全部已排通知，且不新增。
    //    add / update / toggleComplete / rescheduleAll 全部经过这里，一处收口
    //    即可保证全局开关对所有写入路径生效；reminderTime 仍保留在待办里，
    //    重新开启后 rescheduleAll 会把它补排回来。
    if (!await todoReminderEnabled()) {
      for (final id in reminderIdsFor(todo)) {
        await _cancelNotification(id);
      }
      return true; // 「已按开关撤下」是期望状态，不算失败
    }
    final plans = planReminders(todo, DateTime.now());
    final ids = reminderIdsFor(todo);
    if (plans.isEmpty) {
      for (final id in ids) {
        await _cancelNotification(id);
      }
      return true; // 「不需要提醒」本身就是期望状态，不算失败
    }
    // 计划里没有的 id（用户把「周一三五」改成「周二」）必须先撤掉，
    // 否则旧的星期三通知会留在系统里继续响。
    final keep = plans.map((p) => p.id).toSet();
    for (final id in ids) {
      if (!keep.contains(id)) await _cancelNotification(id);
    }
    var allOk = true;
    for (final p in plans) {
      final ok = await NotificationService.schedule(
        id: p.id,
        title: '待办提醒：${todo.title}',
        body: todo.description ?? '到时间啦',
        scheduledTime: p.when,
        payload: todo.id,
        // 🔴 优先级 → 通知渠道 → 振动强度（普通轻震 / 重要双震 / 紧急长震）。
        priority: todo.priority,
        matchDateTimeComponents: p.match,
      );
      if (!ok) allOk = false;
      final ids0 = await _loadScheduledIds();
      if (ids0.add(p.id)) await _saveScheduledIds(ids0);
    }
    return allOk;
  }

  /// 这条待办「下一次」应当响铃的时刻（null = 不需要排程）。
  ///
  /// 🔴 为什么不能直接用 [Todo.reminderTime]（2026-11-01 修）：
  ///    `reminderTime` 是**新增时算死的一次性时刻**（`dueAt − 提前量`）。
  ///    对「每天 / 每周」的重复待办，只有创建当天那一次会响 —— 次日
  ///    [rescheduleAll] 一看 `reminder.isAfter(now)` 为 false 就取消，
  ///    之后永远不再排程，表现为「重复待办只有第一天响」。
  ///    这里改成按重复规则滚动到**下一次未完成实例**。
  ///
  /// 滚动口径：把「提醒相对当天 dueAt 的偏移」套到每一次发生的日子上。
  ///   - 有 [Todo.dueAt] → 偏移 = `dueAt − reminderTime`（可跨天：
  ///     如 00:05 提前 30 分钟 = 前一天 23:35）；
  ///   - 无 [Todo.dueAt] → 偏移为 0，直接用 `reminderTime` 的时分。
  @visibleForTesting
  DateTime? nextReminderFor(Todo todo, DateTime now) {
    final base = todo.reminderTime;
    if (base == null) return null;

    // 非重复：仍用建时算好的那个时刻，只判「是否已过 / 是否已完成」。
    if (!todo.isRepeating) {
      if (!base.isAfter(now)) return null;
      if (todo.isDoneOn(base)) return null;
      return base;
    }

    // 重复：往后找第一个「会发生且当天还没勾掉、且提醒时刻仍在未来」的实例。
    //   上限 366 天，防「weekly 但 repeatDays 为空」这类脏数据死循环。
    final due = todo.dueAt;
    final lead = due == null ? Duration.zero : due.difference(base);
    final startDay = DateTime(now.year, now.month, now.day);
    for (var i = 0; i < 366; i++) {
      final day = startDay.add(Duration(days: i));
      if (!todo.occursOn(day)) continue;
      if (todo.isDoneOn(day)) continue;
      final instanceDue = due == null
          ? DateTime(day.year, day.month, day.day, base.hour, base.minute)
          : DateTime(day.year, day.month, day.day, due.hour, due.minute);
      final candidate = instanceDue.subtract(lead);
      if (candidate.isAfter(now)) return candidate;
    }
    return null;
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
