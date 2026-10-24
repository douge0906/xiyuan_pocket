import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../models/course_model.dart';
import '../../theme/app_theme.dart';
import '../services/course_storage.dart';
import '../../widgets/course_day_header.dart';

/// 网格线颜色（v1.3.0：连续深浅，0 最淡 → 1 最深）。
///
/// 贯穿竖线与横线共用这一个函数；结构线（格子右边线）不参与。
/// 数值对应关系（亮色）：0 ≈ #F0F0F0、0.5 ≈ #DCDCDC、1 ≈ #C4C4C4。
Color gridLineColorFor(BuildContext context, double depth) {
  final d = depth.clamp(0.0, 1.0);
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark
      ? const Color(0xFF8C8C8C).withOpacity(0.15 + 0.55 * d)
      : const Color(0xFF9CA3AF).withOpacity(0.12 + 0.50 * d);
}

// 课程表网格的展示层组件（v1.0.0 从 course_table_home_page.dart 剥离）。
//
// 这些类原本就是独立的 StatelessWidget —— 依赖全部经构造函数显式传入，
// 没有任何页面状态耦合，因此这里是**纯搬迁 + 私有名改为公开名**
// （_Block → CourseBlock 等），不改动任何渲染逻辑。
//
// 主类通过构造参数传入 onOpenAdd / onOpenDetail 回调用，语义不变。

/// 节次块：每个块代表相邻的两节课（如 1-2 节）
class CourseBlock {
  final String label;
  final int period; // 0=上午 1=下午 2=晚上
  final int start;
  final int end;
  final String time;

  const CourseBlock({
    required this.label,
    required this.period,
    required this.start,
    required this.end,
    required this.time,
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'period': period,
        'start': start,
        'end': end,
        'time': time,
      };

  factory CourseBlock.fromJson(Map<String, dynamic> j) => CourseBlock(
        label: (j['label'] as String?) ?? '',
        period: (j['period'] as int?) ?? 0,
        start: (j['start'] as int?) ?? 1,
        end: (j['end'] as int?) ?? 1,
        time: (j['time'] as String?) ?? '',
      );
}


/// 默认上课时间块：按图片中的 11 节课，每节课一个单节块。
/// period: 0=上午 1=下午 2=晚上
const List<CourseBlock> kDefaultCourseBlocks = [
  CourseBlock(label: '1', period: 0, start: 1, end: 1, time: '08:00\n08:45'),
  CourseBlock(label: '2', period: 0, start: 2, end: 2, time: '08:55\n09:40'),
  CourseBlock(label: '3', period: 0, start: 3, end: 3, time: '10:10\n10:55'),
  CourseBlock(label: '4', period: 0, start: 4, end: 4, time: '11:05\n11:50'),
  CourseBlock(label: '5', period: 1, start: 5, end: 5, time: '13:45\n14:30'),
  CourseBlock(label: '6', period: 1, start: 6, end: 6, time: '14:40\n15:25'),
  CourseBlock(label: '7', period: 1, start: 7, end: 7, time: '15:55\n16:40'),
  CourseBlock(label: '8', period: 1, start: 8, end: 8, time: '16:50\n17:35'),
  CourseBlock(label: '9', period: 2, start: 9, end: 9, time: '18:45\n19:30'),
  CourseBlock(label: '10', period: 2, start: 10, end: 10, time: '19:40\n20:25'),
  CourseBlock(label: '11', period: 2, start: 11, end: 11, time: '20:35\n21:20'),
];


class CourseBlockRow extends StatelessWidget {
  final CourseBlock block;
  final int todayWeekday;
  final bool isDark;

  /// v1.1.1：背景图开启时，格子底色必须透明，否则会把背景图整片遮住
  /// （用户反馈「背景图只显示在最右侧一列，左侧空白」）。
  final bool transparent;
  final void Function(int weekday, int startSlot, int endSlot) onOpenAdd;

  /// 时间列宽度覆盖（v1.6.5）：预览按缩放值传，null = 跟随设置。
  final double? timeColWidth;

