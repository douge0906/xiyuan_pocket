import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/todo.dart';
import 'package:xiyuan_pocket/repositories/todo_repository.dart';

/// 待办完成态「可逆」的回归测试（2026-11-02）。
///
/// 🔴 用户报告：点完成之后**无法取消完成**（勾选框弹不回去）。
///
/// 根因：[Todo.copyWith] 的 `completedDay` 参数用 `?? this.completedDay`，
///       传 `null` 是**保留旧值**而不是清空。所有「取消完成」的写路径都写
///       `completedDay: null`（以为是清空），实际保留了上次的完成日 →
///       [Todo.isDoneOn] 读到的仍是 true。
///
/// 正确写法：取消完成时必须同时传 `clearCompletedDay: true`。
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

  group('copyWith 的 completedDay 语义', () {
    test('🔴 只传 completedDay: null 清不掉（说明为什么必须用 clearCompletedDay）',
        () {
      final t = Todo(
        id: 'x',
        title: 'x',
        date: DateTime(2026, 11, 2),
        completed: true,
        completedDay: '2026-11-02',
      );
      final still = t.copyWith(completed: false, completedDay: null);
      expect(still.completedDay, '2026-11-02',
          reason: 'null 是「不改」，不是「清空」——这就是 bug 的源头');
      expect(still.isDoneOn(DateTime(2026, 11, 2)), isTrue,
          reason: 'completedDay 还在 → 界面仍显示已完成');

      final cleared = t.copyWith(completed: false, clearCompletedDay: true);
      expect(cleared.completedDay, isNull);
      expect(cleared.isDoneOn(DateTime(2026, 11, 2)), isFalse);
    });
  });

  group('仓库层：勾选后必须能取消勾选', () {
    test('🔴 toggleCompleteOn 连点两次回到未完成', () async {
      final t = Todo(
        id: 'plain-1',
        title: '交作业',
        date: DateTime(2026, 11, 2),
        completed: false,
      );
      await TodoRepository.instance.add(t);

      // 第一次：勾上
      final done = await TodoRepository.instance
          .toggleCompleteOn(t, DateTime(2026, 11, 2));
      expect(done.completed, isTrue);
      expect(done.completedDay, '2026-11-02');
      expect(done.isDoneOn(DateTime(2026, 11, 2)), isTrue);

      // 第二次：取消 —— 这里曾经失败（completedDay 没被清掉）
      final undone = await TodoRepository.instance
          .toggleCompleteOn(done, DateTime(2026, 11, 2));
      expect(undone.completed, isFalse, reason: 'completed 必须回到 false');
      expect(undone.completedDay, isNull,
          reason: '🔴 completedDay 必须被清空，否则 isDoneOn 仍为 true');
      expect(undone.isDoneOn(DateTime(2026, 11, 2)), isFalse,
          reason: '界面读的就是 isDoneOn —— 它必须是 false 才弹得回去');

      // 落库也要正确（重新读一遍）
      final reread = (await TodoRepository.instance.getAll()).first;
      expect(reread.isDoneOn(DateTime(2026, 11, 2)), isFalse);
    });

    test('🔴 toggleComplete 连点两次回到未完成', () async {
      final t = Todo(
        id: 'plain-2',
        title: '复习',
        date: DateTime(2026, 11, 2),
      );
      await TodoRepository.instance.add(t);
      final done = await TodoRepository.instance.toggleComplete(t);
      expect(done.isDoneOn(DateTime(2026, 11, 2)), isTrue);
      final undone = await TodoRepository.instance.toggleComplete(done);
      expect(undone.isDoneOn(DateTime(2026, 11, 2)), isFalse,
          reason: '🔴 第二次点击必须真的取消');
    });

    test('重复待办：勾今天不影响明天，且能取消', () async {
      final t = Todo(
        id: 'repeat-1',
        title: '背单词',
        date: DateTime(2026, 11, 2),
        repeatType: 'daily',
      );
      await TodoRepository.instance.add(t);
      final d1 = await TodoRepository.instance
          .toggleCompleteOn(t, DateTime(2026, 11, 2));
      expect(d1.isDoneOn(DateTime(2026, 11, 2)), isTrue);
      expect(d1.isDoneOn(DateTime(2026, 11, 3)), isFalse,
          reason: '重复待办按天独立');
      final d2 = await TodoRepository.instance
          .toggleCompleteOn(d1, DateTime(2026, 11, 2));
      expect(d2.isDoneOn(DateTime(2026, 11, 2)), isFalse, reason: '必须能取消');
    });
  });
}
