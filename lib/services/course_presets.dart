part of 'course_storage.dart';

/// 「色彩方案」的**整套外观预设**（2026-10-16）。
///
/// 用户要求：方案不能只管配色 —— **圆角 / 内边距 / 块间距 / 边框 / 课节高度 /
/// 网格线 / 非本周淡化 也要跟着方案一起变**，具体数值照参考截图来。
/// 切换方案 = 一键套用这一整套搭配；套完下面的滑杆仍然可以继续微调。
///
/// 数值来源（两张 867×1920 参考截图，按 2.41 密度折 dp）：
///  · 图1 → 方案二：块宽 101px、圆角 ≈20px（≈8.3dp）、块间距 ≈3dp(margin 1.5)、
///    1 节课高 152px（≈63dp）、无边框；
///  · 图2 → 方案三：块宽 110px、圆角 ≈5px（≈2dp）、块间距 ≈1.2dp(margin 0.6)、
///    1 节课高 167px（≈69dp）、细边框。
class SchemePreset {
  const SchemePreset({
    required this.blockRadius,
    required this.blockPad,
    required this.blockMargin,
    required this.blockBorderWidth,
    required this.rowHeight,
    required this.showGridLines,
    required this.gridLineWidth,
    required this.gridLineDepth,
    required this.otherWeeksDim,
  });

  final double blockRadius;
  final double blockPad;
  final double blockMargin;
  final double blockBorderWidth;

  /// 课节高度：0 = 自动均分（沿用改造前行为）。
  final double rowHeight;
  final bool showGridLines;
  final double gridLineWidth;
  final double gridLineDepth;
  final double otherWeeksDim;

  /// 本预设覆盖的显示设置键 —— 也是「自定义优先」的判定范围。
  static const Set<String> keys = <String>{
    'blockRadius',
    'blockPad',
    'blockMargin',
    'blockBorderWidth',
    'rowHeight',
    'showGridLines',
    'gridLineWidth',
    'gridLineDepth',
    'otherWeeksDim',
  };

  /// 展开成 display settings 的补丁（多 key 一起写）。
  Map<String, dynamic> toDisplayPatch() => <String, dynamic>{
        'blockRadius': blockRadius,
        'blockPad': blockPad,
        'blockMargin': blockMargin,
        'blockBorderWidth': blockBorderWidth,
        'rowHeight': rowHeight,
        'showGridLines': showGridLines,
        'gridLineWidth': gridLineWidth,
        'gridLineDepth': gridLineDepth,
        'otherWeeksDim': otherWeeksDim,
      };

  /// 从一份 display settings 里**摘出本预设覆盖的那几个键的当前值**。
  ///
  /// 用途：切换方案时，先把「当前方案自己那套值」原样存下来（见
  /// [CourseStorage.switchScheme]）。
  static Map<String, dynamic> appearanceOf(Map<String, dynamic> display) =>
      <String, dynamic>{
        for (final k in keys)
          if (display.containsKey(k)) k: display[k],
      };

  /// 取某方案的外观预设。
  static SchemePreset of(CourseColorScheme s) {
    switch (s) {
      case CourseColorScheme.standard:
        // 方案一 = 改造前的中性观感，值就是出厂默认（谁手调过也不会被它带跑）
        return const SchemePreset(
          blockRadius: 6,
          blockPad: 3.0,
          blockMargin: 1.8,
          blockBorderWidth: 0.8,
          rowHeight: 0,
          showGridLines: true,
          gridLineWidth: 1.0,
          gridLineDepth: 0.5,
          otherWeeksDim: 0.75,
        );
      case CourseColorScheme.soft:
        // 方案二（复刻图 1）：圆角大、块间距略宽、无边框、课节 63
        return const SchemePreset(
          blockRadius: 8,
          blockPad: 4.5,
          blockMargin: 1.5,
          blockBorderWidth: 0,
          rowHeight: 63,
          showGridLines: true,
          gridLineWidth: 1.0,
          gridLineDepth: 0.3,
          otherWeeksDim: 0.78,
        );
      case CourseColorScheme.vivid:
        // 方案三（复刻图 2）：圆角很小、块几乎贴满、细边框、课节 69
        return const SchemePreset(
          blockRadius: 2,
          blockPad: 4.0,
          blockMargin: 0.6,
          blockBorderWidth: 0.8,
          rowHeight: 69,
          showGridLines: true,
          gridLineWidth: 1.0,
          gridLineDepth: 0.35,
          otherWeeksDim: 0.75,
        );
    }
  }
}