  const CourseBlockRow({
    super.key,
    required this.block,
    required this.todayWeekday,
    required this.isDark,
    this.transparent = false,
    required this.onOpenAdd,
    this.timeColWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 2026-10-13：设置里开了「隐藏节次时间」就不渲染这一列
        if (!CourseStorage.hideSectionTimeCache)
          CourseTimeCell(
            block: block,
            isDark: isDark,
            transparent: transparent,
            width: timeColWidth,
          ),
        for (int d = 0; d < 7; d++)
          CourseDayCell(
            weekday: d + 1,
            block: block,
            isToday: d + 1 == todayWeekday,
            isDark: isDark,
            transparent: transparent,
            onOpenAdd: onOpenAdd,
          ),
      ],
    );
  }
}

class CourseTimeCell extends StatelessWidget {
  final CourseBlock block;
  final bool isDark;
  const CourseTimeCell({
    super.key,
    required this.block,
    required this.isDark,
    this.transparent = false,
    this.width,
  });

  /// 背景图开启时透出底图。
  final bool transparent;

  /// 列宽覆盖（v1.6.5）：null = 跟随「时间列宽度」设置 [activeTimeColWidth]；
  /// 预览里传缩放后的宽度，保证与网格其它部分对齐。
  final double? width;

  @override
  Widget build(BuildContext context) {
    final times = block.time.split('\n');
    final start = times.isNotEmpty ? times[0] : '';
    final end = times.length > 1 ? times[1] : '';
    // 对齐参考 App A：节次数字 + 起止时间竖向居中，统一中性灰，无彩色圆点。
    final fg = isDark ? Colors.grey.shade400 : const Color(0xFF58686F);
    final subFg = isDark ? Colors.grey.shade600 : Colors.grey.shade400;
    // v1.4.0（2026-10-13 用户澄清）：关闭「显示网格线」时**不应有任何竖线** ——
    // 结构线（时间列右边线）也跟随开关；颜色/粗细与贯穿线、横线共用同一套参数。
    final showLines = CourseStorage.showGridLinesCache;
    return Container(
      // 🔴 v1.6.5 修复：此前写死 kCourseTimeColWidth —— 调「时间列宽度」滑杆时
      //    只有竖线和课程卡移动了，**灰色时间列区域本身纹丝不动**（用户反馈）。
      width: width ?? activeTimeColWidth,
      decoration: BoxDecoration(
        color: transparent
            ? Colors.transparent
            : (isDark ? const Color(0xFF202020) : Colors.grey.shade50),
        border: showLines
            ? Border(
                right: BorderSide(
                    color: gridLineColorFor(
                        context, CourseStorage.gridLineDepthCache),
                    width: CourseStorage.gridLineWidthCache))
            : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            block.label,
            // v1.7.2 回退：上轮误将 11 改为 12.5，而该栏所在行的高度由「可用高度 ÷ 节次数」动态计算，
            //          字号变大后文字撑破格子（用户反馈的课表溢出）。恢复 11 并显式写行高。
            // v1.4.0：三行文字统一 maxLines:1 —— 系统字号放大时「08:00」可能换行撑破
            //         格子（widget 测试实测 Ahem 宽字体下溢出 23px），单行裁剪更稳。
            maxLines: 1,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg, height: 14 / 11),
          ),
          const SizedBox(height: 2),
          Text(
            start,
            maxLines: 1,
            style: TextStyle(fontSize: 11, color: fg, height: 14 / 11),
          ),
          Text(
            end,
            maxLines: 1,
            style: TextStyle(fontSize: 11, color: subFg, height: 14 / 11),
          ),
        ],
      ),
    );
  }
}

class CourseDayCell extends StatelessWidget {
  final int weekday;
  final CourseBlock block;
  final bool isToday;
  final bool isDark;

  /// 背景图开启时透出底图（v1.1.1）。
  final bool transparent;
  final void Function(int weekday, int startSlot, int endSlot) onOpenAdd;
  const CourseDayCell({
    super.key,
    required this.weekday,
    required this.block,
    required this.isToday,
    required this.isDark,
    this.transparent = false,
    required this.onOpenAdd,
  });

