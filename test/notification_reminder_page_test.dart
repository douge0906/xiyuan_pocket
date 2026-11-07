import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/pages/notification_reminder_page.dart';
import 'package:xiyuan_pocket/services/storage_service.dart';

/// 通知与提醒合并页（v1.0.9 用户需求 #9：两页合并 · 盒子等高 · 去小字）。
///
/// 锁四件事：
///  1. 两组标题都在（提醒 / 后台与权限），不会因为某个
///     async 查询失败就整页空；「课堂勿扰」分组已按 m01524 #4 删除，
///     同时不再出现（回归锁）。
///  2. **每一行都是 56 高**（用户明确要求「盒子大小高度相同」）——
///     这条最容易在后续加行时被破坏，所以必须用测试钉住；
///  3. 旧两页的分区名不再出现（合并后只剩一套）；
///  4. 提前时间选择器能落盘、自启动手勾能落盘。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 这一页在 `initState` 里要读 12 项系统/插件状态，其中若干走 MethodChannel。
  /// widget test 默认跑在 fake-async 区，真实异步不会自己推进 —— 所以每轮
  /// `pump` 之间用 `runAsync` 让真实 Future 落地，再 `pump` 一帧看结果。
  /// （不能用 `pumpAndSettle`：加载时的 CircularProgressIndicator 是无限动画，
  ///  它永远不会 settle，会直接超时。）
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(home: NotificationReminderPage()),
    );
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
      if (find.text('后台与权限').evaluate().isNotEmpty) return;
    }
    fail('页面在 400ms 内没有结束加载：_refresh 里有一项读不回来');
  }

  testWidgets('两组标题都在，「课堂勿扰」已移除', (tester) async {
    await pumpPage(tester);
    expect(find.text('提醒'), findsOneWidget);
    expect(find.text('后台与权限'), findsOneWidget);
    // 2026-11-07：分组小标题由「上课提醒」改为「提醒」，且「开启待办提醒」
    // 开关移到本组、紧随「开启课程提醒」下方。
    expect(find.text('上课提醒'), findsNothing);
    expect(find.text('开启待办提醒'), findsOneWidget);
    expect(find.text('开启课程提醒'), findsOneWidget);
    // 2026-11-06（用户 m01524 #4）：课堂勿扰分组、通知悬挂倒计时、
    // 勿扰模式访问权三项都按用户要求删掉了，不能再回来。
    expect(find.text('课堂勿扰'), findsNothing);
    expect(find.text('通知悬挂倒计时'), findsNothing);
    expect(find.text('勿扰模式访问权'), findsNothing);
    // 取而代之的是「通知振动」引导（用户原话：不知道可以打开振动权限）。
    expect(find.text('通知振动'), findsOneWidget);
    // 旧两页的分区名/标题不应该再出现（合并后只剩一套）。
    expect(find.text('必需项 · 可自动检测'), findsNothing);
    expect(find.text('需手动确认'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('每一行都是 56 高', (tester) async {
    await pumpPage(tester);
    final rows = find.byWidgetPredicate(
      (w) => w is SizedBox && w.height == 56.0,
    );
    // 提醒 4 行（课程 / 待办 / 提前时间 / 通知岛）+ 后台与权限 6 行 = 10
    expect(rows, findsNWidgets(10));
  });

  testWidgets('没有副标题小字，状态只用右侧一段文字', (tester) async {
    await pumpPage(tester);
    // 旧页的长副标题（来自 locale 的 notif_perm_desc）不应再出现。
    expect(find.textContaining('Android 13 及以上'), findsNothing);
    expect(find.textContaining('国产系统'), findsNothing);
    // 状态以短词呈现
    expect(find.text('已授权'), findsWidgets);
  });

  testWidgets('点「提前提醒时间」弹出选择器，选 15 分钟后落盘', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('提前提醒时间'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('提前多久提醒'), findsOneWidget);

    await tester.tap(find.text('15 分钟'));
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 60)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('course_reminder_lead_minutes'), 15);
  });

  testWidgets('自启动项的手勾会落盘', (tester) async {
    await pumpPage(tester);
    expect(await StorageService.loadNotifChecked(), isEmpty);

    final box = find.byIcon(Icons.check_box_outline_blank_rounded);
    expect(box, findsOneWidget);
    await tester.tap(box);
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 60)));
    await tester.pump();

    final saved = await StorageService.loadNotifChecked();
    expect(saved, contains('autostart'));
    expect(find.byIcon(Icons.check_box_rounded), findsOneWidget);
  });

  testWidgets('两个操作按钮都在', (tester) async {
    await pumpPage(tester);
    expect(find.text('发送测试提醒'), findsOneWidget);
    expect(find.text('重新排程全部提醒'), findsOneWidget);
  });
}
