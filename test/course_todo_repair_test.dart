import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/todo.dart';
import 'package:xiyuan_pocket/repositories/todo_repository.dart';
import 'package:xiyuan_pocket/services/course_todo_service.dart';

/// 课程待办「未来日期脏数据」自愈测试（2026-10-30 六次自检）。
///
/// 背景：早期版本课程待办 id 未补零，批量完成按 id 匹配时会误把
/// **未来日期**那条一起划掉。这条脏数据写进库后，
/// `autoCompleteFinishedCourses` 只处理「未完成」的记录 → 永远修不回来，
/// 用户切到未来日期就看到早上的课显示成已完成。
///
/// 现在 `repairFutureCompletedCourses` 会在每次加载时自愈。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> clearAll() async {
    final all = await TodoRepository.instance.getAll();
    for (final t in all) {
      await TodoRepository.instance.delete(t);
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await clearAll();
  });

  test('🔴 未来日期却被标完成的课程待办会被重置为未完成', () async {
    final future = DateTime.now().add(const Duration(days: 1));
    await TodoRepository.instance.add(Todo(
      id: 'course_c1_${future.year}${future.month}${future.day}',
      title: '【课程】高数',
      date: future,
      completed: true,
    ));

    final fixed = await CourseTodoService.repairFutureCompletedCourses();
    expect(fixed, 1);

    final all = await TodoRepository.instance.getAll();
    expect(all.first.completed, isFalse);
  });

  test('🔴 今天的课程待办即使已完成也不动（历史记录要保留）', () async {
    final today = DateTime.now();
    await TodoRepository.instance.add(Todo(
      id: 'course_c2_${today.year}${today.month}${today.day}',
      title: '【课程】物理',
      date: today,
      completed: true,
    ));

    final fixed = await CourseTodoService.repairFutureCompletedCourses();
    expect(fixed, 0);
    final all = await TodoRepository.instance.getAll();
    expect(all.first.completed, isTrue);
  });

  test('🔴 非课程待办（用户自己建的）不受影响', () async {
    final future = DateTime.now().add(const Duration(days: 1));
    await TodoRepository.instance.add(Todo(
      id: 'user_todo_1',
      title: '我的作业',
      date: future,
      completed: true,
    ));

    final fixed = await CourseTodoService.repairFutureCompletedCourses();
    expect(fixed, 0);
    final all = await TodoRepository.instance.getAll();
    expect(all.first.completed, isTrue);
  });
}