  @override
  Widget build(BuildContext context) {
    // v1.4.0：结构线（格子右边线）跟随「显示网格线」开关与深浅/粗细滑杆
    // —— 关闭网格线时整张表不该有任何竖线（用户 2026-10-13 澄清）。
    final showLines = CourseStorage.showGridLinesCache;
    return Expanded(
      child: GestureDetector(
        onTap: () => onOpenAdd(weekday, block.start, block.end),
        behavior: HitTestBehavior.translucent,
        child: Container(
          decoration: BoxDecoration(
            color: transparent
                ? Colors.transparent
                : (isToday
                    ? AppTheme.primaryColor.withOpacity(0.04)
                    : (context.surfaceColor)),
            border: showLines
                ? Border(
                    right: BorderSide(
                        color: gridLineColorFor(
                            context, CourseStorage.gridLineDepthCache),
                        width: CourseStorage.gridLineWidthCache))
                : null,
          ),
        ),
      ),
    );
  }
}

/// 整周课表网格：底层是节次行（点击空白添加课程），上层是绝对定位的合并课程卡片。
/// 数字方块按钮（用于节数 / 周数选择）。
class CourseNumberChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool disabled;
  final VoidCallback? onTap;

  const CourseNumberChip({
    super.key,
    required this.label,
    this.selected = false,
    this.disabled = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: disabled ? null : onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primaryColor
              : (disabled
                  ? (context.borderColor)
                  : (context.borderColor)),
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          border: Border.all(
            color: selected
                ? AppTheme.primaryColor
                : (disabled ? (isDark ? Colors.grey.shade700 : Colors.grey.shade300) : Colors.grey.shade300),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected
                ? Colors.white
                : (disabled
                    ? (isDark ? Colors.grey.shade600 : Colors.grey.shade400)
                    : (isDark ? Colors.grey.shade300 : const Color(0xFF374151))),
          ),
        ),
      ),
    );
  }
}

class CourseWeekGrid extends StatelessWidget {
  final List<CourseBlock> blocks;
  final int todayWeekday;
  final int selectedWeek;
  final List<Course> courses;
  final bool isDark;
  final Color surfaceColor;
  final void Function(int weekday, int startSlot, int endSlot) onOpenAdd;
  final void Function(Course course) onOpenDetail;

  /// 点击「冲突格」（同一时段多门课）→ 打开冲突解决弹窗（v1.6.0）。
  final void Function(List<Course> conflicting) onResolveConflict;

  /// 是否套用「课节高度」滑杆（v1.6.4）。课表页为 true；
  /// 设置页顶部的小预览传 false（预览格子固定高，套用会溢出）。
  final bool useFixedRowHeight;

  /// 预览缩放（v1.6.5）：设置页顶部的小预览按此比例缩小时间列宽与行高，
  /// 让「时间列宽度 / 课节高度 / 日期栏高度」滑杆在预览里**实时可见**。
  /// 课表页恒为 1.0。
  final double previewScale;

