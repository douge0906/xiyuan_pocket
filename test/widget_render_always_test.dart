import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/models/course_table.dart';
import 'package:xiyuan_pocket/services/widget_sync_service.dart';

/// 「渲染必须在写存储失败时仍然跑」的口径测试（2026-11-04 晚）。
///
/// 背景：桌面上四个小组件**同时**停在 layout XML 的默认文字上，而 App 内
/// 自检一切正常。根因是 `syncTodayCourses()` 原本是一条线性链：
///
/// ```
/// saveWidgetData → updateWidget×3 → renderNow → recordSuccess
/// ```
///
/// 前面任何一步抛异常就跳进 `catch`，**`renderNow()` 根本不会执行** ——
/// 桌面于是永远停在 `initialLayout`：既没有数据，也没有 `onUpdate` 里
/// `setOnClickPendingIntent` 打上去的点击响应（「点又点不了、又不显示数据」
/// 正是这个形状）。而如果 `saveWidgetData` 恰好成功了，自检页还会显示
/// 「数据正常」，进一步把排查引向错误方向。
///
/// 修法是把 `renderNow()` 从 try 体挪到 `finally`。这个文件就是钉住它：
/// **无论存取/广播哪一步炸，渲染都必须被调用一次。**
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> widgetCalls;
  late int renderNowCount;

  /// 让 `saveWidgetData` 抛异常，模拟存储层出问题。
  bool failSave = false;

  /// 让 `updateWidget`（三次广播）抛异常，模拟广播层出问题。
  bool failBroadcast = false;

  setUp(() {
    widgetCalls = <MethodCall>[];
    renderNowCount = 0;
    failSave = false;
    failBroadcast = false;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('home_widget'),
      (MethodCall call) async {
        widgetCalls.add(call);
        if (call.method == 'saveWidgetData') {
          if (failSave) {
            throw PlatformException(code: 'save_failed', message: '写入失败');
          }
          return true;
        }
        if (call.method == 'updateWidget') {
          if (failBroadcast) {
            throw PlatformException(code: 'broadcast_failed', message: '广播失败');
          }
          return true;
        }
        return null;
      },
    );

    // `renderNow()` 走的是另一个通道，单独计数。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('wxxy/widget_status'),
      (MethodCall call) async {
        if (call.method == 'renderNow') {
          renderNowCount++;
          return <String, Object?>{
            'scheduleSmall': 1,
            'scheduleMedium': 0,
            'scheduleLarge': 0,
            'exam': 0,
            'card': 0,
            'countdown': 0,
            'ok': true,
          };
        }
        if (call.method == 'installed') return <String, Object?>{};
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('wxxy/widget_status'), null);
  });

  /// 播一条今天的课，让 `syncTodayCourses` 有东西可推。
  Future<void> seed() async {
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    String ymd(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    final table = CourseTable(
      id: 't1',
      name: '默认课表',
      createdAt: DateTime(2026, 9, 1),
      courses: <Course>[
        Course(
          id: 'c1',
          name: '高等数学',
          teacher: '张老师',
          classroom: 'A301',
          weekday: now.weekday,
          startSlot: 1,
          endSlot: 2,
          weeks: '1-20',
          colorValue: 0xFF4F7CFF,
        ),
      ],
      semesterStart: monday,
      semesterStartSource: CourseTable.srcUser,
    );

    SharedPreferences.setMockInitialValues(<String, Object>{
      'course_tables_v2': jsonEncode(<String, Object>{
        'tables': <Object>[table.toJson()],
        'activeId': 't1',
      }),
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('course_semester_start', ymd(monday));
  }

  test('正常路径：写存储 + 广播 + 渲染各跑一次', () async {
    await seed();
    await WidgetSyncService.syncTodayCourses();

    expect(renderNowCount, 1, reason: '正常路径也必须走同进程直调');
  });

  test('🔴 saveWidgetData 抛异常时，渲染仍然要跑（否则桌面停在默认文字）', () async {
    await seed();
    failSave = true;

    await WidgetSyncService.syncTodayCourses();

    // 异常被 catch 住（不影响 App 使用），但 finally 里的渲染必须执行。
    expect(
      renderNowCount,
      1,
      reason: '存储失败不能连带渲染一起跳过 —— 这正是「自检正常、桌面却空白」的成因',
    );
  });

  test('🔴 updateWidget（广播）抛异常时，渲染仍然要跑', () async {
    await seed();
    failBroadcast = true;

    await WidgetSyncService.syncTodayCourses();

    expect(
      renderNowCount,
      1,
      reason: '广播失败正是我们要绕开的那条路，绝不能因此把同进程渲染也跳过',
    );
  });

  test('🔴 广播失败时渲染甚至要多跑：不能只依赖 onUpdate', () async {
    await seed();
    failBroadcast = true;

    await WidgetSyncService.syncTodayCourses();

    // 这条断言的重点不是次数，而是「广播这条路断了，渲染这条路还在」。
    expect(renderNowCount, greaterThan(0));
  });

  test('syncInfoWidgets 里子任务抛异常时，渲染仍然要跑', () async {
    await seed();
    // 让存储读不到 → syncCountdownWidget 内部 ensureLoaded 之后的解析会失败。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'widget_countdown_data': '这不是合法 JSON {{{',
    });
    failSave = true;

    await WidgetSyncService.syncInfoWidgets();

    expect(
      renderNowCount,
      1,
      reason: 'Future.wait 短路过一次，三个信息组件一起停在默认文字上',
    );
  });
}
