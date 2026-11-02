import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/pages/add_todo_dialog.dart';

/// 新增待办的默认时刻。
///
/// 🔴 2026-11-02 之前默认是「此刻」，制造了一个必现死锁：
///    点「+」不改时间直接保存 → `reminder = dueAt - lead` →
///    `reminder.isAfter(now)` 为 false（秒数已走过去）→
///    弹「提醒时间已过」→ **待办存不进去**。
///    用户看到的是「打开新增待办就这样，还得先瞎改一下才能保存」。
void main() {
  group('默认时刻必须落在未来', () {
    test('16:57 → 17:00（不是 16:57，也不是 16:30）', () {
      final r = AddTodoDialog.defaultDueAt(DateTime(2026, 11, 2, 16, 57));
      expect(r, DateTime(2026, 11, 2, 17, 0));
    });

    test('16:27 → 16:30（半点已过，取下一个半点）', () {
      // 16:27 + 2 = 16:29，minute < 30 → 16:30
      final r = AddTodoDialog.defaultDueAt(DateTime(2026, 11, 2, 16, 27));
      expect(r, DateTime(2026, 11, 2, 16, 30));
    });

    test('🔴 16:29:30 取最近的 16:30，不能凭空空等半小时', () {
      // 早期实现用「now + 2 分钟再取整」，会把它算成 17:00 ——
      // 用户点「+」莫名其妙多等半小时。规则应是「严格大于 now 的下一个边界」。
      final r = AddTodoDialog.defaultDueAt(DateTime(2026, 11, 2, 16, 29, 30));
      expect(r, DateTime(2026, 11, 2, 16, 30));
      expect(r.isAfter(DateTime(2026, 11, 2, 16, 29, 30)), isTrue);
    });

    test('🔴 恰好踩在半点上（16:30:00）必须给 17:00，不能给 16:30 自己', () {
      // 返回等于 now 的时刻 = `reminder.isAfter(now)` 仍为 false = 死锁复活。
      final r = AddTodoDialog.defaultDueAt(DateTime(2026, 11, 2, 16, 30));
      expect(r, DateTime(2026, 11, 2, 17, 0));
      expect(r.isAfter(DateTime(2026, 11, 2, 16, 30)), isTrue);
    });

    test('16:31 → 17:00（半点已过）', () {
      final r = AddTodoDialog.defaultDueAt(DateTime(2026, 11, 2, 16, 31));
      expect(r, DateTime(2026, 11, 2, 17, 0));
    });

    test('🔴 23:58 跨零点必须推进到次日 00:00，不能变成「今天 00:00」', () {
      final r = AddTodoDialog.defaultDueAt(DateTime(2026, 11, 2, 23, 58));
      expect(r, DateTime(2026, 11, 3, 0, 0));
      // 「今天 00:00」是过去时间，那样等于又回到原 bug。
      expect(r.isAfter(DateTime(2026, 11, 2, 23, 58)), isTrue);
    });

    test('月末跨日（10-31 23:59 → 11-01 00:00）', () {
      final r = AddTodoDialog.defaultDueAt(DateTime(2026, 10, 31, 23, 59));
      expect(r, DateTime(2026, 11, 1, 0, 0));
    });

    test('整点刚过 1 分（17:01 → 17:30）', () {
      final r = AddTodoDialog.defaultDueAt(DateTime(2026, 11, 2, 17, 1));
      expect(r, DateTime(2026, 11, 2, 17, 30));
    });

    test('任意时刻都必须严格晚于输入 3 分钟以上（永不回到过去）', () {
      // 扫一整天 1440 分钟，逐分钟验证 —— 这条兜住所有边界情况。
      final base = DateTime(2026, 11, 2);
      for (var m = 0; m < 1440; m++) {
        final now = base.add(Duration(minutes: m));
        final r = AddTodoDialog.defaultDueAt(now);
        expect(r.isAfter(now), isTrue,
            reason: '$now 算出的默认时刻 $r 不在未来');
        expect(r.minute, anyOf(0, 30),
            reason: '$now 算出的 $r 不是整点或半点');
      }
    });
  });

  group('过期提醒守卫必须区分「改时间」与「本来就过期」', () {
    final now = DateTime(2026, 11, 2, 12, 0);

    test('没开提醒 → 永远不拦', () {
      expect(
        AddTodoDialog.shouldBlockPastReminder(
          reminder: null,
          isEdit: false,
          originalReminder: null,
          now: now,
        ),
        isFalse,
      );
    });

    test('提醒在未来 → 不拦', () {
      expect(
        AddTodoDialog.shouldBlockPastReminder(
          reminder: DateTime(2026, 11, 2, 13, 0),
          isEdit: false,
          originalReminder: null,
          now: now,
        ),
        isFalse,
      );
    });

    test('🔴 新建时选了过去的时刻 → 必须拦（否则存一条永远不响的提醒）', () {
      expect(
        AddTodoDialog.shouldBlockPastReminder(
          reminder: DateTime(2026, 11, 2, 9, 0),
          isEdit: false,
          originalReminder: null,
          now: now,
        ),
        isTrue,
      );
    });

    test('🔴 编辑历史待办、时间一字未动 → 放行（用户只想改错别字）', () {
      final old = DateTime(2026, 10, 20, 9, 0);
      expect(
        AddTodoDialog.shouldBlockPastReminder(
          reminder: old,
          isEdit: true,
          originalReminder: old,
          now: now,
        ),
        isFalse,
      );
    });

    test('🔴 编辑历史待办、把时间也改到了过去 → 仍要拦（用户真的动了时间）', () {
      expect(
        AddTodoDialog.shouldBlockPastReminder(
          reminder: DateTime(2026, 11, 2, 8, 0),
          isEdit: true,
          originalReminder: DateTime(2026, 10, 20, 9, 0),
          now: now,
        ),
        isTrue,
      );
    });

    test('编辑时把提醒改成未来 → 不拦', () {
      expect(
        AddTodoDialog.shouldBlockPastReminder(
          reminder: DateTime(2026, 11, 2, 18, 0),
          isEdit: true,
          originalReminder: DateTime(2026, 10, 20, 9, 0),
          now: now,
        ),
        isFalse,
      );
    });

    test('编辑但没有原始提醒（原本不提醒，这次打开了）→ 按新建口径判', () {
      expect(
        AddTodoDialog.shouldBlockPastReminder(
          reminder: DateTime(2026, 11, 2, 8, 0),
          isEdit: true,
          originalReminder: null,
          now: now,
        ),
        isTrue,
      );
    });
  });
}
