import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/pages/service_settings_page.dart';
import 'package:xiyuan_pocket/services/service_catalog.dart';

/// 「设置页 → 服务管理」空白异常的回归测试。
///
/// 这个页面 2026-11-03 加了拖动排序（`ReorderableListView.builder` 放进
/// `ListView` 的一格里）。只要布局约束给错，整页就会白屏 —— 而 `analyze`
/// 和 `flutter test` 的其它用例都发现不了，因为没人真的把它 build 出来。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('服务管理页必须真的渲染出全部服务，不能白屏', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ServiceSettingsPage(hidden: <String>[]),
    ));
    // 首帧 + _loadOrder() 的异步回填。
    await tester.pumpAndSettle();

    // 🟥 白屏断言：一个服务名都找不到就是空白。
    for (final tool in mainServices) {
      expect(
        find.text(tool.name),
        findsOneWidget,
        reason: '服务管理页没有渲染出「${tool.name}」——页面空白',
      );
    }

    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(find.byType(Switch), findsNWidgets(mainServices.length));
    // 没有任何一条布局异常逃出来。
    expect(tester.takeException(), isNull);
  });

  testWidgets('隐藏过的服务仍然渲染，只是开关是关的', (tester) async {
    final hiddenId = mainServices.first.id;
    await tester.pumpWidget(MaterialApp(
      home: ServiceSettingsPage(hidden: <String>[hiddenId]),
    ));
    await tester.pumpAndSettle();

    expect(find.text(mainServices.first.name), findsOneWidget);
    expect(find.text('已隐藏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
