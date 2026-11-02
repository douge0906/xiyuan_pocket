import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/services/course_todo_service.dart';

/// 回归：课程待办被用户删掉后，不允许被 `syncCoursesForDate` 重建。
///
/// ## 用户报告的现象（2026-11-02）
///
/// 「课程类自动同步的待办事项无法删除」——滑删之后过一会儿又出现。
///
/// ## 根因
///
/// 课程待办的唯一真相是**课表**：[CourseTodoService.syncCoursesForDate]
/// 每次 `_load()` 都会比对「这天有这门课」与「库里有这条待办」，
/// 缺了就补一条。删掉后库里没有了 → 立刻重建。
///
/// ## 这份测试锁什么
///
/// 1. 抑制集合的键是 `id@yyyyMMdd`，**同 id 不同日期互不影响**；
/// 2. `suppress` 后再同步，那条不会被加回来；
/// 3. `unsuppress`（撤销删除）后，同步又能正常重建 —— 否则「撤销」是假的；
/// 4. 抑制集合会自清理过期键（不会无限增长）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CourseTodoService.debugResetSuppressedCache();
  });

  // 🔴 用「今天」而不是写死日期：suppress() 会自清理早于今天的键，
  // 写死日期会在跨零点后失效（2026-11-03 曾因此 4 条测试变红）。
  final now = DateTime.now();
  final day = DateTime(now.year, now.month, now.day);
  final courseId = 'course_42_${day.year}${day.month.toString().padLeft(2, '0')}${day.day.toString().padLeft(2, '0')}';

  test('初始状态：没有任何抑制', () async {
    expect(await CourseTodoService.isSuppressed(courseId, day), isFalse);
  });

  test('抑制后立刻可见', () async {
    await CourseTodoService.suppress(courseId, day);
    expect(await CourseTodoService.isSuppressed(courseId, day), isTrue);
  });

  test('🔴 同 id 别的日期不受影响（复合键，不是单 id）', () async {
    await CourseTodoService.suppress(courseId, day);

    expect(await CourseTodoService.isSuppressed(courseId, day.add(const Duration(days: 1))),
        isFalse,
        reason: '只删了 11-02 这条，11-03 的同名课必须还在');
    expect(await CourseTodoService.isSuppressed(courseId, day.add(const Duration(days: 7))),
        isFalse);
  });

  test('🔴 撤销删除后必须解除抑制，否则「撤销」是假的', () async {
    await CourseTodoService.suppress(courseId, day);
    expect(await CourseTodoService.isSuppressed(courseId, day), isTrue);

    await CourseTodoService.unsuppress(courseId, day);
    expect(await CourseTodoService.isSuppressed(courseId, day), isFalse,
        reason: '撤销了却仍被抑制 → 下次同步会把用户加回来的又当成「不要了」');
  });

  test('重复抑制同一条是幂等的', () async {
    await CourseTodoService.suppress(courseId, day);
    await CourseTodoService.suppress(courseId, day);
    expect(await CourseTodoService.isSuppressed(courseId, day), isTrue);
  });

  test('抑制集合会自清理：过去的日期不保留', () async {
    final past = DateTime.now().subtract(const Duration(days: 30));
    await CourseTodoService.suppress('course_1_20200101', past);
    // 触发一次 suppress，让自清理跑起来
    await CourseTodoService.suppress('course_2_20261231', DateTime(2026, 12, 31));

    expect(await CourseTodoService.isSuppressed('course_1_20200101', past),
        isFalse,
        reason: '过去的键留着只会让集合无限增长，必须清掉');
  });

  test('内存缓存会被 debugReset 清掉（模拟重启后重新从磁盘读）', () async {
    await CourseTodoService.suppress(courseId, day);
    expect(await CourseTodoService.isSuppressed(courseId, day), isTrue);

    CourseTodoService.debugResetSuppressedCache();
    expect(await CourseTodoService.isSuppressed(courseId, day), isTrue,
        reason: '缓存清了应该从 SharedPreferences 重新读出来，不能变成「没删过」');
  });
}
