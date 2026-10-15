// 回归守卫（2026-10-14）：刷新必须写回「我的课表」，导入的第二份表不能被覆盖。
//
// 曾经的 bug：createTable 忘了把 kind 传给 CourseTable 构造（参数有默认值
// kindOwn），导致导入的他人课表也被存成 own → resolveSyncTargetId 认为
// 当前激活那份就是"我的课表" → 我的教务课表直接灌进第二份表。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/models/course_table.dart';
import 'package:xiyuan_pocket/services/course_storage.dart';

Course _c(String id, String name, int wd, int s, int e,
        {CourseSource src = CourseSource.server}) =>
    Course(
      id: id,
      name: name,
      weekday: wd,
      startSlot: s,
      endSlot: e,
      weeks: '1-16周',
      colorValue: 0xFF3B82F6,
      source: src,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('导入第二份表后刷新：应写回 own 表、imported 表不被覆盖', () async {
    SharedPreferences.setMockInitialValues({});

    // ① 我的课表（own）
    await CourseStorage.createTable(
      name: '我的课表',
      courses: [_c('c1', '我的手动课', 1, 1, 2, src: CourseSource.manual)],
      kind: CourseTable.kindOwn,
    );
    final t0 = await CourseStorage.loadTables();
    final ownId = t0.firstWhere((t) => t.kind == CourseTable.kindOwn).id;

    // ② 导入第二份（imported）→ createTable 会自动切过去
    await CourseStorage.createTable(
      name: '别人的课表',
      courses: [_c('c2', '别人的课', 2, 3, 4)],
      kind: CourseTable.kindImported,
    );
    final activeId = await CourseStorage.activeTableId();

    // ③ 刷新目标解析
    final target = await CourseStorage.resolveSyncTargetId();

    // ④ 合并（模拟账号返回一门新课）
    if (target != null) {
      await CourseStorage.mergeServerCoursesInto(target, [_c('c3', '账号新课', 3, 5, 6)]);
    }

    // ⑤ 断言
    final tables = await CourseStorage.loadTables();
    final imported = tables.firstWhere((t) => t.id == activeId);
    final own = tables.firstWhere((t) => t.id == ownId);

    expect(target, ownId, reason: '刷新必须写回 own 表');
    expect(imported.courses.map((c) => c.name).toList(), ['别人的课'],
        reason: 'imported 表不能被我的课表覆盖');
    expect(own.courses.map((c) => c.name).toSet(),
        {'我的手动课', '账号新课'}, reason: 'own 表应更新（保留手动课 + 换教务）');
  });
}
