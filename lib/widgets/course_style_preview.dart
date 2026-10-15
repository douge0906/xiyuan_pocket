import 'package:flutter/material.dart';

import '../models/course_model.dart';
import '../services/course_storage.dart';
import '../theme/app_theme.dart';
import 'course_grid_widgets.dart';

/// 课表外观「实时预览」（v1.4.0，2026-10-13 重做）。
///
/// 课表设置页顶部的迷你课表：**优先显示当前课表的真实课程**（按本周过滤，
/// 本周没课再用内置示例兜底 —— 与掌上徐工 `_TimetableGridPreview` 同一策略，
/// 思路借鉴、实现独立），用与真机课表完全相同的渲染组件（CourseWeekGrid /
/// CourseCardWidget，读同一份设置缓存）绘制，调任何滑杆立即重绘。
///
/// ⚠️ 两个必须遵守的约定：
///  · 调用处**不要给本组件（以及内部包网格的 SizedBox）加 const** —— const
///    实例在父级重建时会被 identical 短路跳过，预览就不会跟着设置变
///    （2026-10-13 实测踩坑：上一版加了 const，用户反馈"修改后不变"）；
///  · 外观参数全部由 CourseStorage.*Cache 读取，组件只收数据（课程/周次/日期）。
class CourseStylePreview extends StatelessWidget {
  const CourseStylePreview({
    super.key,
    required this.courses,
    required this.week,
    required this.monday,
    required this.todayWeekday,
  });

  /// 当前激活课表的全部课程（本周 + 非本周都传 —— 网格内部按「显示非本周课程」
  /// 开关决定显示/淡化，这样那个开关的效果也能在预览里直接看到）。
  final List<Course> courses;

  /// 当前教学周（真实值）。
  final int week;

  /// 本周周一（用于日期栏的真实日期）。
  final DateTime monday;

  /// 今天周几（1~7，真实值，用于高亮）。
  final int todayWeekday;

  /// 只展示前三节（够看全：跨行、单节、空槽都能出现）。
  static const List<CourseBlock> _blocks = [
    CourseBlock(label: '1', period: 0, start: 1, end: 1, time: '08:00\n08:45'),
    CourseBlock(label: '2', period: 0, start: 2, end: 2, time: '08:55\n09:40'),
    CourseBlock(label: '3', period: 0, start: 3, end: 3, time: '10:10\n10:55'),
  ];

  /// 本周完全没课时用的内置示例（保证预览永远有东西可看）。
  static List<Course> _fallback() => const [
        Course(
            id: '_pv1',
            name: '高等数学',
            teacher: '张老师',
            classroom: 'A101',
            weekday: 1,
            startSlot: 1,
            endSlot: 2,
            weeks: '1-16周',
            colorValue: 0xFFD2E5F8),
        Course(
            id: '_pv2',
            name: '大学英语',
            teacher: '李老师',
            classroom: '外语楼203',
            weekday: 3,
            startSlot: 1,
            endSlot: 1,
            weeks: '1-16周',
            colorValue: 0xFFF8D2D7),
        Course(
            id: '_pv3',
            name: '线性代数',
            classroom: '教2-305',
            weekday: 4,
            startSlot: 2,
            endSlot: 3,
            weeks: '1-16周',
            colorValue: 0xFFE5D2F8),
        Course(
            id: '_pv4',
            name: '大学物理',
            teacher: '王老师',
            weekday: 5,
            startSlot: 1,
            endSlot: 3,
            weeks: '1-16周',
            colorValue: 0xFFD2F0E5),
        // 一门只上前几周的：开「显示非本周课程」时能看到它淡化显示。
        Course(
            id: '_pv5',
            name: '体育',
            classroom: '东操场',
            weekday: 2,
            startSlot: 3,
            endSlot: 3,
            weeks: '1-4周',
            colorValue: 0xFFF8E5D2),
      ];

  bool get _hasThisWeekCourse => courses.any((c) => c.isActiveOnWeek(week));

