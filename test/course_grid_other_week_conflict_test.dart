// 回归守卫（2026-11-04，用户 m20950 #4）：「显示非本周课程」打开后，
// 同一时段非本周的课必须能进冲突格轮播 —— 用户原话：「显示的非本周课程
// 无法触发冲突切换」。
//
// 曾经的 bug：分组时非本周课走 `if (!it.active) { inactive.add(it); continue; }`
// 各自单独成组 → 同格永远只有一张卡 → 既轮播不了，也点不到下面那张；
// 用户明明看到两门课撞在一起，却没有任何入口处理。
//
// 这里用**纯 widget 测试**跑，不需要真机：CourseWeekGrid 是纯布局组件，
// 只要给它一份「本周一门 + 非本周一门、同节次」的数据，就能断言
//   ①该格出现 ConflictCell（而不是 CourseCardWidget 直接单卡）；
//   ②3 秒后轮播到非本周那门；
//   ③点开详情拿到的是**当前正在显示的那门**，不是永远第一门。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/services/course_storage.dart';
import 'package:xiyuan_pocket/widgets/course_grid_widgets.dart';

Course _course({
  required String id,
  required String name,
  required int weekday,
  String weeks = '1-16周',
  int start = 1,
  int end = 2,
}) =>
    Course(
      id: id,
      name: name,
      weekday: weekday,
      startSlot: start,
      endSlot: end,
      weeks: weeks,
      colorValue: 0xFF3B82F6,
    );

Widget _grid(List<Course> courses, {
  required int selectedWeek,
  required void Function(Course) onOpenDetail,
  required void Function(List<Course>) onResolve,
}) =>
    MaterialApp(
      home: Scaffold(
        // CourseWeekGrid 内部是 Stack + Positioned，必须有确定高度
        // （在课表页里由 PageView 给定；测试里给个够高的固定值）。
        body: SizedBox(
          height: 900,
          child: CourseWeekGrid(
            blocks: kDefaultCourseBlocks,
            todayWeekday: 1,
            selectedWeek: selectedWeek,
            courses: courses,
            isDark: false,
            surfaceColor: Colors.white,
            onOpenAdd: (_, __, ___) {},
            onOpenDetail: onOpenDetail,
            onResolveConflict: onResolve,
            useFixedRowHeight: true,
            previewScale: 1.0,
          ),
        ),
      ),
    );

void main() {
  // 这些用例都依赖「显示非本周课程」开关，测试跑完要还原，否则会污染别的用例。
  setUp(() => CourseStorage.showOtherWeeksCache = true);
  tearDown(() => CourseStorage.showOtherWeeksCache = false);

  testWidgets('本周课 + 非本周课同节次 → 该格是冲突格，能轮播切换', (tester) async {
    final thisWeek = _course(id: 'a', name: '本周的课', weekday: 1, weeks: '1-16周');
    final otherWeek =
        _course(id: 'b', name: '非本周的课', weekday: 1, weeks: '17-20周');

    await tester.pumpWidget(_grid([thisWeek, otherWeek],
        selectedWeek: 1, onOpenDetail: (_) {}, onResolve: (_) {}));
    await tester.pump();

    // ①同格两门 → 必须是 ConflictCell（它内部是 3 秒 Timer 轮播）
    expect(find.byType(ConflictCell), findsOneWidget,
        reason: '同节次两门课（含非本周）应当合成冲突格，而不是各自一张卡');
    expect(find.text('本周的课'), findsOneWidget, reason: '初始显示第一门');

    // ②3 秒后切到另一门 —— 这一条就是用户要的「能切换」
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('非本周的课'), findsOneWidget, reason: '3 秒后应切到非本周那门');

    // 再 3 秒切回
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('本周的课'), findsOneWidget, reason: '再 3 秒应切回第一门');
  });

  testWidgets('点开详情拿到的是当前显示的那门，不是永远第一门', (tester) async {
    final thisWeek = _course(id: 'a', name: '本周的课', weekday: 1, weeks: '1-16周');
    final otherWeek =
        _course(id: 'b', name: '非本周的课', weekday: 1, weeks: '17-20周');

    Course? opened;
    await tester.pumpWidget(_grid([thisWeek, otherWeek],
        selectedWeek: 1, onOpenDetail: (c) => opened = c, onResolve: (_) {}));
    await tester.pump();

    // 切到第二门后再点
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.tap(find.byType(ConflictCell));
    await tester.pump();

    expect(opened, isNotNull, reason: '点击应当回调 onOpenDetail');
    expect(opened!.name, '非本周的课',
        reason: '用户看到的是哪门就该打开哪门 —— 此前恒为 courses.first');
  });

  testWidgets('关掉「显示非本周课程」后，非本周课不进网格', (tester) async {
    CourseStorage.showOtherWeeksCache = false;

    final thisWeek = _course(id: 'a', name: '本周的课', weekday: 1, weeks: '1-16周');
    final otherWeek =
        _course(id: 'b', name: '非本周的课', weekday: 1, weeks: '17-20周');

    await tester.pumpWidget(_grid([thisWeek, otherWeek],
        selectedWeek: 1, onOpenDetail: (_) {}, onResolve: (_) {}));
    await tester.pump();

    expect(find.byType(ConflictCell), findsNothing,
        reason: '开关关着时不该出现冲突格');
    expect(find.text('本周的课'), findsOneWidget);
    expect(find.text('非本周的课'), findsNothing,
        reason: '关掉开关后非本周课必须完全不显示');
  });

  testWidgets('两门都在本周且同节次 → 仍然是冲突格（回归：别把本周课也拆开）',
      (tester) async {
    final a = _course(id: 'a', name: '课甲', weekday: 1, weeks: '1-16周');
    final b = _course(id: 'b', name: '课乙', weekday: 1, weeks: '1-16周');

    await tester.pumpWidget(_grid([a, b],
        selectedWeek: 1, onOpenDetail: (_) {}, onResolve: (_) {}));
    await tester.pump();

    expect(find.byType(ConflictCell), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('课乙'), findsOneWidget);
  });
}
