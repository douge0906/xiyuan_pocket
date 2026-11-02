import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/models/todo.dart';
import 'package:xiyuan_pocket/repositories/todo_repository.dart';
import 'package:xiyuan_pocket/services/course_storage.dart';
import 'package:xiyuan_pocket/services/course_todo_service.dart';

/// 端到端回归：**删掉课程待办 → 再同步 → 不能又冒出来**。
///
/// 这是任务二真正要证明的那条链路。`course_todo_suppress_test.dart` 只证明
/// 「抑制集合本身工作」，这一条把课表、仓储、同步服务串起来跑。
///
/// ## 用户报告的现象（2026-11-02）
///
/// 「课程类自动同步的待办事项无法删除」——滑删之后过一会儿又出现。
/// 根因：[CourseTodoService.syncCoursesForDate] 把课表当唯一真相，
/// 每次 `_load()` 都会把库里缺的课程待办补回来。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 🔴 用「本周一」而不是写死日期：suppress() 会自清理早于今天的键，
  // 写死日期会在跨零点后失效（2026-11-03 曾因此 2 条测试变红）。
  // 🔴 day 必须是「今天或之后的周一」，两个约束同时成立：
  //  ① 课表里这门课 weekday=1（周一），day 不是周一就不会生成待办；
  //  ② suppress() 会自清理早于今天的键，day 在过去会让登记当场失效。
  // 写死日期曾在 2026-11-03 跨过 11-02 后变红。
  final n = DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final day = today.add(Duration(days: (8 - today.weekday) % 7));

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CourseTodoService.debugResetSuppressedCache();
  });

  /// 造一门「每周一 1-2 节、全学期」的课，并把学期起始日锚到 `day`。
  ///
  /// `weeks` 留空 → [Course.parseWeeks] 返回 null → [Course.isActiveOnWeek]
  /// 恒为 true，不用为每个测试单独算周次。
  Future<void> seedCourse() async {
    const course = Course(
      id: '42',
      name: '高等数学',
      teacher: '王老师',
      classroom: 'J1-101',
      weekday: 1,
      startSlot: 1,
      endSlot: 2,
      colorValue: 0xFFD2E5F8,
    );
    await CourseStorage.saveCourses([course]);
    // 学期起始日就设在 day 那天 → teachingWeek(day) == 1
    await CourseStorage.saveSemesterStart(day);
  }

  Future<List<Todo>> courseTodos() async {
    final all = await TodoRepository.instance.getAll();
    return all.where((t) => t.id.startsWith('course_')).toList();
  }

  test('前置自检：课表能生成待办（否则后面几条都是空跑）', () async {
    await seedCourse();
    final added = await CourseTodoService.syncCoursesForDate(day);
    expect(added, 1, reason: '这天有课，应该生成 1 条待办');

    final list = await courseTodos();
    expect(list.length, 1);
    expect(list.first.title, contains('高等数学'));
  });

  test('🔴 删掉课程待办后重新同步，不能又被加回来', () async {
    await seedCourse();
    await CourseTodoService.syncCoursesForDate(day);

    final target = (await courseTodos()).first;

    // ② 用户删掉它（模拟 `_deleteTodo` 的两步：删库 + 登记抑制）
    await TodoRepository.instance.delete(target);
    await CourseTodoService.suppress(target.id, target.date);
    expect(await courseTodos(), isEmpty, reason: '删除后库里应该没有课程待办');

    // ③ 再同步一次 —— 这就是用户「重新进首页」看到的
    final addedAgain = await CourseTodoService.syncCoursesForDate(day);
    expect(addedAgain, 0, reason: '🔴 用户删掉的不能被重建');
    expect(await courseTodos(), isEmpty,
        reason: '🔴 这就是用户报的「删了又回来」');
  });

  test('撤销删除（unsuppress）后，同步不会把它当成「用户不要了」', () async {
    await seedCourse();
    await CourseTodoService.syncCoursesForDate(day);

    final target = (await courseTodos()).first;

    // 删除 + 登记抑制
    await TodoRepository.instance.delete(target);
    await CourseTodoService.suppress(target.id, target.date);
    expect(await CourseTodoService.syncCoursesForDate(day), 0);

    // 用户点「撤销」：先把这条加回库，再解除抑制
    await TodoRepository.instance.add(target);
    await CourseTodoService.unsuppress(target.id, target.date);

    expect(await courseTodos().then((l) => l.length), 1,
        reason: '撤销后这条应该回来');
    // 再同步一次不能把「撤销」当成删除
    expect(await CourseTodoService.syncCoursesForDate(day), 0,
        reason: '已经在了，不该重复添加');
    expect(await courseTodos().then((l) => l.length), 1);
  });

  test('没有抑制时，同步仍然会把缺的补上（不能过度抑制）', () async {
    await seedCourse();
    await CourseTodoService.syncCoursesForDate(day);

    final target = (await courseTodos()).first;

    // 只删库、不登记抑制 —— 相当于「数据意外丢了」而不是「用户主动删」
    await TodoRepository.instance.delete(target);
    expect(await courseTodos(), isEmpty);

    final added = await CourseTodoService.syncCoursesForDate(day);
    expect(added, 1, reason: '没有抑制记录时，课表仍是真相，缺的要补回来');

    final restored = await courseTodos();
    expect(restored.length, 1);
    expect(restored.first.completed, isFalse, reason: '补回来的应该是一条干净的新待办');
  });

  test('同一门课的另一天不受影响（只抑制那一天）', () async {
    await seedCourse();
    final nextMonday = day.add(const Duration(days: 7));

    await CourseTodoService.syncCoursesForDate(day);
    final d1 = (await courseTodos()).first;

    await TodoRepository.instance.delete(d1);
    await CourseTodoService.suppress(d1.id, d1.date);

    // 下周一同一门课 —— 应该照常生成
    final added = await CourseTodoService.syncCoursesForDate(nextMonday);
    expect(added, 1, reason: '只删了 11-02 这条，11-09 的同名课必须还在');

    final remaining = await courseTodos();
    expect(remaining.length, 1);
    expect(Todo.dayKeyOf(remaining.first.date), Todo.dayKeyOf(nextMonday));
  });
}