  /// 预览缩放比（v1.6.8）：**等比缩放** —— 由「预览卡片宽度 ÷ 真机课表宽度」
  /// 算出来，而不是之前手拍的固定 0.62。
  ///
  /// 为什么重要：手拍值只缩了纵向（行高/日期栏），横向（时间列）没动 ——
  /// 横纵比例跟真机对不上，拖「课节高度」时看到的"变高了多少"是失真的
  /// （用户反馈「不是真实预览」）。等比缩放后，预览里的一切与真机同比例。
  double _scale(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final previewW = screenW - 16 * 2 - 14 * 2; // 页面外距 + 卡片内距
    final gridW = screenW - 16 * 2;             // 真机课表可用宽度
    if (gridW <= 0) return 1.0;
    return (previewW / gridW).clamp(0.6, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final display = _hasThisWeekCourse ? courses : _fallback();
    final scale = _scale(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Row(
            children: [
              Icon(Icons.visibility_outlined,
                  size: 14, color: context.textTertiary),
              const SizedBox(width: 6),
              Text(
                _hasThisWeekCourse ? '实时预览 · 你的课表' : '实时预览 · 示例课表（本周无课）',
                style: TextStyle(fontSize: 11.5, color: context.textTertiary),
              ),
            ],
          ),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          child: Container(
            // 与真机课表同款表面色（深色模式下也一致）
            color: context.surfaceColor,
            child: Column(
              children: [
                _dateRow(context, scale),
                SizedBox(
                  // 课节高度滑杆实时可见：调过行高时按「等比缩放后的行高 × 节数」
                  // 给足容器高度（上限 300，超出由容器裁剪）；「自动」时保持 150。
                  height: _gridHeight(scale),
                  // ⚠️ 不要加 const（见类头部说明）
                  child: _PreviewGrid(
                    courses: display,
                    week: week,
                    todayWeekday: todayWeekday,
                    scale: scale,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 预览缩放比（v1.6.5）：时间列宽 / 行高 / 日期栏高度都按此缩小，
  /// 0.62 ≈ 原来的观感（34/56 ≈ 0.61、30/48 ≈ 0.63）。
  /// 预览网格高度：行高「自动」时用 150；调过行高就按「等比缩放后的行高 ×
  /// 节数」给足 —— 行高调大，预览整体变高（真实反映）。上限 300 只是防止把
  /// 设置页撑太长，超出时显示前几行（**不会再压扁行高**）。
  double _gridHeight(double scale) {
    final rh = CourseStorage.rowHeightCache;
    if (rh <= 0) return 150;
    final dividerH = CourseStorage.showGridLinesCache
        ? CourseStorage.gridLineWidthCache
        : 0.0;
    final total = _blocks.length * (rh * scale) +
        (_blocks.length - 1) * dividerH;
    return total.clamp(150, 300);
  }

  /// 简版日期栏：**真实周次 + 真实日期**（与真机表头同一口径，只是更小、不可点）。
  Widget _dateRow(BuildContext context, double scale) {
    // 时间列宽 / 日期栏高度都跟随设置，并按**同一比例**缩放 —— 与网格对齐
    final timeColW = CourseStorage.hideSectionTimeCache
        ? 0.0
        : CourseStorage.timeColWidthCache * scale;
    final hideDate = CourseStorage.hideDateRowCache;
    const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return Container(
      height: hideDate ? 26 : (CourseStorage.dateRowHeightCache * scale),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        border: Border(bottom: BorderSide(color: context.borderColor)),
      ),
      child: Row(
        children: [
          if (timeColW > 0)
            SizedBox(
              width: timeColW,
              child: Center(
                child: Text('第$week周',
                    style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.primaryColor)),
              ),
            ),
          for (int i = 0; i < 7; i++)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      labels[i],
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight:
                            i + 1 == todayWeekday ? FontWeight.bold : FontWeight.w500,
                        color: i + 1 == todayWeekday
                            ? AppTheme.primaryColor
                            : context.textSecondary,
                      ),
                    ),
                    if (!hideDate)
                      Text(
                        '${monday.add(Duration(days: i)).month}/${monday.add(Duration(days: i)).day}',
                        style: TextStyle(
                          fontSize: 9,
                          color: i + 1 == todayWeekday
                              ? AppTheme.primaryColor.withOpacity(0.85)
                              : context.textTertiary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 内层网格：给 CourseWeekGrid 一个固定高度（它按可用高度等分节次行）。
///
/// ⚠️ 调用处不要加 const（见类头部说明）。
class _PreviewGrid extends StatelessWidget {
  const _PreviewGrid({
    required this.courses,
    required this.week,
    required this.todayWeekday,
    required this.scale,
  });

  final List<Course> courses;
  final int week;
  final int todayWeekday;
  /// 等比缩放比（由外层按宽度算出）
  final double scale;

  @override
  Widget build(BuildContext context) {
    return CourseWeekGrid(
      blocks: CourseStylePreview._blocks,
      todayWeekday: todayWeekday,
      selectedWeek: week,
      courses: courses,
      isDark: context.isDark,
      surfaceColor: context.surfaceColor,
      onOpenAdd: (_, __, ___) {},
      onOpenDetail: (_) {},
      // 预览只是看样式：点冲突格不做任何处理（真实解决入口在课表页）
      onResolveConflict: (_) {},
      // v1.6.5：预览套用行高（容器高度已按缩放后总高给足），
      // 并按**同一等比比例**缩放时间列宽 —— 三根布局滑杆都能实时看到真实效果。
      useFixedRowHeight: true,
      previewScale: scale,
    );
  }
}
