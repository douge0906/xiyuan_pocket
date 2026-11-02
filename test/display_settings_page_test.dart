import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/pages/display_settings_page.dart';

/// 「界面与显示」页的回归测试（2026-10-30 七次自检）。
///
/// 🔴 曾经的崩溃：`_modePill` 返回 [Expanded]，调用方又套了一层 [Padding]
///    —— Expanded 跨过 ParentDataWidget 直接挂到 Row 上，违反 Flutter 的
///    ParentDataWidget 契约 → 运行时抛「Incorrect use of ParentDataWidget」
///    → **整页灰屏**（文字、字号、语言等选项全都显示不出来）。
///
/// 这个测试直接渲染该页：只要再出现 ParentDataWidget 误用就会红。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('🔴 页面能正常渲染，不抛 ParentDataWidget 异常', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const MaterialApp(
      home: DisplaySettingsPage(),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    // 关键文案都在
    expect(find.text('界面与显示'), findsOneWidget);
    expect(find.text('字体大小'), findsOneWidget);
    expect(find.text('语言'), findsOneWidget);
    expect(find.text('动效强度'), findsOneWidget);
    expect(find.text('振动反馈'), findsOneWidget);
    expect(find.text('主题色'), findsOneWidget);

    // 滑杆（字号 / 圆角 / 动效）都渲染出来了
    expect(find.byType(Slider), findsWidgets);

    // 页面本身没有崩溃 → 不存在异常
    expect(tester.takeException(), isNull);
  });

  testWidgets('🔴 语言切换按钮可点且不崩', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const MaterialApp(
      home: DisplaySettingsPage(),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    // 语言胶囊：中文 / English
    expect(find.text('中文'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);

    await tester.tap(find.text('English'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}
