import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/models/todo.dart';
import 'package:xiyuan_pocket/repositories/todo_repository.dart';
import 'package:xiyuan_pocket/services/course_todo_service.dart';

/// 课程 → 待办 联动的回归测试（2026-10-30 自检）。
///
/// 钉住三个曾经出过问题的点：
///   1. 课程待办 id 必须补零 —— 否则 01-12 与 11-02 撞号，
///      批量完成会把**未来日期**的待办一起划掉；
///   2. 去重键必须带日期 —— 否则同课程同节次的另一天被当成重复而漏生成；
///   3. 同 id 重复写入必须覆盖而不是追加 —— 并发同步不能产生两条一样的待办。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('课程待办 id 补零', () {
    final c = Course(
      id: 'c1',
      name: '高数',
      teacher: '张老师',
      classroom: 'A101',
      startSlot: 1,
      endSlot: 2,
      weekday: 1,
      pattern: CoursePattern.fixed,
      colorValue: 0xFFD2F0E5,
      weeks: '1-16',
    );

    test('🔴 01-12 与 11-02 不能撞号', () {
      final jan = CourseTodoService.courseTodoId(c, DateTime(2026, 1, 12));
      final nov = CourseTodoService.courseTodoId(c, DateTime(2026, 11, 2));
      expect(jan, isNot(nov));
      expect(jan, 'course_c1_20260112');
      expect(nov, 'course_c1_20261102');
    });

    test('同一天同一课程 id 稳定（可重复调用）', () {
      final d = DateTime(2026, 3, 5);
      expect(CourseTodoService.courseTodoId(c, d),
          CourseTodoService.courseTodoId(c, d));
    });
  });

  group('待办仓库：同 id 覆盖而非追加', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final all = await TodoRepository.instance.getAll();
      for (final t in all) {
        await TodoRepository.instance.delete(t);
      }
    });

    test('🔴 重复 add 同一 id 只留一条', () async {
      final todo = Todo(
        id: 'dup_test_1',
        title: '课程待办',
        date: DateTime(2026, 11, 2),
        completed: false,
      );
      await TodoRepository.instance.add(todo);
      await TodoRepository.instance.add(todo);
      final all = await TodoRepository.instance.getAll();
      expect(all.where((t) => t.id == 'dup_test_1').length, 1);
    });

    test('不同 id 的两条都保留', () async {
      await TodoRepository.instance.add(Todo(
          id: 'dup_a', title: 'A', date: DateTime(2026, 11, 2)));
      await TodoRepository.instance.add(Todo(
          id: 'dup_b', title: 'B', date: DateTime(2026, 11, 3)));
      final all = await TodoRepository.instance.getAll();
      expect(all.where((t) => t.id == 'dup_a').length, 1);
      expect(all.where((t) => t.id == 'dup_b').length, 1);
    });
  });
}