  const CourseWeekGrid({
    super.key,
    required this.blocks,
    required this.todayWeekday,
    required this.selectedWeek,
    required this.courses,
    required this.isDark,
    required this.surfaceColor,
    required this.onOpenAdd,
    required this.onOpenDetail,
    required this.onResolveConflict,
    this.useFixedRowHeight = true,
    this.previewScale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 去除时段分隔横栏（上午/下午/晚上）：每节课一行等高分摊，叠加卡片按节次索引定位。
        // v1.3.0：横向网格线的厚度跟着「网格线粗细」滑杆走（关网格线时为 0），
        // 行高分配同步扣减，保证 n 行 + (n-1) 条线恰好铺满可用高度。
        final showGridLines = CourseStorage.showGridLinesCache;
        final lineW = CourseStorage.gridLineWidthCache;
        final dividerHeight = showGridLines ? lineW : 0.0;
        // v1.6.4：课节高度滑杆（0 = 自动均分，与改造前完全一致；>0 = 固定行高，
        // 超出可用高度时由课表页外面的滚动容器兜住）。
        final fixedRow =
            useFixedRowHeight ? CourseStorage.rowHeightCache * previewScale : 0.0;
        final rowHeight = fixedRow > 0
            ? fixedRow
            : (constraints.maxHeight - (blocks.length - 1) * dividerHeight) / blocks.length;
        // v1.6.5：预览按 previewScale 缩小时间列宽（保证预览里各部件对齐）
        final timeColW = activeTimeColWidth * previewScale;
        final dayWidth = (constraints.maxWidth - timeColW) / 7;
        final gridLineColor =
            gridLineColorFor(context, CourseStorage.gridLineDepthCache);

        final overlays = <Widget>[];
        // v1.6.0：同一时段多门课不再直接叠放（后面的盖住前面的，看着像 App 出错）
        // —— 聚成「冲突组」：组内轮播显示 + 点击进解决弹窗。按星期收集后，
        // 组内按节次区间重叠合并（含完全重叠：同起止的两门）。
        final byWeekday = <int,
            List<({Course course, int startIdx, int endIdx})>>{};
        for (final course in courses) {
          // v1.1.0：「显示非本周课程」开启时不再直接跳过非本周课程，改为淡化显示
          final activeThisWeek = course.isActiveOnWeek(selectedWeek);
          if (!activeThisWeek && !CourseStorage.showOtherWeeksCache) continue;
          final startIdx = blocks.indexWhere((b) => b.start == course.startSlot);
          final endIdx = blocks.lastIndexWhere((b) => b.end == course.endSlot);
          if (startIdx == -1 || endIdx == -1 || endIdx < startIdx) continue;

          final weekdays = <int>[];
          final cwd = course.weekday;
          if (cwd == 0) {
            weekdays.addAll([1, 2, 3, 4, 5, 6, 7]);
          } else if (cwd == -1) {
            weekdays.addAll([1, 2, 3, 4, 5]);
          } else {
            weekdays.add(cwd);
          }
          for (final wd in weekdays) {
            byWeekday
                .putIfAbsent(wd, () => [])
                .add((course: course, startIdx: startIdx, endIdx: endIdx));
          }
        }
        for (final entry in byWeekday.entries) {
          final wd = entry.key;
          final items = entry.value..sort((a, b) => a.startIdx - b.startIdx);
          final groups =
              <List<({Course course, int startIdx, int endIdx})>>[];
          for (final it in items) {
            if (groups.isNotEmpty && it.startIdx <= groups.last.last.endIdx) {
              groups.last.add(it);
            } else {
              groups.add([it]);
            }
          }
          for (final g in groups) {
            final top = g.first.startIdx * (rowHeight + dividerHeight);
            final maxEnd = g.map((e) => e.endIdx).reduce((a, b) => a > b ? a : b);
            final height = (maxEnd - g.first.startIdx + 1) * rowHeight +
                (maxEnd - g.first.startIdx) * dividerHeight;
            final cellCourses = g.map((e) => e.course).toList();
            overlays.add(Positioned(
              top: top,
              left: timeColW + (wd - 1) * dayWidth,
              width: dayWidth,
              height: height,
              child: cellCourses.length == 1
                  ? CourseCardWidget(
                      course: cellCourses.first,
                      onTap: () => onOpenDetail(cellCourses.first),
                      dimmed: !cellCourses.first.isActiveOnWeek(selectedWeek),
                    )
                  : ConflictCell(
                      courses: cellCourses,
                      selectedWeek: selectedWeek,
                      onResolve: () => onResolveConflict(cellCourses),
                    ),
            ));
          }
        }

        // v1.1.0：贯穿竖线（对齐在线版）—— 每天一条从上到下的完整竖线 + 时间列右边界。
        // 此前只有「单元格右边线」，被横线打断成一段段，两版观感不一致（用户反馈）。
        // v1.3.0：粗细与深浅改由连续滑杆控制（与横线同一颜色）。
        final gridLines = <Widget>[];
        if (showGridLines) {
          for (int c = 0; c < 7; c++) {
            gridLines.add(Positioned(
              top: 0,
              bottom: 0,
              left: timeColW + c * dayWidth - lineW / 2,
              child: Container(width: lineW, color: gridLineColor),
            ));
          }
        }

        // v1.1.0：课表背景图（与在线版一致）——图片铺满整表 + 底色薄膜透出，
        // 薄膜既让背景图能看见，又保证时间列文字 / 空格依然可读。
        final bgPath = CourseStorage.backgroundImageCache;
        final bgFile = bgPath.isEmpty ? null : File(bgPath);
        final hasBg = bgFile != null && bgFile.existsSync();

        return Container(
          color: surfaceColor,
          child: Stack(
            // v1.1.1 关键修复（对齐在线版）：必须 StackFit.expand。
            // 默认 StackFit.loose 时 Stack 尺寸按非定位子组件（Column）塌陷，
            // 导致「背景图只显示一列」+「贯穿竖线完全看不见」两个症状。
            fit: StackFit.expand,
            children: [
              if (hasBg) ...[
                // v1.1.1 修复「背景图错位到最右边一列」：Stack 里非 Positioned 的子组件
                // 会按自身尺寸参与布局，图片按原始分辨率摆 -> 偏移。必须 Positioned.fill 铺满。
                Positioned.fill(
                  child:
                      Image.file(bgFile, fit: BoxFit.cover, gaplessPlayback: true),
                ),
                ColoredBox(
                  // v1.1.1 薄膜加浓（0.55 -> 0.72）：真机上看背景图时时间/日期文字被图案
                  // 干扰到几乎看不清 —— 盖住底图的同时要保证文字可读。
                  color: surfaceColor.withOpacity(isDark ? 0.78 : 0.72),
                ),
              ],
              Column(
                children: [
                  for (int i = 0; i < blocks.length; i++) ...[
                    // 🔴 v1.6.6 修复：固定行高时**必须用确定高度**。
                    //    用 Expanded 会被容器高度均分，与课程卡（按 rowHeight 定位）
                    //    **错位**；容器高度不足时下面的课还会被裁掉 —— 预览里看到
                    //    的就是「明明调长了，预览反而更短」。
                    //    自动模式（fixedRow = 0）仍用 Expanded 均分可用高度。
                    if (fixedRow > 0)
                      SizedBox(
                        height: rowHeight,
                        child: CourseBlockRow(
                          block: blocks[i],
                          todayWeekday: todayWeekday,
                          isDark: isDark,
                          transparent: hasBg,
                          onOpenAdd: onOpenAdd,
                          timeColWidth: timeColW,
                        ),
                      )
                    else
                      Expanded(
                        child: CourseBlockRow(
                          block: blocks[i],
                          todayWeekday: todayWeekday,
                          isDark: isDark,
                          transparent: hasBg,
                          onOpenAdd: onOpenAdd,
                          timeColWidth: timeColW,
                        ),
                      ),
                    // v1.1.0：横线也只由「课表设置 → 显示网格线」控制
                    // （读内存缓存，避免逐层传参）：关 = 完全没有网格线。
                    if (i != blocks.length - 1 && showGridLines)
                      Divider(
                          height: dividerHeight,
                          thickness: dividerHeight,
                          color: gridLineColor),
                  ],
                ],
              ),
              // v1.1.1 逐字对齐在线版顺序：**gridLines 在 overlays 之前**
              // （在线版 _WeekGrid 就是这个顺序，我之前写反了）。
              ...gridLines,
              ...overlays,
            ],
          ),
        );
      },
    );
  }
}

