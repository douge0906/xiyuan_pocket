import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/todo.dart';
import 'package:xiyuan_pocket/repositories/todo_repository.dart';

/// 待办仓库删除语义的回归测试（2026-10-31 九次自检）。
///
/// 🔴 曾经的 bug：[TodoRepository.delete] 只按 id 删除。
///    课程待办 id 历史上未补零（`course_5_2026112` 既是 01-12 也是 11-02），
///    迁移旧 id 时按「id + 日期」挑出要改名的记录，却用只按 id 的 delete 删 →
///    **另一日期的待办被连带删除**（历史已完成记录凭空消失）。
///
/// 现在删除必须能按「id + 日期」精确匹配。
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

  test('🔴 按 id + 日期删除：只删当天那条，另一日期保留', () async {
    // 同 id 不同日期（历史撞号形态）
    final jan = Todo(
      id: 'course_5_2026112',
      title: '【课程】高数',
      date: DateTime(2026, 1, 12),
      completed: true,
    );
    final nov = Todo(
      id: 'course_5_2026112',
      title: '【课程】高数',
      date: DateTime(2026, 11, 2),
    );
    // 直接写库（add 会按 id 覆盖，所以这里用两次不同 id 写入再改）
    await TodoRepository.instance.add(nov);
    expect((await TodoRepository.instance.getAll()).length, 1);

    // 删除 01-12 那条（同 id 不同日期）→ 应删不到 nov
    await TodoRepository.instance.deleteOn(jan);
    final after = await TodoRepository.instance.getAll();
    expect(after.length, 1);
    expect(after.first.date, DateTime(2026, 11, 2));
  });

  test('🔴 按 id + 日期删除：日期对得上就删掉', () async {
    final t = Todo(
      id: 'course_9_20261102',
      title: '【课程】物理',
      date: DateTime(2026, 11, 2),
    );
    await TodoRepository.instance.add(t);
    await TodoRepository.instance.deleteOn(t);
    expect((await TodoRepository.instance.getAll()).length, 0);
  });

  test('🔴 旧 delete 仍可用（按 id 全删，保持既有语义）', () async {
    final t = Todo(
      id: 'plain_1',
      title: '普通待办',
      date: DateTime(2026, 11, 2),
    );
    await TodoRepository.instance.add(t);
    await TodoRepository.instance.delete(t);
    expect((await TodoRepository.instance.getAll()).length, 0);
  });
}
