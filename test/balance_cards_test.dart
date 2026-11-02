import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/widgets/balance_cards.dart';

/// 余额卡片交互回归测试（2026-10-30 五次自检）。
///
/// 钉住两件事：
///   1. **数字滚动**：数值变化后最终必须显示**新值**（旧值不能残留）；
///   2. **手动刷新按钮**：有 onRefresh 时右上角出现刷新点，没有则显示右箭头。
void main() {
  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(body: SizedBox(width: 320, child: child)),
      );

  Widget card({
    required double? numeric,
    VoidCallback? onRefresh,
    bool refreshing = false,
  }) {
    return wrap(
      UserBalanceCards(
        isDark: false,
        cardBalance: numeric,
        balanceLoading: false,
        balanceRefreshing: refreshing,
        balanceError: null,
        campusOnline: true,
        probed: true,
        elec: null,
        elecLoading: false,
        elecError: null,
        dorm: null,
        onRefreshCard: onRefresh,
        onDetailCard: null,
        onElecTap: () {},
      ),
    );
  }

  testWidgets('🔴 数值变化后最终显示新值', (tester) async {
    await tester.pumpWidget(card(numeric: 12.34));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('¥ 12.34'), findsWidgets);

    // 换成新值 → 滚动结束后应显示新值，且旧值不再出现。
    await tester.pumpWidget(card(numeric: 56.78));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('¥ 56.78'), findsWidgets);
    expect(find.text('¥ 12.34'), findsNothing);
  });

  testWidgets('🔴 有刷新入口时显示刷新点，点击触发回调', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(card(numeric: 1.00, onRefresh: () => tapped++));
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tapped, 1);
  });

  testWidgets('🔴 没有刷新入口时显示右箭头而不是刷新点', (tester) async {
    await tester.pumpWidget(card(numeric: 1.00));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsWidgets);
  });

  testWidgets('🔴 刷新中显示转圈图标且不可点', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(card(
      numeric: 1.00,
      onRefresh: () => tapped++,
      refreshing: true,
    ));
    await tester.pump();
    expect(find.byIcon(Icons.sync_rounded), findsOneWidget);
    // 转圈是无限动画，pumpAndSettle 不会结束 → 用固定时长推进。
    await tester.tap(find.byIcon(Icons.sync_rounded), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tapped, 0);
  });
}
