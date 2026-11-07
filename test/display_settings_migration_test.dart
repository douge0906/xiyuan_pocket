import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/services/course_storage.dart';

/// 2026-11-04（用户 m20128 #2）回归：
///
/// 用户原话「显示网格线无法生效，开关自动驳回。显示非本周课程失效，
/// 无法预览且无法生效。课表背景图无法添加生效。」
///
/// 根因：`loadDisplaySettings()` 里的「默认方案二」迁移**没有一次性标记**，
/// 每次读取都把 `softSchemePatch()` 再套一遍，而它带着
/// `showGridLines: false` / `backgroundImage: ''` / `otherWeeksDim` ——
/// 于是用户改完设置，下次进设置页又被驳回。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('默认方案二迁移只做一次：网格线开关不会被反复驳回', () async {
    SharedPreferences.setMockInitialValues({});
    // 第一次读：触发迁移
    final first = await CourseStorage.loadDisplaySettings();
    expect(first['_schemeDefaultSoft'], isTrue, reason: '迁移必须打上标记');

    // 用户打开网格线并保存
    final on = <String, dynamic>{...first, 'showGridLines': true};
    await CourseStorage.saveDisplaySettings(on);

    // 再读：不能被迁移驳回
    final again = await CourseStorage.loadDisplaySettings();
    expect(again['showGridLines'], isTrue,
        reason: '用户开了网格线，重新读设置不能又被关掉');
  });

  test('显示非本周课程：改动不会被反复驳回', () async {
    SharedPreferences.setMockInitialValues({});
    final first = await CourseStorage.loadDisplaySettings();
    await CourseStorage.saveDisplaySettings(
        <String, dynamic>{...first, 'showOtherWeeks': true});

    final again = await CourseStorage.loadDisplaySettings();
    expect(again['showOtherWeeks'], isTrue);

    // 关掉也要能保持（不是单向强制 true）
    await CourseStorage.saveDisplaySettings(
        <String, dynamic>{...again, 'showOtherWeeks': false});
    final third = await CourseStorage.loadDisplaySettings();
    expect(third['showOtherWeeks'], isFalse);
  });

  test('课表背景图：路径不会被迁移清空', () async {
    SharedPreferences.setMockInitialValues({});
    final first = await CourseStorage.loadDisplaySettings();
    const path = '/data/user/0/icu.wxxydouge.wxxy_pocket/app_flutter/course_background.png';
    await CourseStorage.saveDisplaySettings(
        <String, dynamic>{...first, 'backgroundImage': path});

    final again = await CourseStorage.loadDisplaySettings();
    expect(again['backgroundImage'], path, reason: '背景图路径不能被 softSchemePatch 清空');
  });

  test('首次迁移的淡蓝背景色是提高过饱和度的值', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await CourseStorage.loadDisplaySettings();
    // 0xFFC6DDF7 = 饱和度 20% 的淡蓝（用户 m20455 #2 指定）。
    expect(s['backgroundColor'], 0xFFC6DDF7);
  });

  test('用户自己选过方案（schemeUserPicked）后不再被迁移覆盖', () async {
    SharedPreferences.setMockInitialValues({});
    final first = await CourseStorage.loadDisplaySettings();
    await CourseStorage.saveDisplaySettings(<String, dynamic>{
      ...first,
      'scheme': 'vivid',
      'schemeUserPicked': true,
      'showGridLines': false,
    });

    final again = await CourseStorage.loadDisplaySettings();
    expect(again['scheme'], 'vivid');
    expect(again['showGridLines'], isFalse);
  });

  test('损坏的存储不抛异常，回落默认值', () async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{'course_display_settings_v1': '{不是 JSON'});
    final s = await CourseStorage.loadDisplaySettings();
    expect(s, isA<Map<String, dynamic>>());
    expect(jsonEncode(s), isNotEmpty);
  });
}
