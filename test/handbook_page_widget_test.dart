import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/pages/tools/handbook_page.dart';
import 'package:xiyuan_pocket/services/handbook_repository.dart';

/// 「锡院学生手册」UI 冒烟测试。
///
/// 数据层单测覆盖的是解析与召回；这里专门验证「渲染」不炸：
/// 章节原文页里有 100 张表 + 28 处来源脚注卡，表格放在横向
/// SingleChildScrollView 里曾是渲染雷区（无限宽约束会让 Table 抛异常）。
/// 本测试把含表的章节逐个 pump 出来，确认布局阶段零异常，并覆盖
/// 附带一键查的空态 / 命中 / 回跳与来源覆盖页。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HandbookData data;

  setUpAll(() {
    final raw = File('assets/seed/handbook_2026.json').readAsStringSync();
    data = HandbookRepository.fromJson(
        jsonDecode(raw) as Map<String, dynamic>);
  });

  /// 逐个把含表格的章节泵出来，断言渲染期没有异常。
  testWidgets('章节原文页：表格 + 来源脚注卡逐章渲染不抛异常',
      (tester) async {
    final withTables = data.visibleChapters
        .where((c) => c.sections
            .expand((s) => s.blocks)
            .any((b) => b.kind == 'tbl' || b.isSource))
        .toList();
    expect(withTables, isNotEmpty);

    for (final chapter in withTables) {
      await tester.pumpWidget(MaterialApp(
        home: HandbookChapterPage(chapter: chapter),
      ));
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: '章节「${chapter.title}」渲染出现布局异常',
      );
    }
  });

  testWidgets('12.3 奖学金表与来源脚注原文可见', (tester) async {
    final c12 = data.chapter('十二、');
    expect(c12, isNotNull);
    await tester.pumpWidget(MaterialApp(
      home: HandbookChapterPage(chapter: c12!),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // 表格单元格与来源脚注都是原文照录。
    expect(find.text('6000', skipOffstage: false), findsWidgets);
    expect(find.textContaining('《无锡学院学校奖学金评定办法（试行）》',
        skipOffstage: false), findsWidgets);
  });

  testWidgets('来源与覆盖页渲染附录 D / C 原文表不抛异常', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HandbookSourcesPage(data: data),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('来源与覆盖'), findsOneWidget);
  });

  testWidgets('附带一键查：空态 → 输入 → 命中列表', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HandbookSearchPage(data: data),
    ));
    await tester.pump();
    expect(find.text('关键词一键查（附带功能）'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '奖学金');
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    // 命中回跳位置行存在（最佳答案卡 + 相关结果）。
    expect(find.byIcon(Icons.place_outlined), findsWidgets);
  });
}
