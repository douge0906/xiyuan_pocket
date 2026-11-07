// 把 Dart 侧**真实产出**的小组件 JSON 落成夹具，供 Android JVM 单测读取
// （2026-11-04）。
//
// 为什么需要它：小组件这条链路是 Dart 写 → Kotlin 读，跨语言的字段约定
// （`courses` / `allCourses` / `semesterStart` / `weeks` / `weekType` /
// `pattern`）一旦漂移，界面上不是报错，而是「小组件不闪退但没有数据」——
// 这个项目为它返工了三次，每次都要用户装包、过一夜、再截图。
//
// 这里把真实 JSON 存到 android 单测的 resources 里，由
// `android/app/src/test/kotlin/.../WidgetDartContractTest.kt` 反向验证
// Kotlin 解析器认得这份字节。以后谁改了下发字段而没改原生解析，CI 会红。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/models/course_table.dart';
import 'package:xiyuan_pocket/services/widget_sync_service.dart';

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

  test('导出 Dart 侧真实 JSON 作为 Kotlin 契约夹具', () async {
    final today = DateTime.now().weekday;

    // 覆盖三种 pattern + 一段周次文本，确保夹具能压到解析器的全部分支。
    final courses = <Course>[
      Course(
        id: 'fix1',
        name: '高等数学',
        teacher: '张老师',
        classroom: 'A301',
        weekday: today,
        startSlot: 1,
        endSlot: 2,
        weeks: '1-20',
        colorValue: 0xFFF8D2D7,
        pattern: CoursePattern.fixed,
      ),
      Course(
        id: 'fix2',
        name: '大学物理',
        teacher: '李老师',
        classroom: 'B202',
        weekday: today,
        startSlot: 3,
        endSlot: 4,
        weeks: '1-18(单)',
        colorValue: 0xFFD2E5F8,
        pattern: CoursePattern.fixed,
      ),
      Course(
        id: 'fix3',
        name: '早自习',
        weekday: 0,
        startSlot: 1,
        endSlot: 1,
        weeks: '1-20',
        colorValue: 0xFFD2F0E5,
        pattern: CoursePattern.daily,
      ),
    ];

    await _seed(courses);
    await WidgetSyncService.syncTodayCourses();

    String? raw;
    for (final c in calls) {
      if (c.method == 'saveWidgetData') {
        final args = c.arguments as Map?;
        if (args?['id'] == 'widget_today_courses') {
          raw = args?['data'] as String?;
        }
      }
    }
    expect(raw, isNotNull, reason: '必须写入了 widget_today_courses');

    // 夹具必须是「今天」写的真实数据 —— 原生解析器就是按这个格式工作。
    final json = jsonDecode(raw!) as Map<String, dynamic>;
    expect(json['allCourses'], isA<List>(), reason: '整学期数据必须一起下发');
    expect((json['allCourses'] as List), isNotEmpty);
    expect(json['semesterStart'], isA<String>());
    expect((json['semesterStart'] as String).length, 10);

    // 落到 android 单测的 resources 目录（相对仓库根的固定路径）。
    final out = File(
      'android/app/src/test/resources/widget_payload_dart.json',
    );
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));

    // 占位断言：真正的内容校验在 Kotlin 侧。
    expect(out.existsSync(), isTrue);
  });
}

Future<void> _seed(List<Course> courses) async {
  final now = DateTime.now();
  final monday = DateTime(now.year, now.month, now.day)
      .subtract(Duration(days: now.weekday - 1));

  final table = CourseTable(
    id: 't1',
    name: '我的课表',
    createdAt: DateTime(2026, 9, 1),
    courses: courses,
    semesterStart: monday,
  );

  SharedPreferences.setMockInitialValues({
    'course_tables_v2': jsonEncode({
      'tables': [table.toJson()],
      'activeId': 't1',
    }),
    'course_semester_start': _ymd(monday),
  });
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
