import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/pages/home_page.dart';

/// 首页首帧渲染的回归测试（2026-10-31 九次自检）。
///
/// 🔴 曾经的 bug（两个，都只在运行时才炸，静态检查查不到）：
///   1. `_dataDay` 声明为 `late DateTime`，赋值点在 `_load()` 的 setState 里
///      （异步链跑完才赋值），而**首帧 build 就会读它**
///      （`key: ValueKey(_dataDay)`）→ LateInitializationError
///      → 整页 ErrorWidget（冷启动首页白屏，且不会自愈）。
///   2. `HomeTodoList` 用了 `SingleTickerProviderStateMixin`，但它有**两个**
///      AnimationController（震动 / 重入场）→ 运行时抛
///      「multiple tickers were created」→ 待办列表整块报错。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('🔴 首页首帧不抛 LateInitializationError', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: HomePage()),
    ));
    // 只推进一帧 —— 正是出问题的时机（异步 _load 还没回来）。
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: '首页首帧不应抛异常');

    // 让首页的 30s 周期 Timer 自然到期并销毁 widget 树，
    // 否则测试结束时报「Timer is still pending」。
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('🔴 首页首帧渲染出标题（不是 ErrorWidget）', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: HomePage()),
    ));
    await tester.pump();

    expect(find.text('掌上锡院'), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);

    // 让首页的 30s 周期 Timer 自然到期，避免测试结束时报
    // 「A Timer is still pending even after the widget tree was disposed」。
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