class CourseCardWidget extends StatelessWidget {
  final Course course;
  final VoidCallback? onTap;

  /// 是否为「非本周课程」（v1.1.0）：淡化显示，仅在设置里开启「显示非本周课程」时出现。
  final bool dimmed;

  const CourseCardWidget({
    super.key,
    required this.course,
    this.onTap,
    this.dimmed = false,
  });

  @override
  Widget build(BuildContext context) {
    // 复刻参考 App A 的课程卡：浅色背景 + 黑线细边框 + 黑色字体（课程名加粗）+ 内容从顶部开始、完整展示。
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // v1.6.9：色彩方案只在**渲染期**转换（不改课程数据）——
    // 方案一 = 课程原色；方案二 / 三 = 提饱和 + 压明度（2026-10-16 按参考图重定的 S/L）。
    final bg = courseColorFor(course.colorValue, CourseStorage.schemeCache);

    // 2026-10-13 v1.3.0：圆角 / 内边距 / 块间距 / 不透明度 / 边框（粗细·实虚·虚线密度）
    // 全部读连续滑杆值 —— 课表页与设置页顶部实时预览共用这一份渲染。
    final radius = CourseStorage.blockRadiusCache;
    final pad = CourseStorage.blockPadCache;
    final outerMargin = CourseStorage.blockMarginCache;
    final opacity = CourseStorage.blockOpacityCache;
    final borderW = CourseStorage.blockBorderWidthCache; // 0 = 无边框
    final dashed = CourseStorage.blockBorderDashedCache;
    final dashDensity = CourseStorage.blockDashDensityCache; // 越大越密
    final borderColor =
        isDark ? Colors.white.withOpacity(0.25) : Colors.black.withOpacity(0.30);

    // v1.6.9：非本周课程 = **淡灰**（不再是「向背景色混合」）；
    // 保留各课原色的明暗差异，滑杆控制整体灰的深浅。文字色按最终底色重算。
    var surface = dimmed
        ? otherWeekGrayFor(bg, CourseStorage.otherWeeksDimCache, isDark)
        : bg;
    if (opacity < 1.0) surface = surface.withOpacity(opacity);
    final fg = textOnColor(surface);

    Widget card = Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(radius),
        border: (borderW > 0 && !dashed)
            ? Border.all(color: borderColor, width: borderW)
            : null,
      ),
      // 2026-10-16（用户：「非本周课程 颜色灰白虚度增加 并且打上多道斜线」）：
      // 非本周课程在底色上再叠一层 **45° 多道斜线**。
      // 注意结构：斜线画在 **padding 之外 + ClipRRect 裁到圆角内**，
      // 且用 `painter`（背景层）而不是 foregroundPainter ⇒ 斜线**在文字下面**，
      // 不会糊住课程名。
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: CustomPaint(
          painter: dimmed
              ? _DiagonalHatchPainter(
                  color: isDark
                      ? Colors.white.withOpacity(0.10)
                      : Colors.black.withOpacity(0.07),
                  spacing: 7,
                  strokeWidth: 1,
                )
              : null,
          child: Padding(
            padding: EdgeInsets.only(
                left: pad,
                right: pad,
                top: pad,
                bottom: pad > 1 ? pad - 1 : pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                Text(
                  course.name,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: fg,
                      height: 1.25),
                  maxLines: 3,
                  overflow: TextOverflow.clip,
                  softWrap: true,
                ),
                // 教室放在教师之前，且**地点不允许省略**（字号不变、房号不删）：
                // 给到 3 行、用 clip 换行显示，多出来的垂直空间从教师那里让。
                // 教师是唯一可以被省略的一项（放不下就尾部打省略号）。
                if (course.classroom.isNotEmpty &&
                    CourseStorage.showClassroomOnCardCache)
                  Padding(
                    padding: const EdgeInsets.only(top: 1.5),
                    child: Text(
                      '@${course.classroom}',
                      style: TextStyle(fontSize: 10.5, color: fg, height: 1.2),
                      maxLines: 3,
                      overflow: TextOverflow.clip,
                      softWrap: true,
                    ),
                  ),
                if (course.teacher.isNotEmpty &&
                    CourseStorage.showTeacherOnCardCache)
                  Padding(
                    padding: const EdgeInsets.only(top: 1.5),
                    child: Text(
                      course.teacher,
                      style: TextStyle(fontSize: 10.5, color: fg, height: 1.2),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    // 虚线边框（v1.3.0 真正实现 —— 此前只是个没生效的占位选项）：
    // 实线太规矩，虚线更"轻"。用 PathMetric 按段长/间隔自绘，密度越大段越短、越密。
    if (borderW > 0 && dashed) {
      card = CustomPaint(
        foregroundPainter: _DashedRoundedBorderPainter(
          color: borderColor,
          strokeWidth: borderW,
          radius: radius,
          dashLength: 4.0 / dashDensity,
          gapLength: 3.0 / dashDensity,
        ),
        child: card,
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.all(outerMargin),
        child: card,
      ),
    );
  }
}

/// 非本周课程的斜线纹理画笔（2026-10-16）。
///
/// 在课程卡底色之上铺一层等距 **45° 斜线**（左下 → 右上，即 `///` 方向），
/// 把「非本周课程」和本周课程一眼分开 —— 用户要求「打上多道斜线」。
///
/// 只管画线、不管裁剪：调用方在外面套 `ClipRRect(圆角)`，把线裁在卡片圆角内。
class _DiagonalHatchPainter extends CustomPainter {
  const _DiagonalHatchPainter({
    required this.color,
    this.spacing = 7,
    this.strokeWidth = 1,
  });

  final Color color;

  /// 相邻两条斜线的**水平**间距（越小越密）。
  final double spacing;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt
      ..style = PaintingStyle.stroke;
    final gap = spacing.clamp(2.0, 40.0);
    // 起点从 -height 开始，斜线才能把整块（含左上角）铺满。
    for (double x = -size.height; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DiagonalHatchPainter old) =>
      old.color != color ||
      old.spacing != spacing ||
      old.strokeWidth != strokeWidth;
}

/// 虚线圆角边框画笔（v1.3.0）。
///
/// 做法：把圆角矩形路径按「段长 + 间隔」切成一段段画 —— 这是 Flutter 里
/// 画虚线边框的标准做法（`Path.computeMetrics()` + `extractPath`），
/// 与掌上徐工的 `course_card.dart` 同一思路（实现独立重写，未复制其代码）。
class _DashedRoundedBorderPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double radius;
  final double dashLength;
  final double gapLength;

  const _DashedRoundedBorderPainter({
    required this.color,
    required this.strokeWidth,
    required this.radius,
    required this.dashLength,
    required this.gapLength,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final inset = strokeWidth / 2;
    final w = math.max(size.width - strokeWidth, 1.0);
    final h = math.max(size.height - strokeWidth, 1.0);
    final rect = Rect.fromLTWH(inset, inset, w, h);
    final r = radius.clamp(0.0, math.min(w, h) / 2);
    final path = Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final dash = dashLength.clamp(1.0, 24.0);
    final gap = gapLength.clamp(1.0, 24.0);
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final next = math.min(dist + dash, metric.length);
        canvas.drawPath(metric.extractPath(dist, next), paint);
        dist = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRoundedBorderPainter old) =>
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.radius != radius ||
      old.dashLength != dashLength ||
      old.gapLength != gapLength;
}

/// 冲突格（v1.6.0）：同一时段排了多门课时的格子。
///
/// 显示策略（仿掌上徐工）：格子内**轮播**这几门课 —— 顶部一条细进度条做
/// 「当前门停留倒计时」（3 秒走满即切下一门、循环），底部小圆点标明共几门、
/// 当前是第几个。点击整格 → 打开冲突解决弹窗（选保留哪门 / 都保留）。
class ConflictCell extends StatefulWidget {
  const ConflictCell({
    super.key,
    required this.courses,
    required this.selectedWeek,
    required this.onResolve,
  });

  /// 该时段重叠的课程（>=2 门，可能混合「教务 + 手动」两种来源）。
  final List<Course> courses;
  final int selectedWeek;
  final VoidCallback onResolve;

  @override
  State<ConflictCell> createState() => _ConflictCellState();
}

class _ConflictCellState extends State<ConflictCell>
    with SingleTickerProviderStateMixin {
  /// 轮播周期：3 秒一门（与掌上徐工一致）。
  static const _period = Duration(seconds: 3);

  /// 进度条动画（只负责"当前门还剩多久"的视觉）。
  late final AnimationController _tick =
      AnimationController(vsync: this, duration: _period);

  /// 🔴 v1.6.3：切换改由 **Timer 驱动**。
  ///    此前靠 `_tick.value < 0.01`（repeat 回绕的瞬间）来切换 —— 在低帧率
  ///    设备上每帧增量 > 0.01，会整帧跳过这个窗口，导致"倒计时不动、也不切课"
  ///    （用户报告：冲突倒计时无效、无反应）。Timer 不受帧率影响，可靠。
  Timer? _timer;
  int _i = 0;

  @override
  void initState() {
    super.initState();
    _tick.forward();
    _timer = Timer.periodic(_period, (_) {
      if (!mounted) return;
      setState(() => _i = (_i + 1) % widget.courses.length);
      _tick.forward(from: 0); // 进度条重置，与下一次切换对齐
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final course = widget.courses[_i];
    return Stack(
      children: [
        Positioned.fill(
          child: CourseCardWidget(
            course: course,
            onTap: widget.onResolve,
            dimmed: !course.isActiveOnWeek(widget.selectedWeek),
          ),
        ),
        // 顶部倒计时进度条（当前门的剩余停留时间）
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _tick,
              builder: (_, __) => LinearProgressIndicator(
                value: _tick.value,
                minHeight: 3,
                backgroundColor: Colors.white.withOpacity(0.25),
                valueColor: AlwaysStoppedAnimation<Color>(
                    Colors.white.withOpacity(0.95)),
              ),
            ),
          ),
        ),
        // 底部指示点：共几门、当前第几个
        Positioned(
          left: 0,
          right: 0,
          bottom: 4,
          child: IgnorePointer(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int i = 0; i < widget.courses.length; i++)
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _i
                          ? Colors.white
                          : Colors.white.withOpacity(0.45),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
