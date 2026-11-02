import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/pages/tools/course_table_settings_page.dart';

void main() {
  testWidgets('课表设置四个分组可切换且无布局异常', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      home: CourseTableSettingsPage(
        onAddCourse: () {},
        onEditTime: () {},
        onSyncTodos: () {},
        onClearAll: () {},
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('课表设置'), findsOneWidget);
    expect(find.text('布局与网格'), findsOneWidget);

    for (final tab in ['背景与日期', '课程卡', '数据与同步']) {
      await tester.tap(find.text(tab));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull, reason: '切换到 $tab 时异常');
    }
  });
}
