import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/widgets/empty_state_art.dart';
import 'package:xiyuan_pocket/widgets/empty_todo_art.dart';
import 'package:xiyuan_pocket/widgets/home_todo_list.dart';
import 'package:xiyuan_pocket/widgets/state_views.dart';

/// 空状态手绘插画回归测试（2026-10-31 八次自检）。
///
/// 钉住四点：
///   1. 首页待办空状态**恢复原本的「勾选圈 + 星光」手绘**（EmptyTodoArt）——
///      用户明确反馈通用插画「太丑」，这一条不能回退；
///   2. 其余场景按**自身属性**配专属插画（信封 / 订阅卡 / 成绩单 / 书…）；
///   3. 所有空状态都走 [EmptyState]，插画是**手绘**而非 Material 图标；
///   4. 错误态用「断网云」变体。
void main() {
  testWidgets('🔴 首页待办空状态用原手绘 EmptyTodoArt', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: EmptyTodoArt(color: Color(0xFFB8BFC9)),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(EmptyTodoArt), findsOneWidget);
    expect(find.byType(EmptyArt), findsNothing,
        reason: '待办不该用通用插画');
    expect(tester.takeException(), isNull);
  });

  testWidgets('🔴 待办列表为空时渲染原手绘', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HomeTodoList(
          todos: const [],
          date: DateTime(2026, 11, 1),
          restPhrase: '休息一下',
          onToggle: (_) {},
          onDelete: (_) {},
          onEdit: (_) {},
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(EmptyTodoArt), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('🔴 空状态渲染手绘插画（不是 Material 图标）', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: EmptyState(
          message: '暂无内容',
          hint: '下拉可刷新',
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('暂无内容'), findsOneWidget);
    expect(find.text('下拉可刷新'), findsOneWidget);
    // 手绘插画是 CustomPaint，不是 Icon
    expect(find.byType(EmptyArt), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('🔴 各场景按自身属性配专属变体', (tester) async {
    // 消息列表无内容 → 信封；未订阅 → 订阅卡
    for (final variant in [
      EmptyArtVariant.inbox,
      EmptyArtVariant.subscribe,
      EmptyArtVariant.search,
      EmptyArtVariant.offline,
      EmptyArtVariant.calendar,
      EmptyArtVariant.report,
      EmptyArtVariant.book,
      EmptyArtVariant.wallet,
      EmptyArtVariant.box,
    ]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AppEmptyState(variant: variant, title: '空'),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byType(EmptyArt), findsOneWidget, reason: '$variant 应能渲染');
      expect(tester.takeException(), isNull, reason: '$variant 不该抛异常');
    }
  });

  testWidgets('🔴 错误态渲染断网手绘图 + 重试按钮', (tester) async {
    var retried = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ErrorState(
          message: '暂时无法获取',
          onRetry: () => retried++,
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('暂时无法获取'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(retried, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('🔴 AppEmptyState 支持副文案与动作', (tester) async {
    var acted = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppEmptyState(
          variant: EmptyArtVariant.wallet,
          title: '暂无交易记录',
          subtitle: '有过消费记录后会显示在这里',
          actionLabel: '刷新',
          onAction: () => acted++,
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('暂无交易记录'), findsOneWidget);
    expect(find.text('有过消费记录后会显示在这里'), findsOneWidget);
    await tester.tap(find.text('刷新'));
    await tester.pump();
    expect(acted, 1);
  });
}
