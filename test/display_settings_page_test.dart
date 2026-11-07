import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/pages/display_settings_page.dart';

/// 「外观与个性化」页的回归测试。
///
/// 🔴 曾经的崩溃：`_modePill` 返回 [Expanded]，调用方又套了一层 [Padding]
///    —— Expanded 跨过 ParentDataWidget 直接挂到 Row 上，违反 Flutter 的
///    ParentDataWidget 契约 → 运行时抛「Incorrect use of ParentDataWidget」
///    → **整页灰屏**（文字、字号、语言等选项全都显示不出来）。
///
/// v1.0.9（2026-11-03）这页被收窄：字体大小 / 语言 / 动效强度 / 振动反馈四行
/// 移到「通用设置」容器页。这里同时锁两件事：
///   1. 剩下四组（明暗 / 主题色 / 背景 / 圆角 + 布局入口）都在，页面不崩；
///   2. **体感四项必须不在这里** —— 否则又变成两个真源。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: DisplaySettingsPage()));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('🔴 页面能正常渲染，不抛 ParentDataWidget 异常', (tester) async {
    await pump(tester);

    expect(find.text('外观与个性化'), findsOneWidget);
    expect(find.text('主题色'), findsOneWidget);
    expect(find.byType(Slider), findsWidgets);

    expect(tester.takeException(), isNull);
  });

  testWidgets('体感四项已移出本页（字体大小 / 语言 / 动效强度 / 振动反馈）',
      (tester) async {
    await pump(tester);

    expect(find.text('字体大小'), findsNothing, reason: '已移到「通用设置」');
    expect(find.text('语言'), findsNothing, reason: '已移到设置首屏，就地展开');
    expect(find.text('动效强度'), findsNothing, reason: '已改名为「振动强度」');
    expect(find.text('振动反馈'), findsNothing, reason: '已移到「通用设置」');
  });

  testWidgets('布局入口仍在：底部导航 / 首页板块 / 课表个性化', (tester) async {
    await pump(tester);
    await tester.scrollUntilVisible(find.text('课表个性化'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('课表个性化'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
