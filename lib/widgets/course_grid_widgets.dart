import 'package:flutter/material.dart';
import '../../models/course_model.dart';
import '../../theme/app_theme.dart';
import '../services/course_storage.dart';
import '../../widgets/course_day_header.dart';

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
  final void Function(int weekday, int startSlot, int endSlot) onOpenAdd;
  const CourseBlockRow({
    super.key,
    required this.block,
    required this.todayWeekday,
    required this.isDark,
    required this.onOpenAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CourseTimeCell(block: block, isDark: isDark),
        for (int d = 0; d < 7; d++)
          CourseDayCell(
            weekday: d + 1,
            block: block,
            isToday: d + 1 == todayWeekday,
            isDark: isDark,
            onOpenAdd: onOpenAdd,
          ),
      ],
    );
  }
}

class CourseTimeCell extends StatelessWidget {
  final CourseBlock block;
  final bool isDark;
  const CourseTimeCell({super.key, required this.block, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final times = block.time.split('\n');
    final start = times.isNotEmpty ? times[0] : '';
    final end = times.length > 1 ? times[1] : '';
    // 对齐参考 App A：节次数字 + 起止时间竖向居中，统一中性灰，无彩色圆点。
    final fg = isDark ? Colors.grey.shade400 : const Color(0xFF58686F);
    final subFg = isDark ? Colors.grey.shade600 : Colors.grey.shade400;
    return Container(
      width: kCourseTimeColWidth,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF202020) : Colors.grey.shade50,
        // 右边线由 CourseWeekGrid 的贯穿竖线统一绘制，这里不再画（否则叠成双线）。
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            block.label,
            // v1.7.2 回退：上轮误将 11 改为 12.5，而该栏所在行的高度由「可用高度 ÷ 节次数」动态计算，
            //          字号变大后文字撑破格子（用户反馈的课表溢出）。恢复 11 并显式写行高。
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg, height: 14 / 11),
          ),
          const SizedBox(height: 2),
          Text(
            start,
            style: TextStyle(fontSize: 11, color: fg, height: 14 / 11),
          ),
          Text(
            end,
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
  final void Function(int weekday, int startSlot, int endSlot) onOpenAdd;
  const CourseDayCell({
    super.key,
    required this.weekday,
    required this.block,
    required this.isToday,
    required this.isDark,
    required this.onOpenAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: () => onOpenAdd(weekday, block.start, block.end),
        behavior: HitTestBehavior.translucent,
        child: Container(
          decoration: BoxDecoration(
            color: isToday ? AppTheme.primaryColor.withOpacity(0.04) : (context.surfaceColor),
            // 右边线由 CourseWeekGrid 的贯穿竖线统一绘制，这里不再画（否则叠成双线）。
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
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primaryColor
              : (disabled
                  ? (context.borderColor)
                  : (context.borderColor)),
          borderRadius: BorderRadius.circular(8),
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
            fontSize: 12.5,
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
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 去除时段分隔横栏（上午/下午/晚上）：每节课一行等高分摊，叠加卡片按节次索引定位。
        const dividerHeight = 1.0;
        final rowHeight = (constraints.maxHeight - (blocks.length - 1) * dividerHeight) / blocks.length;
        final dayWidth = (constraints.maxWidth - kCourseTimeColWidth) / 7;

        final overlays = <Widget>[];
        for (final course in courses) {
          if (!course.isActiveOnWeek(selectedWeek)) continue;
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

          final top = startIdx * (rowHeight + dividerHeight);
          final height = (endIdx - startIdx + 1) * rowHeight + (endIdx - startIdx) * dividerHeight;

          for (final wd in weekdays) {
            overlays.add(Positioned(
              top: top,
              left: kCourseTimeColWidth + (wd - 1) * dayWidth,
              width: dayWidth,
              height: height,
              child: CourseCardWidget(course: course, onTap: () => onOpenDetail(course)),
            ));
          }
        }

        // v1.1.0：贯穿竖线（对齐在线版）—— 每天一条从上到下的完整竖线 + 时间列右边界。
        // 此前只有「单元格右边线」，被横线打断成一段段，两版观感不一致（用户反馈）。
        final gridLines = <Widget>[];
        if (CourseStorage.showGridLinesCache) {
          final lineColor = isDark ? Colors.grey.shade600 : Colors.grey.shade300;
          for (int c = 0; c < 7; c++) {
            gridLines.add(Positioned(
              top: 0,
              bottom: 0,
              left: kCourseTimeColWidth + c * dayWidth,
              child: Container(width: 1.0, color: lineColor),
            ));
          }
        }

        return Container(
          color: surfaceColor,
          child: Stack(
            children: [
              Column(
                children: [
                  for (int i = 0; i < blocks.length; i++) ...[
                    Expanded(
                      child: CourseBlockRow(
                        block: blocks[i],
                        todayWeekday: todayWeekday,
                        isDark: isDark,
                        onOpenAdd: onOpenAdd,
                      ),
                    ),
                    // v1.1.0：横线也只由「课表设置 → 显示网格线」控制
                    // （读内存缓存，避免逐层传参）：关 = 完全没有网格线。
                    if (i != blocks.length - 1 &&
                        CourseStorage.showGridLinesCache)
                      Divider(height: dividerHeight, thickness: dividerHeight, color: context.borderColor),
                  ],
                ],
              ),
              ...overlays,
              ...gridLines,
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
  const CourseCardWidget({super.key, required this.course, this.onTap});

  @override
  Widget build(BuildContext context) {
    // 复刻参考 App A 的课程卡：浅色背景 + 黑线细边框 + 黑色字体（课程名加粗）+ 内容从顶部开始、完整展示。
    final bg = Color(course.colorValue);
    final fg = textOnColor(bg);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        height: double.infinity,
        margin: const EdgeInsets.all(1.8),
        padding: const EdgeInsets.only(left: 3, right: 3, top: 3, bottom: 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isDark ? Colors.white.withOpacity(0.25) : Colors.black.withOpacity(0.30),
            width: 0.8,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Text(
              course.name,
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: fg, height: 1.25),
              maxLines: 3,
              overflow: TextOverflow.clip,
              softWrap: true,
            ),
            if (course.teacher.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 1.5),
                child: Text(
                  course.teacher,
                  style: TextStyle(fontSize: 10.5, color: fg, height: 1.2),
                  maxLines: 2,
                  overflow: TextOverflow.clip,
                  softWrap: true,
                ),
              ),
            if (course.classroom.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 1.5),
                child: Text(
                  '@${course.classroom}',
                  style: TextStyle(fontSize: 10.5, color: fg, height: 1.2),
                  maxLines: 2,
                  overflow: TextOverflow.clip,
                  softWrap: true,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
