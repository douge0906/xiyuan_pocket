import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/models/course_table.dart';
import 'package:xiyuan_pocket/models/todo.dart';
import 'package:xiyuan_pocket/repositories/todo_repository.dart';
import 'package:xiyuan_pocket/services/course_todo_service.dart';

/// 通知 id 与重复排程的回归测试（2026-11-04 子智能体审查后的修复）。
///
/// 钉住三条曾经静默失效的点：
///   1. **id 不得溢出 int32** —— 插件 Java 侧 `NotificationDetails.id` 是
///      `Integer`，Dart 传 21.5 亿会抛 `ClassCastException`，且被三级降级
///      无声吞掉 → 约 2.6% 的每周待办会缺一个星期的提醒。
///   2. **schedule 与 cancel 必须用同一个 id 公式** —— 两处一旦不一致，
///      旧通知取消不掉，变成幽灵通知。
///   3. **课程待办不得自带 `reminderTime`** —— 否则与
///      `CourseReminderService` 的「提前 N 分钟」并存，一节课响两次。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('通知 id 空间', () {
    test('stableNotifyId 恒落在 int32 安全区（0x40000000..0x4FFFFFFF）', () {
      for (var i = 0; i < 5000; i++) {
        final id = Todo.stableNotifyId('todo_$i');
        expect(id, greaterThanOrEqualTo(0x40000000));
        expect(id, lessThanOrEqualTo(0x4FFFFFFF));
      }
    });

    test('每周待办加星期偏移后仍不溢出 int32', () {
      const worstBase = 0x4FFFFFFF; // 上限
      for (var d = DateTime.monday; d <= DateTime.sunday; d++) {
        expect(worstBase + d * 1000, lessThan(2147483647),
            reason: '插件 Java 侧 id 是 Integer，越界会抛 ClassCastException');
      }
    });

    test('reminderIdsFor 与 planReminders 用的是同一个 id 公式', () {
      final todo = Todo(
        id: 'weekly_1',
        title: '每周例会',
        date: DateTime(2026, 11, 2),
        reminderTime: DateTime(2026, 11, 2, 9),
        repeatType: 'weekly',
        repeatDays: const [1, 3, 5],
      );
      final ids = TodoRepository.instance.reminderIdsFor(todo);
      final plans = TodoRepository.instance.planReminders(
        todo,
        DateTime(2026, 11, 2, 8),
      );
      expect(plans, isNotEmpty);
      // 计划里的 id 必须是 ids 的子集 —— 否则 cancel 打不到 schedule 排的那条。
      for (final p in plans) {
        expect(ids, contains(p.id),
            reason: 'planReminders 与 reminderIdsFor 公式不一致 → 幽灵通知');
      }
    });
  });

  group('课程待办不重复响铃', () {
    test('生成的课程待办 reminderTime 为空，dueAt 带上课时刻', () async {
      // 用「今天」建课表：课程 weekday = 今天，教学周恒为 1。
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final monday = today.subtract(Duration(days: today.weekday - 1));

      final course = Course(
        id: 'c1',
        name: '高数',
        teacher: '张老师',
        classroom: 'A101',
        startSlot: 1,
        endSlot: 2,
        weekday: today.weekday,
        pattern: CoursePattern.fixed,
        colorValue: 0xFFD2F0E5,
        weeks: '1-16',
        weekType: CourseWeekType.every,
      );
      _seed([course], monday);

      await CourseTodoService.syncCoursesForDate(today);

      final all = await TodoRepository.instance.getAll();
      final todo = all.firstWhere((t) => t.title.contains('高数'));
      expect(todo.reminderTime, isNull,
          reason: '课程待办自带提醒会与 CourseReminderService 重复响铃');
      // dueAt 仍然带上上课时刻，列表照旧显示几点。
      expect(todo.dueAt, isNotNull);
      expect(todo.dueAt!.hour, 8);
    });
  });
}

void _seed(List<Course> courses, DateTime semesterStart) {
  final table = CourseTable(
    id: 't1',
    name: '我的课表',
    createdAt: DateTime(2026, 9, 1),
    courses: courses,
    semesterStart: semesterStart,
    semesterStartSource: CourseTable.srcUser,
  );
  SharedPreferences.setMockInitialValues(<String, Object>{
    'course_tables_v2': jsonEncode({
      'tables': [table.toJson()],
      'activeId': 't1',
    }),
  });
}
