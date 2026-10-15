import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/models/course_model.dart';

/// 课节色块「色彩方案」、课程自动分色（暖色优先）、非本周「淡灰」的回归测试。
///
/// 只测**纯函数**的行为边界 —— 渲染层（CourseCardWidget）读的也是这几个函数，
/// 这里钉死就能防住「以后手一抖把某一档调没了 / 调成一片灰」。
void main() {
  double sat(Color c) => HSLColor.fromColor(c).saturation;
  double light(Color c) => HSLColor.fromColor(c).lightness;
  double hue(Color c) => HSLColor.fromColor(c).hue;

  group('CourseColorScheme 命名（v1.7.1）', () {
    test('三档直接叫方案一 / 方案二 / 方案三', () {
      expect(CourseColorScheme.standard.label, '方案一');
      expect(CourseColorScheme.soft.label, '方案二');
      expect(CourseColorScheme.vivid.label, '方案三');
    });

    test('改名只动 label、不动存储值 —— 老用户已选的方案不会丢', () {
      expect(CourseColorScheme.standard.name, 'standard');
      expect(CourseColorScheme.soft.name, 'soft');
      expect(CourseColorScheme.vivid.name, 'vivid');
    });
  });

  group('courseColorFor', () {
    test('方案一 = 原色，不做任何转换', () {
      for (final v in coursePalette) {
        expect(
          courseColorFor(v, CourseColorScheme.standard).value,
          v,
          reason: '方案一必须原样返回调色板颜色',
        );
      }
    });

    test('方案二（柔彩）：色相不变、饱和度下压但**不发白**', () {
      for (final v in coursePalette) {
        final base = Color(v);
        final soft = courseColorFor(v, CourseColorScheme.soft);
        expect(hue(soft), closeTo(hue(base), 3.0), reason: '色相必须保住');
        expect(sat(soft), lessThanOrEqualTo(sat(base) + 0.001));
        // 🔴 柔彩的命门：饱和度必须有下限。
        //    上一版把饱和度压到 ×0.40 又提亮 12%，色块变成「发白的灰粉 / 灰蓝」，
        //    这就是用户说的「色彩方案不对」。钉住下限 = 再也不会退回去。
        expect(sat(soft), greaterThanOrEqualTo(0.30),
            reason: '柔彩仍必须是一块有颜色的色块，不能洗成灰白');
        expect(light(soft), inInclusiveRange(0.84, 0.94));
      }
    });

    test('方案二 与「非本周淡灰」必须分得开（不能撞脸）', () {
      for (final v in coursePalette) {
        final soft = courseColorFor(v, CourseColorScheme.soft);
        final gray = otherWeekGrayFor(Color(v), 0.75, false);
        expect(sat(soft), greaterThan(0.25), reason: '本周的课必须有颜色');
        expect(sat(gray), closeTo(0, 0.001), reason: '非本周的课必须是灰的');
      }
    });

    test('方案三：饱和度更高、亮度更低，色相保持不变', () {
      for (final v in coursePalette) {
        final base = Color(v);
        final vivid = courseColorFor(v, CourseColorScheme.vivid);
        expect(sat(vivid), greaterThan(sat(base)));
        expect(light(vivid), lessThan(light(base)));
        expect(hue(vivid), closeTo(hue(base), 3.0));
      }
    });

    test('三套方案互不相同（不能出现「换了没反应」）', () {
      for (final v in coursePalette) {
        final a = courseColorFor(v, CourseColorScheme.standard).value;
        final b = courseColorFor(v, CourseColorScheme.soft).value;
        final c = courseColorFor(v, CourseColorScheme.vivid).value;
        expect(a == b, isFalse);
        expect(b == c, isFalse);
        expect(a == c, isFalse);
      }
    });
  });

  group('CourseColorScheme.parse', () {
    test('能解析枚举名，未知值回落方案一', () {
      expect(CourseColorScheme.parse('soft'), CourseColorScheme.soft);
      expect(CourseColorScheme.parse('vivid'), CourseColorScheme.vivid);
      expect(CourseColorScheme.parse('standard'), CourseColorScheme.standard);
      expect(CourseColorScheme.parse(null), CourseColorScheme.standard);
      expect(CourseColorScheme.parse('乱码'), CourseColorScheme.standard);
    });
  });

  group('colorForName 暖色优先（v1.7.1）', () {
    const names = <String>[
      '高等数学', '大学物理', '程序设计基础', '线性代数', '大学英语',
      '数据结构', '计算机网络', '操作系统', '概率论', '体育',
      '形势与政策', '马克思主义基本原理', '数字电路', '模拟电路', '离散数学',
      '编译原理', '软件工程', '人工智能导论', '计算机图形学', '数据库系统',
    ];

    test('分配结果一定来自暖 / 冷两组，且都在调色板里', () {
      for (final n in names) {
        final c = colorForName(n);
        expect(
          courseWarmColors.contains(c) || courseCoolColors.contains(c),
          isTrue,
          reason: '$n 分配到了组外的颜色',
        );
        expect(coursePalette.contains(c), isTrue, reason: '$n 的颜色不在调色板里');
      }
    });

    test('暖色占多数（用户要求：暖色优先）', () {
      final warm =
          names.where((n) => courseWarmColors.contains(colorForName(n))).length;
      final ratio = warm / names.length;
      expect(ratio, greaterThan(0.5), reason: '整张课表要偏暖，暖色应明显过半');
      expect(ratio, lessThan(1.0), reason: '也不能清一色暖 —— 要留对比');
    });

    test('同名稳定：反复取色结果一致（否则每次启动课表都换色）', () {
      for (final n in names) {
        expect(colorForName(n), colorForName(n));
      }
    });

    test('空课程名兜底不崩', () {
      expect(colorForName(''), coursePalette.first);
    });

    test('暖 / 冷两组内部不重复', () {
      expect(courseWarmColors.toSet().length, courseWarmColors.length);
      expect(courseCoolColors.toSet().length, courseCoolColors.length);
    });
  });

  group('otherWeekGrayFor', () {
    test('结果一定是纯灰（饱和度归零）', () {
      for (final v in coursePalette) {
        for (final dim in [0.45, 0.65, 0.85]) {
          final g = otherWeekGrayFor(Color(v), dim, false);
          expect(sat(g), closeTo(0, 0.001), reason: '非本周课程必须是灰色');
          final gd = otherWeekGrayFor(Color(v), dim, true);
          expect(sat(gd), closeTo(0, 0.001));
        }
      }
    });

    test('保留原色明暗差异：原色越深的课，灰也越深', () {
      // 从调色板里挑一个"深"的和一个"浅"的
      final deep = coursePalette.reduce(
          (a, b) => light(Color(a)) < light(Color(b)) ? a : b);
      final pale = coursePalette.reduce(
          (a, b) => light(Color(a)) > light(Color(b)) ? a : b);
      const dim = 0.65;
      expect(
        light(otherWeekGrayFor(Color(deep), dim, false)),
        lessThan(light(otherWeekGrayFor(Color(pale), dim, false))),
      );
      // 深色模式下方向一致（越深越暗）
      expect(
        light(otherWeekGrayFor(Color(deep), dim, true)),
        lessThan(light(otherWeekGrayFor(Color(pale), dim, true))),
      );
    });

    test('滑杆越大越淡：浅色模式更浅、深色模式更暗', () {
      final c = Color(coursePalette[3]);
      expect(
        light(otherWeekGrayFor(c, 0.85, false)),
        greaterThan(light(otherWeekGrayFor(c, 0.45, false))),
      );
      expect(
        light(otherWeekGrayFor(c, 0.85, true)),
        lessThan(light(otherWeekGrayFor(c, 0.45, true))),
      );
    });

    test('两种模式的灰分别落在浅色 / 深色区间', () {
      for (final v in coursePalette) {
        expect(light(otherWeekGrayFor(Color(v), 0.75, false)),
            greaterThan(0.6));
        expect(light(otherWeekGrayFor(Color(v), 0.75, true)), lessThan(0.5));
      }
    });
  });
}
