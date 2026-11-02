import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/todo.dart';
import 'package:xiyuan_pocket/repositories/todo_repository.dart';

/// 待办仓库的批量操作回归测试（2026-10-30 四次自检）。
///
/// 钉住两个曾经出过问题的点：
///   1. 批量完成必须**按 id + 日期**匹配 —— 历史课程待办 id 未补零时
///      （`course_5_2026112` 既是 01-12 也是 11-02），
///      只按 id 会把**未来日期**的那条一起划掉；
///   2. 批量新增必须**同 id 覆盖**，不能追加出两条一样的。
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

  test('🔴 日期不匹配的不会被完成（未来日期不被误划）', () async {
    // 库里这条的 id 是历史未补零格式，日期落在 11-02。
    await TodoRepository.instance.add(Todo(
      id: 'course_5_2026112',
      title: '【课程】高数',
      date: DateTime(2026, 11, 2),
    ));

    // 用 01-12 的日期去批量完成 → 日期对不上，一条都不该动。
    final changed = await TodoRepository.instance.completeManyWithDays([
      (id: 'course_5_2026112', day: DateTime(2026, 1, 12)),
    ]);
    expect(changed, 0);
    final all = await TodoRepository.instance.getAll();
    expect(all.length, 1);
    expect(all.first.completed, isFalse);
    expect(all.first.date, DateTime(2026, 11, 2));
  });

  test('🔴 id 与日期都对得上才会完成', () async {
    await TodoRepository.instance.add(Todo(
      id: 'course_5_20260112',
      title: '【课程】高数',
      date: DateTime(2026, 1, 12),
    ));
    final changed = await TodoRepository.instance.completeManyWithDays([
      (id: 'course_5_20260112', day: DateTime(2026, 1, 12)),
    ]);
    expect(changed, 1);
    final all = await TodoRepository.instance.getAll();
    expect(all.first.completed, isTrue);
  });

  test('🔴 批量新增：同 id 覆盖，不追加', () async {
    await TodoRepository.instance.addMany([
      Todo(id: 'b1', title: 'A', date: DateTime(2026, 11, 2)),
      Todo(id: 'b2', title: 'B', date: DateTime(2026, 11, 2)),
    ]);
    await TodoRepository.instance.addMany([
      Todo(id: 'b1', title: 'A2', date: DateTime(2026, 11, 2)),
    ]);
    final all = await TodoRepository.instance.getAll();
    expect(all.where((t) => t.id == 'b1').length, 1);
    expect(all.firstWhere((t) => t.id == 'b1').title, 'A2');
    expect(all.length, 2);
  });
}
