import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/services/course_storage.dart';

/// 「冲突组签名」回归（2026-10-16）。
///
/// 进课表页的自动冲突提醒靠这个签名去重：用户处理过的冲突组不再重复弹
/// （修「重新进入课表页面又会触发冲突提醒」）。签名必须**与组内顺序无关**，
/// 且不同的课要分得开 —— 否则要么漏提醒、要么永远提醒。
void main() {
  Course c(String name, int wd, int s, int e) => Course(
        id: 't_${name}_$wd-$s',
        name: name,
        teacher: '张老师',
        classroom: 'C1-112',
        weekday: wd,
        startSlot: s,
        endSlot: e,
        weeks: '1-16',
        colorValue: 0xFFD2E5F8,
        source: CourseSource.server,
      );

  group('CourseStorage.conflictGroupKey', () {
    test('与组内顺序无关（同一组冲突无论先后，签名一致）', () {
      final a = c('高等数学', 1, 1, 2);
      final b = c('大学英语', 1, 1, 2);
      expect(CourseStorage.conflictGroupKey(<Course>[a, b]),
          CourseStorage.conflictGroupKey(<Course>[b, a]));
    });

    test('课名 / 星期 / 节次任一不同 → 签名就不同（不会把别的冲突误判成已处理）', () {
      final base = c('高等数学', 1, 1, 2);
      final ref =
          CourseStorage.conflictGroupKey(<Course>[base, c('大学英语', 1, 1, 2)]);
      expect(ref, isNot(CourseStorage.conflictGroupKey(<Course>[base, c('大学物理', 1, 1, 2)])));
      expect(ref, isNot(CourseStorage.conflictGroupKey(<Course>[base, c('大学英语', 2, 1, 2)])));
      expect(ref, isNot(CourseStorage.conflictGroupKey(<Course>[base, c('大学英语', 1, 3, 4)])));
    });

    test('稳定：同一组课反复算结果一致', () {
      final g = <Course>[c('A', 1, 1, 2), c('B', 1, 2, 3)];
      expect(CourseStorage.conflictGroupKey(g),
          CourseStorage.conflictGroupKey(List<Course>.of(g)));
    });
  });
}
