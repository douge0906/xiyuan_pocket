import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../database/todo_database.dart';
import '../models/todo.dart';
import '../services/notification_service.dart';

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
class TodoRepository {
  TodoRepository._();
  static final TodoRepository instance = TodoRepository._();

  final TodoDatabase _db = TodoDatabase.instance;

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

  // ---------------------------------------------------------------------------
  // 查询
  // ---------------------------------------------------------------------------

  /// 全部待办。
  Future<List<Todo>> getAll() => _db.readAll();

  /// 指定日期（按年月日）的待办。
  Future<List<Todo>> getByDate(DateTime day) async {
    final all = await _db.readAll();
    return all.where((t) => _sameDay(t.date, day)).toList();
  }

  // ---------------------------------------------------------------------------
  // 写入 —— 每个方法都保证「库」与「通知」同步
  // ---------------------------------------------------------------------------

  /// 新增待办：落库 + （若设置了将来的提醒且未完成）立即创建通知。
  Future<void> add(Todo todo) async {
    final list = await _db.readAll();
    list.add(todo);
    await _db.writeAll(list);
    await _syncNotification(todo);
  }

  /// 编辑待办：落库 + 先取消旧通知再按最新提醒时间重排。
  /// 因 notifyId 由 id 推导、id 不随编辑改变，取消/重排命中同一 id，天然幂等。
  Future<void> update(Todo todo) async {
    final list = await _db.readAll();
    final idx = list.indexWhere((t) => t.id == todo.id);
    if (idx < 0) return;
    list[idx] = todo;
    await _db.writeAll(list);
    // 改时间：先取消旧通知，再按新状态重建（不重复创建，同 id 覆盖）。
    await _cancelNotification(todo.notifyId);
    await _syncNotification(todo);
  }

  /// 删除待办：删库 + 取消通知。
  Future<void> delete(Todo todo) async {
    final list = await _db.readAll();
    list.removeWhere((t) => t.id == todo.id);
    await _db.writeAll(list);
    await _cancelNotification(todo.notifyId);
  }

  /// 切换完成态：落库 + 完成则取消通知 / 未完成且提醒在将来则重排。
  /// 返回更新后的待办，便于调用方做乐观 UI 校正。
  Future<Todo> toggleComplete(Todo todo) async {
    final list = await _db.readAll();
    final idx = list.indexWhere((t) => t.id == todo.id);
    if (idx < 0) return todo;
    final updated = list[idx].copyWith(completed: !list[idx].completed);
    list[idx] = updated;
    await _db.writeAll(list);
    await _syncNotification(updated);
    return updated;
  }

  /// 批量标记完成（一次读、一次写、一次落库）。
  /// 用于「课程结束后自动划掉」这类批量场景，避免逐条 toggle 造成 N 次整表读写。
  /// 返回实际改变的条数。
  Future<int> completeMany(Set<String> ids) async {
    if (ids.isEmpty) return 0;
    final list = await _db.readAll();
    final hit = <Todo>[];
    var changed = 0;
    for (var i = 0; i < list.length; i++) {
      final t = list[i];
      if (ids.contains(t.id) && !t.completed) {
        list[i] = t.copyWith(completed: true);
        hit.add(list[i]);
        changed++;
      }
    }
    if (changed == 0) return 0;
    await _db.writeAll(list);
    for (final t in hit) {
      await _cancelNotification(t.notifyId);
    }
    return changed;
  }

  /// 重排所有「未完成且提醒在将来」的待办通知。
  ///
  /// Android 在重启 / 强制停止后会清除 AlarmManager 定时任务，需在
  /// App 启动时、以及开机后（BootReceiver → background 入口）补排一次。
  ///
  /// v2.4.0：只精确取消「本仓库排过的 + 当前待办对应」的 id，再逐条重建，
  /// **不会**再误清上课提醒等其它模块的通知（见 [_kScheduledIds] 注释）。
  Future<void> rescheduleAll() async {
    final all = await _db.readAll();
    final tracked = await _loadScheduledIds();
    final currentIds = all.map((t) => t.notifyId).toSet();
    // 先清：上轮残留（tracked）+ 本轮将要重建（current），保证无重复、无幽灵。
    for (final id in {...tracked, ...currentIds}) {
      await NotificationService.cancel(id);
    }
    await _saveScheduledIds({});
    // 再建：仅「未完成且提醒在将来」的会被真正排上。
    for (final t in all) {
      await _syncNotification(t);
    }
  }

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

  /// 依据待办当前状态，创建或取消其提醒通知（幂等）。
  /// - 未完成 + 有提醒 + 提醒时间在将来 → 创建/覆盖通知；
  /// - 其余情况（已完成 / 无提醒 / 时间已过）→ 取消通知。
  Future<void> _syncNotification(Todo todo) async {
    final reminder = todo.reminderTime;
    final shouldNotify =
        !todo.completed && reminder != null && reminder.isAfter(DateTime.now());
    if (shouldNotify) {
      await NotificationService.schedule(
        id: todo.notifyId,
        title: '待办提醒：${todo.title}',
        body: todo.description ?? '到时间啦',
        scheduledTime: reminder,
        payload: todo.id,
      );
      final ids = await _loadScheduledIds();
      if (ids.add(todo.notifyId)) await _saveScheduledIds(ids);
    } else {
      await _cancelNotification(todo.notifyId);
    }
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
