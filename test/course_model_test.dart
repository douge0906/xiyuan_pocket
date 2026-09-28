import 'package:flutter_test/flutter_test.dart';

import '../lib/models/course_model.dart';

/// 课表核心判定测试（v2.3.7）。
/// 背景：v2.3.1 把「某天有没有这节课」的判定从三处拷贝收敛为 Course.occursOn，
/// 这里覆盖固定/每天/工作日三种模式 + 单双周 + 周次范围 + 边界，保证收敛等价。
Course _c({
  int weekday = 1,
  String weeks = '1-16周',
  CourseWeekType weekType = CourseWeekType.every,
  CoursePattern pattern = CoursePattern.fixed,
}) =>
    Course(
      id: 't',
      name: '测试课',
      weekday: weekday,
      startSlot: 1,
      endSlot: 2,
      weeks: weeks,
      colorValue: 0xFF000000,
      weekType: weekType,
      pattern: pattern,
    );

void main() {
  group('Course.occursOn 固定周几', () {
    test('周一课程：仅周一命中', () {
      final c = _c(weekday: 1);
      expect(c.occursOn(1, 3), isTrue);
      expect(c.occursOn(2, 3), isFalse);
      expect(c.occursOn(7, 3), isFalse);
    });

    test('周日课程：仅周日命中', () {
      final c = _c(weekday: 7);
      expect(c.occursOn(7, 3), isTrue);
      expect(c.occursOn(6, 3), isFalse);
    });
  });

  group('Course.occursOn 每天 / 工作日', () {
    test('每天：一周七天都命中', () {
      final c = _c(pattern: CoursePattern.daily);
      for (var d = 1; d <= 7; d++) {
        expect(c.occursOn(d, 3), isTrue, reason: '周$d 应命中');
      }
    });

    test('工作日：仅周一到周五命中', () {
      final c = _c(pattern: CoursePattern.workday);
      for (var d = 1; d <= 5; d++) {
        expect(c.occursOn(d, 3), isTrue, reason: '周$d 应命中');
      }
      expect(c.occursOn(6, 3), isFalse);
      expect(c.occursOn(7, 3), isFalse);
    });
  });

  group('Course.occursOn 周次过滤', () {
    test('周次范围外不命中（1-7 周课程第 8 周不上课）', () {
      final c = _c(weeks: '1-7周');
      expect(c.occursOn(1, 7), isTrue);
      expect(c.occursOn(1, 8), isFalse);
    });

    test('单周：偶数周不命中', () {
      final c = _c(weeks: '1-15周(单)', weekType: CourseWeekType.odd);
      expect(c.occursOn(1, 1), isTrue);
      expect(c.occursOn(1, 3), isTrue);
      expect(c.occursOn(1, 2), isFalse, reason: '双周不该上课');
      expect(c.occursOn(1, 4), isFalse);
    });

    test('双周：奇数周不命中', () {
      final c = _c(weeks: '2-16周(双)', weekType: CourseWeekType.even);
      expect(c.occursOn(1, 2), isTrue);
      expect(c.occursOn(1, 4), isTrue);
      expect(c.occursOn(1, 1), isFalse);
    });

    test('开学前（第 0 周及负数）不命中', () {
      final c = _c();
      expect(c.occursOn(1, 0), isFalse);
      expect(c.occursOn(1, -1), isFalse);
    });
  });

  group('isActiveOnWeek 与 occursOn 一致性', () {
    test('occursOn = isActiveOnWeek ∩ 星期匹配', () {
      final c = _c(weekday: 3, weeks: '3-16周');
      for (var week = 1; week <= 20; week++) {
        final expectMatch = c.isActiveOnWeek(week) && week >= 3;
        expect(c.occursOn(3, week), expectMatch, reason: '第$week周');
      }
    });
  });
}
