import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/todo.dart';
import 'package:xiyuan_pocket/services/ui_prefs.dart';
import 'package:xiyuan_pocket/widgets/home_todo_list.dart';

/// 首页待办列表的刷新链路（2026-11-03 修「任务列表不更新」）。
///
/// 这一串测试锁的是那个 bug 的两个成因，都在 [HomeTodoList] 内部：
///
/// 1. `_switching` 只靠函数末尾复位，而函数里有三处提前 `return` ——
///    任意一处先返回，`_switching` 就永久卡 true，之后 `didUpdateWidget`
///    每次都直接 `return`，父级传什么都不再生效。
/// 2. 切换动画期间到达的**同一天**增删改被整段丢弃（只记了日期，
///    日期没变所以切完也没人补账）。
///
/// 两条都表现为「数据变了、界面不动」，用户看到的就是「任务列表怎么不更新」。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiPrefs.setMotion(1.0);
  });

  Todo makeTodo(String id, String title, DateTime date, {int priority = 0}) {
    return Todo(
      id: id,
      title: title,
      date: date,
      completed: false,
      priority: priority,
    );
  }

  final day = DateTime(2026, 11, 3);

  Future<void> pumpList(
    WidgetTester tester, {
    required List<Todo> todos,
  }) async {
    // 视口拉高，保证整列表都建出来（AnimatedList 是懒构建的）。
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HomeTodoList(
          todos: todos,
          date: day,
          restPhrase: '还有',
          refreshTick: 0,
          onToggle: (_) {},
          onDelete: (_) {},
          onEdit: (_) {},
        ),
      ),
    ));
    // 入场动画：逐条插入 + 55ms 间隔，跑够时间让 _enterInitial 收尾。
    await tester.pumpAndSettle(const Duration(seconds: 2));
  }

  testWidgets('首屏能渲染出全部待办', (tester) async {
    await pumpList(tester, todos: [
      makeTodo('a', '写实验报告', day),
      makeTodo('b', '复习线性代数', day),
      makeTodo('c', '交作业', day),
    ]);

    expect(find.text('写实验报告'), findsOneWidget);
    expect(find.text('复习线性代数'), findsOneWidget);
    expect(find.text('交作业'), findsOneWidget);
  });

  testWidgets('🔴 同一天追加一条待办，列表必须跟着长出来', (tester) async {
    await pumpList(tester, todos: [makeTodo('a', '写实验报告', day)]);
    expect(find.text('新加的待办'), findsNothing);

    // 父级传入新数据（模拟 _load() 之后 setState）。
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HomeTodoList(
          todos: [
            makeTodo('a', '写实验报告', day),
            makeTodo('b', '新加的待办', day),
          ],
          date: day,
          restPhrase: '还有',
          refreshTick: 0,
          onToggle: (_) {},
          onDelete: (_) {},
          onEdit: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('新加的待办'), findsOneWidget,
        reason: '🔴 _switching 若卡在 true，这里会找不到新待办');
  });

  testWidgets('🔴 同一天删掉一条待办，列表必须跟着少一行', (tester) async {
    await pumpList(tester, todos: [
      makeTodo('a', '写实验报告', day),
      makeTodo('b', '要删掉的待办', day),
    ]);
    expect(find.text('要删掉的待办'), findsOneWidget);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HomeTodoList(
          todos: [makeTodo('a', '写实验报告', day)],
          date: day,
          restPhrase: '还有',
          refreshTick: 0,
          onToggle: (_) {},
          onDelete: (_) {},
          onEdit: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('要删掉的待办'), findsNothing,
        reason: '🔴 删除没同步说明 _applyDiff 根本没被调用');
    expect(find.text('写实验报告'), findsOneWidget);
  });

  testWidgets('🔴 连续多次更新都要生效（不是只能刷一次）', (tester) async {
    await pumpList(tester, todos: [makeTodo('a', '第一版', day)]);

    for (var round = 1; round <= 3; round++) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: HomeTodoList(
            todos: [makeTodo('a', '第 $round 版', day)],
            date: day,
          restPhrase: '还有',
            refreshTick: 0,
            onToggle: (_) {},
            onDelete: (_) {},
            onEdit: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(find.text('第 $round 版'), findsOneWidget,
          reason: '第 $round 次更新没生效');
    }
  });

  testWidgets('切到另一天，列表内容整体换掉', (tester) async {
    final next = day.add(const Duration(days: 1));
    await pumpList(tester, todos: [makeTodo('a', '今天的事', day)]);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HomeTodoList(
          todos: [makeTodo('b', '明天的事', next)],
          date: next,
          restPhrase: '还有',
          refreshTick: 0,
          onToggle: (_) {},
          onDelete: (_) {},
          onEdit: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(find.text('今天的事'), findsNothing);
    expect(find.text('明天的事'), findsOneWidget);
  });
}
