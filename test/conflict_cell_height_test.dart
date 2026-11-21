// T1 回归守卫（2026-11-14 返工）：冲突组内各门课程必须按**自己的**节次
// 区间撑高，短课不得被组内最长课拉满。
//
// 场景：A 占第 1-2 节（两节），B 占第 1-3 节（三节），同格冲突轮播。
// 轮播到 A 时卡片高度应为两节高；切到 B 时应为三节高。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/widgets/course_grid_widgets.dart';

Course _c(String name, int s, int e) => Course(
      id: 'x_$name',
      name: name,
      weekday: 1,
      startSlot: s,
      endSlot: e,
      weeks: '1-16周',
      colorValue: 0xFF3B82F6,
    );

double _cardHeight(WidgetTester tester) {
  final box = tester.renderObject(find.byType(CourseCardWidget).first);
  return (box as RenderBox).size.height;
}

void main() {
  const rowHeight = 40.0;
  const dividerHeight = 1.0;
  // 两节高 / 三节高
  const twoSlot = 2 * rowHeight + dividerHeight;
  const threeSlot = 3 * rowHeight + 2 * dividerHeight;

  testWidgets('冲突格：短课按两节撑高，长课按三节撑高，互不统一', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 120,
            height: threeSlot,
            child: ConflictCell(
              courses: [_c('短课A', 1, 2), _c('长课B', 1, 3)],
              startIdxs: const [0, 0],
              endIdxs: const [1, 2],
              groupStartIdx: 0,
              rowHeight: rowHeight,
              dividerHeight: dividerHeight,
              selectedWeek: 1,
              onOpenDetailOf: (c) {},
              onResolve: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    // 初始 _i=0：短课 A，应两节高
    expect(find.text('短课A'), findsOneWidget);
    expect(_cardHeight(tester), closeTo(twoSlot, 0.01),
        reason: '短课 A 应只占两节高度，不得被拉到三节');

    // 切到长课 B
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('长课B'), findsOneWidget);
    expect(_cardHeight(tester), closeTo(threeSlot, 0.01),
        reason: '长课 B 应占三节高度');

    await tester.pumpWidget(const SizedBox());
  });
}
