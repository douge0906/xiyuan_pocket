import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/todo.dart';
import 'package:xiyuan_pocket/repositories/todo_repository.dart';
import 'package:xiyuan_pocket/services/course_todo_service.dart';

/// 待办「完成态跨天串写」回归测试（2026-10-31 八次自检）。
///
/// 用户报告：**「我若查看明日待办，则同步的课程由于时间原因会默认完成，
/// 状态延续到今日」**。
///
/// 根因不是时间判定本身（`autoCompleteFinishedCourses` 的未来日期守卫是对的），
/// 而是**待办的身份键用错了**：
///   · 课程待办 id 是派生的（`course_<课程id>_<yyyyMMdd>`），旧版本未补零
///     → `2026-01-12` 与 `2026-11-02` 撞成同一个 `course_5_2026112`；
///   · 库里所有写路径都按 **id 单键**匹配 → 同 id 不同日期时改到**别的行**。
///
/// 修复：
///   · 身份键改成 **(id, 日期)**（`Todo.compositeKey`）；
///   · 完成态按天归属（新增 `Todo.completedDay`）；
///   · 一次性历史迁移清理撞号脏数据。
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

  /// 构造「同 id、不同日期」的两行 —— 历史撞号的真实形态。
  Future<void> seedColliding() async {
    final jan = DateTime(2026, 1, 12);
    final nov = DateTime(2026, 11, 2);
    // 旧写法不补零：01-12 与 11-02 都得到 2026112
    for (final d in [jan, nov]) {
      await TodoRepository.instance.add(Todo(
        id: 'course_5_2026112',
        title: '【课程】高数',
        date: d,
        completed: false,
      ));
    }
  }

  test('🔴 同 id 不同日期：勾选其中一条不会改到另一条', () async {
    await seedColliding();
    final jan = DateTime(2026, 1, 12);
    final nov = DateTime(2026, 11, 2);

    final all = await TodoRepository.instance.getAll();
    expect(all.length, 2);

    // 点「11-02」那行
    final novRow = all.firstWhere((t) => t.date.month == 11);
    await TodoRepository.instance.toggleCompleteOn(novRow, nov);

    final after = await TodoRepository.instance.getAll();
    final janRow = after.firstWhere((t) => t.date.month == 1);
    final novAfter = after.firstWhere((t) => t.date.month == 11);
    expect(novAfter.isDoneOn(nov), isTrue, reason: '11-02 应被勾选');
    expect(janRow.isDoneOn(jan), isFalse, reason: '1-12 不该被牵连');
  });

  test('🔴 同 id 不同日期：删除一条不会连带删掉另一条', () async {
    await seedColliding();
    final all = await TodoRepository.instance.getAll();
    final novRow = all.firstWhere((t) => t.date.month == 11);

    await TodoRepository.instance.delete(novRow);

    final after = await TodoRepository.instance.getAll();
    expect(after.length, 1, reason: '只该删掉 11-02 那条');
    expect(after.first.date.month, 1);
  });

  test('🔴 同 id 不同日期：自愈不会改错行（历史记录不丢）', () async {
    // 库里有两行同 id：1-12（已完成）与 11-02（已完成）
    final jan = DateTime(2026, 1, 12);
    final nov = DateTime(2026, 11, 2);
    for (final d in [jan, nov]) {
      await TodoRepository.instance.add(Todo(
        id: 'course_5_2026112',
        title: '【课程】高数',
        date: d,
        completed: true,
      ));
    }

    // 以「今天 = 2026-10-20」为基准：11-02 是未来
    final fixed = await CourseTodoService.repairFutureCompletedCourses(
      now: DateTime(2026, 10, 20),
    );
    expect(fixed, 1);

    final after = await TodoRepository.instance.getAll();
    expect(after.length, 2, reason: '不该把行改没了');
    final janRow = after.firstWhere((t) => t.date.month == 1);
    final novRow = after.firstWhere((t) => t.date.month == 11);
    expect(janRow.date, jan, reason: '1-12 那行的日期不能被改写');
    expect(janRow.completed, isTrue, reason: '1-12 的历史完成态要保留');
    expect(novRow.completed, isFalse, reason: '11-02 的脏完成态要清掉');
  });

  test('🔴 完成态按天归属：勾明天不影响今天', () async {
    final jan = DateTime(2026, 1, 12);
    final nov = DateTime(2026, 11, 2);
    await TodoRepository.instance.add(Todo(
      id: 'course_5_20261102',
      title: '【课程】高数',
      date: nov,
      completed: false,
    ));

    final all = await TodoRepository.instance.getAll();
    await TodoRepository.instance.toggleCompleteOn(all.first, nov);

    final after = await TodoRepository.instance.getAll();
    expect(after.first.isDoneOn(nov), isTrue);
    expect(after.first.isDoneOn(jan), isFalse,
        reason: '完成态不能延续到别的日期');
    expect(after.first.completedDay, '2026-11-02');
  });

  test('🔴 历史迁移：撞号 id 被改成补零 id', () async {
    await seedColliding();

    final changed = await CourseTodoService.migrateCourseTodoHistory(
      now: DateTime(2026, 10, 20),
    );
    expect(changed, greaterThan(0));

    final after = await TodoRepository.instance.getAll();
    expect(after.length, 2, reason: '两条记录都要保留（只是 id 改了）');
    for (final t in after) {
      expect(t.id, 'course_5_${t.date.year}'
          '${t.date.month.toString().padLeft(2, '0')}'
          '${t.date.day.toString().padLeft(2, '0')}');
    }
  });

  test('🔴 历史迁移：未来日期的脏完成态被重置', () async {
    final nov = DateTime(2026, 11, 2);
    await TodoRepository.instance.add(Todo(
      id: 'course_5_20261102',
      title: '【课程】高数',
      date: nov,
      completed: true,
    ));

    await CourseTodoService.migrateCourseTodoHistory(
      now: DateTime(2026, 10, 20),
    );

    final after = await TodoRepository.instance.getAll();
    expect(after.first.completed, isFalse);
    expect(after.first.completedDay, isNull);
  });

  test('🔴 历史迁移：幂等（跑两次结果一致）', () async {
    await seedColliding();
    await CourseTodoService.migrateCourseTodoHistory(
      now: DateTime(2026, 10, 20),
    );
    final first = await TodoRepository.instance.getAll();

    await CourseTodoService.migrateCourseTodoHistory(
      now: DateTime(2026, 10, 20),
    );
    final second = await TodoRepository.instance.getAll();

    expect(second.length, first.length);
    for (var i = 0; i < first.length; i++) {
      expect(second[i].id, first[i].id);
      expect(second[i].date, first[i].date);
      expect(second[i].completed, first[i].completed);
    }
  });

  test('🔴 用户自建待办不受迁移影响', () async {
    await TodoRepository.instance.add(Todo(
      id: 'user_todo_1',
      title: '我的作业',
      date: DateTime(2026, 11, 2),
      completed: true,
    ));

    await CourseTodoService.migrateCourseTodoHistory(
      now: DateTime(2026, 10, 20),
    );

    final after = await TodoRepository.instance.getAll();
    expect(after.length, 1);
    expect(after.first.id, 'user_todo_1');
    expect(after.first.completed, isTrue);
  });
}
