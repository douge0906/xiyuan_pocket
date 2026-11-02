import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/widgets/home_week_strip.dart';

/// 周次条交互回归测试（2026-10-30 自检）。
///
/// 钉住两个曾经出错的点：
///   1. **点击**必须能选中某一天（抬起时提交，不是按下即切）；
///   2. **按住横向拖动**必须能连续切换日期（跟手，不只是弹一下）。
void main() {
  testWidgets('周次条点按与横向拖动切换日期', (tester) async {
    DateTime selected = DateTime(2026, 10, 26);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SizedBox(
            width: 350,
            child: HomeWeekStrip(
              selected: selected,
              onSelected: (d) => setState(() => selected = d),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('30'));
    await tester.pumpAndSettle();
    expect(selected.day, 30);

    final box = tester.getRect(find.byType(HomeWeekStrip));
    await tester.dragFrom(
      Offset(box.left + 20, box.center.dy),
      const Offset(250, 0),
    );
    await tester.pumpAndSettle();
    expect(selected.day, greaterThanOrEqualTo(30));
  });

  testWidgets('🔴 拖动过程中会连续切换多个日期（跟手，不是只切一次）',
      (tester) async {
    final seen = <int>[];
    DateTime selected = DateTime(2026, 10, 26);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SizedBox(
            width: 350,
            child: HomeWeekStrip(
              selected: selected,
              onSelected: (d) => setState(() {
                selected = d;
                seen.add(d.day);
              }),
            ),
          ),
        ),
      ),
    ));

    final box = tester.getRect(find.byType(HomeWeekStrip));
    // 分多段拖过 3 天的距离（每段 40px）→ 应该至少触发 2 次切换
    final gesture = await tester.startGesture(
        Offset(box.left + 40, box.center.dy));
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(seen.length, greaterThanOrEqualTo(2),
        reason: '拖过 4 格应至少切换 2 次，实际：$seen');
  });

  testWidgets('🔴 轻点不应触发拖动逻辑（只切一次）', (tester) async {
    final seen = <int>[];
    DateTime selected = DateTime(2026, 10, 26);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SizedBox(
            width: 350,
            child: HomeWeekStrip(
              selected: selected,
              onSelected: (d) => setState(() {
                selected = d;
                seen.add(d.day);
              }),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('29'));
    await tester.pumpAndSettle();
    expect(seen, [29]);
  });
}
