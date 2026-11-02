import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/models/todo.dart';
import 'package:xiyuan_pocket/repositories/todo_repository.dart';

/// 重复待办「下一次提醒时刻」的滚动测试（2026-11-01）。
///
/// 用户报告的原始症状：
///   「新建一个每天 / 每周的待办，只有建的那天会响，第二天以后再也不响。」
///
/// 根因：[Todo.reminderTime] 在新增时算死成**一次性时刻**
/// （`dueAt − 提前量`），而 `_syncNotification` 原来的判据是
/// `reminder.isAfter(DateTime.now())` —— 次日这个条件恒为 false，
/// 于是通知被取消且永不重排。
///
/// 修复：[TodoRepository.nextReminderFor] 按重复规则向后滚动，
/// 返回第一个「会发生 + 当天未勾掉 + 提醒时刻在未来」的实例。
///
/// 这套断言锁住的就是那个滚动行为 —— 一旦有人把滚动逻辑改回
/// 「直接用 reminderTime」，下面「明天 / 下周还要响」的用例会立刻红。
void main() {
  final repo = TodoRepository.instance;

  /// 基准「现在」：2026-11-01（周日）10:00。
  /// 用固定日期而不是 DateTime.now()，避免测试在跨日 / 跨周时飘。
  final now = DateTime(2026, 11, 1, 10, 0);

  Todo daily({int hour = 20, int minute = 0, int lead = 0}) {
    // 每天 20:00 提醒；建库那天就是 2026-11-01。
    final due = DateTime(2026, 11, 1, hour, minute);
    return Todo(
      id: 'daily_test',
      title: '每天打卡',
      date: DateTime(2026, 11, 1),
      dueAt: due,
      reminderTime: due.subtract(Duration(minutes: lead)),
      remindLeadMinutes: lead,
      repeatType: 'daily',
    );
  }

  Todo weekly(List<int> days, {int hour = 9}) {
    final due = DateTime(2026, 11, 1, hour, 0);
    return Todo(
      id: 'weekly_test',
      title: '每周上课',
      date: DateTime(2026, 11, 1),
      dueAt: due,
      reminderTime: due,
      repeatType: 'weekly',
      repeatDays: days,
    );
  }

  group('🔴 重复待办的下一次提醒（此前只有第一天响）', () {
    test('每天 20:00 的待办：今天 10:00 看，应排在今天 20:00', () {
      final t = daily();
      expect(repo.nextReminderFor(t, now), DateTime(2026, 11, 1, 20, 0));
    });

    test('每天 20:00 的待办：今天 21:00 看，应滚到明天 20:00', () {
      final t = daily();
      final later = DateTime(2026, 11, 1, 21, 0);
      expect(repo.nextReminderFor(t, later), DateTime(2026, 11, 2, 20, 0));
    });

    test('每天 20:00 的待办：隔了 5 天再打开，应排到当天或次日 20:00', () {
      final t = daily();
      final muchLater = DateTime(2026, 11, 6, 8, 0);
      expect(repo.nextReminderFor(t, muchLater), DateTime(2026, 11, 6, 20, 0));
    });

    test('每周一 / 周三 9:00：周日 10:00 看，应排到周一 9:00', () {
      final t = weekly([1, 3]);
      expect(repo.nextReminderFor(t, now), DateTime(2026, 11, 2, 9, 0));
    });

    test('每周一 / 周三 9:00：周一 10:00 看（已过点），应排到周三 9:00', () {
      final t = weekly([1, 3]);
      final monLater = DateTime(2026, 11, 2, 10, 0);
      expect(repo.nextReminderFor(t, monLater), DateTime(2026, 11, 4, 9, 0));
    });

    test('今天已勾掉 → 排到下一次（不是今天）', () {
      final t = daily().copyWith(completedDates: [Todo.dayKeyOf(DateTime(2026, 11, 1))]);
      expect(repo.nextReminderFor(t, now), DateTime(2026, 11, 2, 20, 0));
    });

    test('提前 30 分钟：每天 20:00 的事，今天 19:45 看应已排（19:30 已过 → 滚到明天 19:30）', () {
      final t = daily(lead: 30);
      final at1945 = DateTime(2026, 11, 1, 19, 45);
      expect(repo.nextReminderFor(t, at1945), DateTime(2026, 11, 2, 19, 30));
    });

    test('提前 30 分钟：今天 19:00 看，应排今天 19:30', () {
      final t = daily(lead: 30);
      final at1900 = DateTime(2026, 11, 1, 19, 0);
      expect(repo.nextReminderFor(t, at1900), DateTime(2026, 11, 1, 19, 30));
    });
  });

  group('非重复待办保持原口径', () {
    test('一次性待办：时间在将来 → 返回那个时刻', () {
      final t = Todo(
        id: 'once',
        title: '交作业',
        date: DateTime(2026, 11, 2),
        dueAt: DateTime(2026, 11, 2, 18, 0),
        reminderTime: DateTime(2026, 11, 2, 18, 0),
      );
      expect(repo.nextReminderFor(t, now), DateTime(2026, 11, 2, 18, 0));
    });

    test('一次性待办：时间已过 → null（不再提醒）', () {
      final t = Todo(
        id: 'once_past',
        title: '交作业',
        date: DateTime(2026, 10, 30),
        dueAt: DateTime(2026, 10, 30, 18, 0),
        reminderTime: DateTime(2026, 10, 30, 18, 0),
      );
      expect(repo.nextReminderFor(t, now), isNull);
    });

    test('无提醒时间的待办 → null', () {
      final t = Todo(
        id: 'no_remind',
        title: '随便记一下',
        date: DateTime(2026, 11, 1),
      );
      expect(repo.nextReminderFor(t, now), isNull);
    });
  });

  group('脏数据不会死循环', () {
    test('weekly 但 repeatDays 为空 → 366 天内无实例，返回 null 而不是卡住', () {
      final t = weekly(const []);
      expect(repo.nextReminderFor(t, now), isNull);
    });
  });
}
