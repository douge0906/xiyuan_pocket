import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiyuan_pocket/pages/onboarding_page.dart';
import 'package:xiyuan_pocket/services/legal_consent.dart';
import 'package:xiyuan_pocket/services/nav_prefs.dart';
import 'package:xiyuan_pocket/services/onboarding_prefs.dart';

/// 快速开始四步：能不能走完、模式选完有没有真落盘、没勾同意时不能过。
///
/// 这几个点都必须有测试：它们是「首次启动」的唯一路径，
/// 一旦哪一步不动，新装的人就卡在门口 —— 而老用户永远看不到。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // NavPrefs 是进程级 notifier：上一个用例改过的布局会漏到下一个用例，
    // 必须显式回出厂，否则「点眼睛能不能隐藏」这种断言全看执行顺序。
    await NavPrefs.reset();
  });

  /// 点一下再走两帧：翻页用的是 420ms 动画，只 pump 一次长时长
  /// 只能把第一帧推到终点，动画控制器要到下一帧才真正开始计时。
  ///
  /// 1100ms 是给最后一步留的：点完「同意并去登录」会先停 980ms 播收尾动画
  /// 再 pop，pump 不够就会留下 pending timer，测试直接判失败。
  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
  }

  Future<void> pumpOnboarding(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const OnboardingPage(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 900));
  }

  testWidgets('四步能走完，选极简模式会真正隐藏三页', (tester) async {
    await pumpOnboarding(tester);
    expect(find.text('开始设置'), findsOneWidget);

    await tapText(tester, '开始设置');
    // 第二步：五个标签的介绍
    expect(find.text('五大功能，统一锡院'), findsOneWidget);

    await tapText(tester, '继续');
    // 第三步：两张模式卡片
    expect(find.text('默认模式'), findsOneWidget);
    expect(find.text('极简模式'), findsOneWidget);

    await tapText(tester, '极简模式');
    await tapText(tester, '就这个');

    // 第四步：同意
    expect(find.text('我已阅读并同意'), findsOneWidget);
    await tapText(tester, '我已阅读并同意');
    await tapText(tester, '同意并去登录');

    // 模式落进 NavPrefs：只剩课表（「我的」是固定页，永远可见、不参与隐藏）
    expect(NavPrefs.visible, {NavPage.course, NavPage.user});
    expect(await OnboardingPrefs.isDone(), isTrue);
    expect(await OnboardingPrefs.mode(), OnboardingMode.minimal);
    expect(await LegalConsentService.isAccepted(), isTrue);

    // 让周期定时器随页面销毁
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('第二步点标签只看介绍，「调整」态下点才是收起', (tester) async {
    await pumpOnboarding(tester);
    await tapText(tester, '开始设置');

    // 平时点标签只是切介绍，不会把它关掉。
    final tab = find.byKey(const ValueKey<String>('bar-message'));
    expect(tab, findsOneWidget);

    await tester.tap(tab);
    await tester.pump(const Duration(milliseconds: 300));
    expect(NavPrefs.layout.hidden.contains(NavPage.message), isFalse);

    // 进「调整」态再点，才是收起。
    await tester.tap(find.text('调整'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(tab);
    await tester.pump(const Duration(milliseconds: 300));

    expect(NavPrefs.layout.hidden.contains(NavPage.message), isTrue);
    // 模拟导航条上也真的没了
    expect(NavPrefs.visible.contains(NavPage.message), isFalse);

    // 再点一次放回来
    await tester.tap(tab);
    await tester.pump(const Duration(milliseconds: 300));
    expect(NavPrefs.layout.hidden.contains(NavPage.message), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('没勾同意时点「同意并去登录」不前进，什么都不写', (tester) async {
    await pumpOnboarding(tester);
    await tapText(tester, '开始设置');
    await tapText(tester, '继续');
    await tapText(tester, '就这个');

    await tapText(tester, '同意并去登录');

    // 还停在第四步，且什么都没写
    expect(find.text('同意并去登录'), findsOneWidget);
    expect(await OnboardingPrefs.isDone(), isFalse);
    expect(await LegalConsentService.isAccepted(), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('默认模式 = 四页都显示', (tester) async {
    await pumpOnboarding(tester);
    await tapText(tester, '开始设置');
    await tapText(tester, '继续');
    await tapText(tester, '就这个');
    await tapText(tester, '我已阅读并同意');
    await tapText(tester, '同意并去登录');

    expect(NavPrefs.visible, {
      NavPage.home,
      NavPage.message,
      NavPage.course,
      NavPage.service,
      NavPage.user,
    });
    expect(await OnboardingPrefs.mode(), OnboardingMode.full);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
