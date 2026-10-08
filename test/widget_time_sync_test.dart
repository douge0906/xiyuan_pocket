import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/services/course_storage.dart';

/// 「改上课时间 → 小组件跟着变」的端到端验证（任务一）。
///
/// 同学反馈「课表时间和小组件不同步」有两个来源：一个是 timeText 算错
/// （见 widget_sync_test.dart），另一个是**改完上课时间根本没通知小组件** ——
/// `CourseStorage.saveCourses()` 结尾有 `unawaited(syncTodayCourses())`，
/// 但 `saveTimeBlocks()` 当初漏抄了这一句。
///
/// 这个文件不看代码、只**拦 home_widget 的平台通道**，检查实际推给原生侧的
/// JSON 内容 —— 也就是「小组件真正会收到什么」。
/// 把 `saveTimeBlocks` 里那句同步删掉，本文件必须变红。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('home_widget'),
            (call) async {
      calls.add(call);
      return call.method == 'saveWidgetData' ? true : null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
  });

  /// 捞最近一次推给小组件的「今日课程」JSON。
  Map<String, dynamic>? lastPushed() {
    for (final c in calls.reversed) {
      if (c.method != 'saveWidgetData') continue;
      final args = c.arguments;
      if (args is! Map) continue;
      // home_widget 0.4.1 的参数键是 id / data（不是 key / value）
      if (args['id'] != 'widget_today_courses') continue;
      final value = args['data'];
      if (value is! String) continue;
      return jsonDecode(value) as Map<String, dynamic>;
    }
    return null;
  }

  /// 每天都有、不挑周的课 —— 保证「今天」一定命中。
  Course dailyCourse(int start, int end) => Course(
        id: 'c_$start',
        name: '测试课',
        teacher: '张老师',
        classroom: 'A101',
        weekday: 1,
        startSlot: start,
        endSlot: end,
        colorValue: 0xFFD2E5F8,
        source: CourseSource.manual,
        pattern: CoursePattern.daily,
      );

  test('🔴 改上课时间后，推给小组件的时刻确实换成了新值', () async {
    await CourseStorage.saveCourses([dailyCourse(1, 2)]);
    await pumpEventQueue();

    // 先用默认时间看一次基线
    final before = lastPushed();
    expect(before, isNotNull, reason: 'saveCourses 之后本来就该推一次小组件');
    expect((before!['courses'] as List).first['timeText'], '08:00-09:40');

    // 记下当前推了几次，后面只认「新增的那次」
    final mark = calls.length;

    // 👉 只调 saveTimeBlocks —— 不碰课程数据
    await CourseStorage.saveTimeBlocks(const [
      {'label': '1', 'period': 0, 'start': 1, 'end': 1, 'time': '08:10\n08:55'},
      {'label': '2', 'period': 0, 'start': 2, 'end': 2, 'time': '09:05\n09:50'},
    ]);
    await pumpEventQueue();

    final after = lastPushed();
    expect(after, isNotNull, reason: '改完上课时间必须重推小组件，否则小组件停在旧时间');
    expect(calls.length, greaterThan(mark),
        reason: 'saveTimeBlocks 没有产生任何对小组件的调用 —— 这就是「不同步」的来源');

    final item = (after!['courses'] as List).first as Map<String, dynamic>;
    expect(item['timeText'], '08:10-09:50', reason: '小组件上显示的时刻没跟着改');
    // 原生「下一节课」的切换用的也是这两个数，必须一起换
    expect(item['startMinute'], 8 * 60 + 10);
    expect(item['endMinute'], 9 * 60 + 50);
  });

  test('改完时间也会广播重绘（updateWidget），不是只写存储', () async {
    await CourseStorage.saveCourses([dailyCourse(1, 2)]);
    await pumpEventQueue();
    final mark = calls.length;

    await CourseStorage.saveTimeBlocks(const [
      {'label': '1', 'period': 0, 'start': 1, 'end': 1, 'time': '07:30\n08:15'},
      {'label': '2', 'period': 0, 'start': 2, 'end': 2, 'time': '08:25\n09:10'},
    ]);
    await pumpEventQueue();

    final updates = calls
        .skip(mark)
        .where((c) => c.method == 'updateWidget')
        .toList();
    expect(updates, isNotEmpty, reason: '光写数据不广播，桌面上的小组件不会自己重绘');
    // 三个尺寸都要通知到
    final names = updates
        .map((c) => (c.arguments as Map)['qualifiedAndroidName'])
        .toSet();
    expect(names, contains('icu.wxxydouge.wxxy_pocket.widget.SmallWidgetProvider'));
    expect(names, contains('icu.wxxydouge.wxxy_pocket.widget.MediumWidgetProvider'));
    expect(names, contains('icu.wxxydouge.wxxy_pocket.widget.LargeWidgetProvider'));
  });

  test('改开学日后也重推（教学周决定今天上哪几门）', () async {
    await CourseStorage.saveCourses([dailyCourse(9, 11)]);
    await pumpEventQueue();

    final mark = calls.length;
    await CourseStorage.saveSemesterStart(DateTime(2026, 9, 7));
    await pumpEventQueue();

    expect(calls.length, greaterThan(mark),
        reason: 'saveSemesterStart 也必须重推小组件（第 N 周标签 + 单双周取舍都靠它）');
    final pushed = lastPushed();
    expect(pushed, isNotNull);
    expect(pushed!['semesterWeek'], isA<int>());
  });
}
