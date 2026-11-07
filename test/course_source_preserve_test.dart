import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/services/course_storage.dart';

/// 🔴 回归：PDF / 实验课导入的课标成 [CourseSource.imported]，
/// 教务同步（`mergeServerCoursesInto`）必须**原样保留**它们。
///
/// 曾经的 bug：两者都标 `server`，而合并逻辑是「先 removeWhere(source==server)
/// 再放入本次教务结果」→ 用户导入 PDF 课表后一登录，那批课被静默删光。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Course course(String id, String name, CourseSource src,
          {int weekday = 1, String weeks = '1-16周'}) =>
      Course(
        id: id,
        name: name,
        weekday: weekday,
        startSlot: 1,
        endSlot: 2,
        weeks: weeks,
        colorValue: 0xFF667EEA,
        source: src,
      );

  test('教务同步保留 imported 的课，只替换 server 的课', () async {
    final tableId = await CourseStorage.createTable(name: '本学期');
    await CourseStorage.mergeServerCoursesInto(tableId, [
      course('old_server', '旧的教务课', CourseSource.server),
      course('pdf_1', 'PDF 导入的实验课', CourseSource.imported),
      course('manual_1', '手动加的课', CourseSource.manual),
    ]);

    // 第二次同步：教务这次返回完全不同的一门课
    final r = await CourseStorage.mergeServerCoursesInto(tableId, [
      course('new_server', '新的教务课', CourseSource.server),
    ]);

    final names = r.merged.map((c) => c.name).toSet();
    expect(names, contains('新的教务课'), reason: '本次教务结果必须进来');
    expect(names, isNot(contains('旧的教务课')), reason: '上一轮 server 课要被替换');
    expect(names, contains('PDF 导入的实验课'),
        reason: 'imported 的课不能被教务同步删掉 —— 这正是本测试要钉住的回归');
    expect(names, contains('手动加的课'), reason: 'manual 的课本来就要保留');
  });

  test('source 的 JSON 往返：三值都能存能读', () {
    for (final src in CourseSource.values) {
      final back = Course.fromJson(
          course('x', 'n', src).toJson());
      expect(back.source, src, reason: '${src.name} 存进去读出来必须还是它');
    }
  });

  test('旧数据没写 source 字段时按 manual 处理（不会被同步删掉）', () {
    final back = Course.fromJson(<String, dynamic>{
      'id': 'legacy',
      'name': '旧课',
      'weekday': 1,
      'startSlot': 1,
      'endSlot': 2,
      'weeks': '1-16周',
    });
    expect(back.source, CourseSource.manual);
  });

  test('实验课导入是并集：原有普通课不会被挤掉', () async {
    await CourseStorage.mergeServerCoursesInto(
      await CourseStorage.activeTableId(),
      [
        course('c1', '高等数学', CourseSource.server, weekday: 1),
        course('c2', '大学英语', CourseSource.server, weekday: 2),
      ],
    );

    // 模拟「导入实验课」：在当前课表后追加，不整体替换
    final before = await CourseStorage.loadCourses();
    await CourseStorage.saveCourses([
      ...before,
      course('lab_1', '物理实验', CourseSource.imported, weekday: 3),
    ]);

    final after = await CourseStorage.loadCourses();
    final names = after.map((c) => c.name).toSet();
    expect(names, containsAll(['高等数学', '大学英语', '物理实验']),
        reason: '实验课是补充，不该把已有的普通课冲掉');
    expect(after.length, 3);
  });
}
