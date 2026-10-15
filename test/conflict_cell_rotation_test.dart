// 回归守卫（2026-10-14）：冲突格 3 秒轮播必须真的切换。
//
// 曾经的 bug：切换靠 `AnimationController.repeat()` 回绕瞬间的 `value < 0.01`
// 判断，低帧率下该窗口会被整帧跳过 → 倒计时不走、课程也不切换
// （用户报告「冲突倒计时无效、无反应」）。现改 Timer 驱动。
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

void main() {
  testWidgets('冲突格：3 秒后切到下一门，再 3 秒回到第一门', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 120,
            height: 120,
            child: ConflictCell(
              courses: [_c('第一门课', 1, 2), _c('第二门课', 1, 2)],
              selectedWeek: 1,
              onResolve: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('第一门课'), findsOneWidget, reason: '初始应显示第一门');

    // 推进 3 秒 → 切换
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('第二门课'), findsOneWidget, reason: '3 秒后应切到第二门');

    // 再 3 秒 → 回到第一门（循环）
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('第一门课'), findsOneWidget, reason: '应循环回第一门');

    // 放掉定时器，避免测试结束时报 pending timer
    await tester.pumpWidget(const SizedBox());
  });
}
