import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/models/course_table.dart';
import 'package:xiyuan_pocket/services/widget_sync_service.dart';

/// 「小组件取不到数据」的端到端口径测试（2026-11-03）。
///
/// 背景：用户反馈小组件上什么都没有 / 一直显示旧的。之前的测试全部集中在
/// `timeTextFor` 这类**纯函数**上，从没有人验证过「写入 home_widget 的那段
/// JSON 到底长什么样」—— 而原生 `WidgetDataStore.read()` 只要
/// `optJSONArray("courses")` 拿到 null 就直接 `return null`，
/// 于是 `buildSmall` 走「今日无课」分支。也就是说：**只要 JSON 结构与
/// 原生解析对不上，界面上就是「没数据」，而不是报错**。
///
/// 这个文件用真实的 [WidgetSyncService.syncTodayCourses] 跑一遍，
/// 拦截 `home_widget` 的 MethodChannel，把真正写进去的字符串捞出来逐字段断言。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('home_widget'),
      (MethodCall call) async {
        calls.add(call);
        // 插件在 saveWidgetData 上返回 prefs.commit() 的布尔值。
        if (call.method == 'saveWidgetData') return true;
        if (call.method == 'updateWidget') return true;
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('home_widget'), null);
  });

  /// 从拦截到的调用里取出写入 `widget_today_courses` 的 JSON 字符串。
  String? payload() {
    for (final c in calls) {
      if (c.method == 'saveWidgetData') {
        final args = c.arguments as Map?;
        if (args?['id'] == 'widget_today_courses') {
          return args?['data'] as String?;
        }
      }
    }
    return null;
  }

  test('今天有课时，写出的 JSON 必须带非空 courses 且字段齐全', () async {
    final today = DateTime.now().weekday; // 1..7
    final course = Course(
      id: 'c1',
      name: '高等数学',
      teacher: '张老师',
      classroom: 'A301',
      weekday: today,
      startSlot: 1,
      endSlot: 2,
      weeks: '1-20',
      colorValue: 0xFFF8D2D7,
      pattern: CoursePattern.fixed,
    );
    await _seed([course]);

    await WidgetSyncService.syncTodayCourses();

    final raw = payload();
    expect(raw, isNotNull, reason: '必须调用过 saveWidgetData(widget_today_courses)');

    final json = jsonDecode(raw!) as Map<String, dynamic>;

    // ① 原生 WidgetDataStore.read() 靠这几个键决定「有没有数据」。
    expect(json['date'], isA<String>());
    expect(json['weekday'], today);
    expect(json['hasSchedule'], isTrue);
    expect(json['courses'], isA<List>());

    final courses = json['courses'] as List;
    expect(courses, isNotEmpty, reason: '今天有课，写入的 courses 不能是空数组');
    expect(courses.length, 1);

    // ② 原生逐字段 optInt/optString 解析出的每一列都要有值。
    final c = courses.first as Map<String, dynamic>;
    expect(c['name'], '高等数学');
    expect(c['classroom'], 'A301');
    expect(c['startSlot'], 1);
    expect(c['endSlot'], 2);
    expect(c['startMinute'], 8 * 60, reason: '1 节 08:00 起，共 480 分钟');
    expect(c['endMinute'], 9 * 60 + 40, reason: '2 节到 09:40，共 580 分钟');
    expect(c['timeText'], '08:00-09:40');
    expect(c['color'], isA<int>());
  });

  test('课程不在本周时 courses 为空但 hasSchedule=false（原生走「今日无课」）',
      () async {
    final today = DateTime.now().weekday;
    final course = Course(
      id: 'c2',
      name: '线性代数',
      weekday: today,
      startSlot: 3,
      endSlot: 4,
      // 只排第 25 周，正常学期到不了。
      weeks: '25',
      colorValue: 0xFFD2E5F8,
      pattern: CoursePattern.fixed,
    );
    await _seed([course]);

    await WidgetSyncService.syncTodayCourses();

    final raw = payload();
    expect(raw, isNotNull);
    final json = jsonDecode(raw!) as Map<String, dynamic>;
    expect(json['courses'], isEmpty);
    expect(json['hasSchedule'], isFalse);
  });

  test('写入之后必须通知到三个课表 Provider，否则界面不会重绘', () async {
    final today = DateTime.now().weekday;
    await _seed([
      Course(
        id: 'c3',
        name: '大学英语',
        weekday: today,
        startSlot: 5,
        endSlot: 6,
        weeks: '1-20',
        colorValue: 0xFFD2F0E5,
        pattern: CoursePattern.fixed,
      ),
    ]);

    await WidgetSyncService.syncTodayCourses();

    final updated = calls
        .where((c) => c.method == 'updateWidget')
        .map((c) => (c.arguments as Map?)?['qualifiedAndroidName'])
        .toList();
    expect(updated,
        contains('icu.wxxydouge.wxxy_pocket.widget.SmallWidgetProvider'));
    expect(updated,
        contains('icu.wxxydouge.wxxy_pocket.widget.MediumWidgetProvider'));
    expect(updated,
        contains('icu.wxxydouge.wxxy_pocket.widget.LargeWidgetProvider'));
  });
}

/// 把一份课表直接写进 SharedPreferences（绕过 UI）。
///
/// 开学日取「本周一」→ 今天必然是第 1 周，配合 `weeks: '1-20'` 能稳定命中。
Future<void> _seed(List<Course> courses, {DateTime? semesterStart}) async {
  final start = semesterStart ?? _mondayOfToday();
  final table = CourseTable(
    id: 't1',
    name: '我的课表',
    createdAt: DateTime(2026, 9, 1),
    courses: courses,
    semesterStart: start,
    semesterStartSource: CourseTable.srcUser,
  );
  SharedPreferences.setMockInitialValues(<String, Object>{
    _kTables: jsonEncode({
      'tables': [table.toJson()],
      'activeId': 't1',
    }),
  });
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kSemesterStart, _ymd(start));
}

DateTime _mondayOfToday() {
  final now = DateTime.now();
  final d = DateTime(now.year, now.month, now.day);
  return d.subtract(Duration(days: d.weekday - 1));
}

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// `CourseStorage` 的存储键是私有的，测试里只能用字面量。
const String _kTables = 'course_tables_v2';
const String _kSemesterStart = 'course_semester_start';
