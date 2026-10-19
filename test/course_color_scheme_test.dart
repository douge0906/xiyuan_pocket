import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/services/course_storage.dart';

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
    test('方案一：色相不变、在调色板上**轻微加深**（2026-10-16 用户：「颜色变深一点」）', () {
      for (final v in coursePalette) {
        final base = Color(v);
        final std = courseColorFor(v, CourseColorScheme.standard);
        expect(hue(std), closeTo(hue(base), 3.0), reason: '色相必须保住');
        expect(light(std), lessThan(light(base)), reason: '方案一要比原色深一点');
        expect(sat(std), greaterThanOrEqualTo(sat(base) - 0.001));
        // 幅度必须**小于**方案二 / 三，否则三档分不出层次
        expect(light(std),
            greaterThan(light(courseColorFor(v, CourseColorScheme.soft))),
            reason: '方案一应比方案二浅');
        expect(light(std),
            greaterThan(light(courseColorFor(v, CourseColorScheme.vivid))),
            reason: '方案一应比方案三浅');
      }
    });

    test('方案二：色相不变、提饱和 + 压明度（2026-10-16 复刻参考图 1）', () {
      for (final v in coursePalette) {
        final base = Color(v);
        final soft = courseColorFor(v, CourseColorScheme.soft);
        expect(hue(soft), closeTo(hue(base), 3.0), reason: '色相必须保住');
        expect(sat(soft), greaterThan(sat(base)), reason: '方案二要更有颜色');
        expect(light(soft), lessThan(light(base)), reason: '方案二明度略降');
        // 🔴 命门：无论是哪一档，都不能洗成灰白 —— 灰白是「非本周课程」的样子。
        expect(sat(soft), greaterThan(0.5),
            reason: '本周的课必须是一块明确的彩色色块，不能洗成灰白');
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

  group('SchemePreset 整套外观预设（2026-10-16）', () {
    test('方案一 = 出厂默认（不会把用户手调带跑）', () {
      final a = SchemePreset.of(CourseColorScheme.standard);
      final d = CourseStorage.defaultDisplaySettings();
      expect(a.blockRadius, d['blockRadius']);
      expect(a.blockPad, d['blockPad']);
      expect(a.blockMargin, d['blockMargin']);
      expect(a.blockBorderWidth, d['blockBorderWidth']);
      expect(a.rowHeight, d['rowHeight']);
    });

    test('方案二 / 三 必须真的改了外观（否则「换方案」等于没换）', () {
      final a = SchemePreset.of(CourseColorScheme.standard);
      for (final s in [CourseColorScheme.soft, CourseColorScheme.vivid]) {
        final p = SchemePreset.of(s);
        expect(p.blockRadius, isNot(a.blockRadius), reason: '${s.label} 圆角没变');
        expect(p.rowHeight, isNot(a.rowHeight), reason: '${s.label} 课节高度没变');
      }
    });

    test('圆角方向复刻参考图：图1（方案二）圆、图2（方案三）方', () {
      final b = SchemePreset.of(CourseColorScheme.soft);
      final c = SchemePreset.of(CourseColorScheme.vivid);
      expect(b.blockRadius, greaterThan(c.blockRadius),
          reason: '方案二（图1）圆角应明显大于方案三（图2）');
      expect(c.blockMargin, lessThan(b.blockMargin),
          reason: '方案三（图2）的色块几乎贴满列宽');
    });

    test('补丁写进显示设置后真的被采纳（不能写了不生效）', () {
      final p = SchemePreset.of(CourseColorScheme.soft);
      final s = <String, dynamic>{
        ...CourseStorage.defaultDisplaySettings(),
        ...p.toDisplayPatch(),
      };
      CourseStorage.applyDisplayToCache(s);
      expect(CourseStorage.blockRadiusCache, p.blockRadius);
      expect(CourseStorage.rowHeightCache, p.rowHeight);
      expect(CourseStorage.blockBorderWidthCache, p.blockBorderWidth);
      expect(CourseStorage.blockMarginCache, closeTo(p.blockMargin, 1e-9));
      expect(CourseStorage.otherWeeksDimCache, closeTo(p.otherWeeksDim, 1e-9));
      expect(CourseStorage.showGridLinesCache, p.showGridLines);
    });

    test('切换方案：每档各自保存自己那套手动调整，互不干扰', () {
      // 方案一下把圆角调成 20（= 方案一自己的手动值）
      var d = <String, dynamic>{
        ...CourseStorage.defaultDisplaySettings(),
        'blockRadius': 20.0,
      };
      // 切到方案二 → 用方案二的出厂预设（圆角 8），不是 20
      d = CourseStorage.switchScheme(d, CourseColorScheme.soft);
      expect(d['scheme'], 'soft');
      expect(d['blockRadius'],
          SchemePreset.of(CourseColorScheme.soft).blockRadius);
      // 在方案二里把圆角调成 3（= 方案二自己的手动值）
      d = <String, dynamic>{...d, 'blockRadius': 3.0};
      // 切回方案一 → 回到方案一那套（20）
      d = CourseStorage.switchScheme(d, CourseColorScheme.standard);
      expect(d['scheme'], 'standard');
      expect(d['blockRadius'], 20.0, reason: '方案一的手动值必须还在');
      // 再切回方案二 → 回到方案二那套（3）
      d = CourseStorage.switchScheme(d, CourseColorScheme.soft);
      expect(d['blockRadius'], 3.0, reason: '方案二的手动值必须还在');
    });

    test('没被动过的方案：切过去用出厂预设', () {
      var d = CourseStorage.defaultDisplaySettings();
      d = CourseStorage.switchScheme(d, CourseColorScheme.vivid);
      final p = SchemePreset.of(CourseColorScheme.vivid);
      expect(d['blockRadius'], p.blockRadius);
      expect(d['rowHeight'], p.rowHeight);
      expect(d['blockMargin'], closeTo(p.blockMargin, 1e-9));
    });

    test('switchScheme 不会动到配色 / 外观以外的既有键', () {
      final d0 = <String, dynamic>{
        ...CourseStorage.defaultDisplaySettings(),
        'showOtherWeeks': true,
      };
      final d1 = CourseStorage.switchScheme(d0, CourseColorScheme.soft);
      expect(d1['showOtherWeeks'], isTrue);
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

    test('滑杆必须真的调得动：浅色模式全量程跨度 ≥ 0.15', () {
      // 用户报告过「非本周灰滑杆调节基本无效」—— 上一版全量程只走了 0.055
      // （≈14 个灰阶），肉眼确实看不出来。这里钉住跨度，防再退回去。
      for (final v in coursePalette) {
        final lo = light(otherWeekGrayFor(Color(v), 0.45, false));
        final hi = light(otherWeekGrayFor(Color(v), 0.85, false));
        expect(hi - lo, greaterThan(0.15),
            reason: '跨度太小 = 滑杆形同虚设');
      }
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
