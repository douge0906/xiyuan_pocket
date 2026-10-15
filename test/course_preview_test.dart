import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/services/course_storage.dart';
import 'package:xiyuan_pocket/widgets/course_style_preview.dart';

/// 课表预览「随设置实时重绘」回归测试（2026-10-13）。
///
/// 背景：设置页第一版把预览写成 `const CourseStylePreview()`，const 实例在
/// 父级 setState 时会被 identical 短路跳过（updateChild 直接 return）→
/// 用户反馈「修改后不变」。这个测试钉住行为：**缓存一变 + 父级重建，
/// 预览必须按新值重绘**（调滑杆时就是这条链路）。
void main() {
  tearDown(() => CourseStorage.blockRadiusCache = 6);

  testWidgets('缓存变更 + 父级重建后，预览按新值重绘', (tester) async {
    CourseStorage.blockRadiusCache = 6;

    late StateSetter rebuild;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return ListView(children: [
              // 与设置页保持同一用法：**不能加 const**（参数是运行时值）
              CourseStylePreview(
                courses: [
                  Course(
                    id: 'pv_x1',
                    name: '测试课',
                    weekday: 1,
                    startSlot: 1,
                    endSlot: 1,
                    weeks: '1-16周',
                    colorValue: 0xFFD2E5F8,
                  ),
                ],
                week: 1,
                monday: DateTime(2026, 9, 7),
                todayWeekday: 3,
              ),
            ]);
          },
        ),
      ),
    ));

    bool hasCardRadius(double r) {
      final target = BorderRadius.circular(r);
      return tester.widgetList<Container>(find.byType(Container)).any((c) {
        final d = c.decoration;
        return d is BoxDecoration && d.borderRadius == target;
      });
    }

    expect(hasCardRadius(6), isTrue, reason: '初始应按缓存值 6 渲染卡片圆角');

    // 模拟拖滑杆：先改缓存（_liveSlider 做的事），再触发重建（setState）
    CourseStorage.blockRadiusCache = 24;
    rebuild(() {});
    await tester.pump();

    expect(hasCardRadius(24), isTrue,
        reason: '父级重建后必须按新值 24 重绘（const 短路回归）');
    expect(hasCardRadius(6), isFalse, reason: '旧圆角不应再存在');
  });
}
