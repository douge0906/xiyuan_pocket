import 'package:flutter/material.dart';

import '../services/course_storage.dart';
import '../theme/app_theme.dart';
import 'course_date_picker.dart';

/// 课表页表头：周次选择 + 一周日期行（v2.3.1 自 course_table_home_page 拆出）。
const double kCourseTimeColWidth = 48.0;

/// 运行时的时间列宽：设置里开了「隐藏节次时间」就归零（2026-10-13）；
/// 否则读「课表布局 → 时间列宽度」滑杆（v1.6.4，默认 48）。
double get activeTimeColWidth => CourseStorage.hideSectionTimeCache
    ? 0.0
    : CourseStorage.timeColWidthCache;
const List<String> courseDayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

class CourseDayHeader extends StatelessWidget {
  final int selectedWeek;
  final int todayWeekday;
  final DateTime semesterStart;
  final ValueChanged<DateTime> onSemesterStartChanged;
  final ValueChanged<int> onWeekChanged;
  final bool isDark;

  const CourseDayHeader({
    super.key,
    required this.selectedWeek,
    required this.todayWeekday,
    required this.semesterStart,
    required this.onSemesterStartChanged,
    required this.onWeekChanged,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    // 直接由开学日期正向推算第 N 周的周一，避免「今天回推」跨学期错乱（9.7 bug 修复）
    final monday = semesterStart.add(Duration(days: (selectedWeek - 1) * 7));
    final surfaceColor = context.cardColor;
    // 日期栏要和时间栏一样透出全屏背景，否则顶部留一条实色（2026-10-26）
    final hasFullBg = CourseStorage.backgroundImageCache.isNotEmpty ||
        CourseStorage.backgroundColorCache != null;

    return Container(
      // v1.6.4：日期栏高度可调（课表布局滑杆，默认 56）
      height: CourseStorage.dateRowHeightCache,
      decoration: BoxDecoration(
        color: hasFullBg ? Colors.transparent : surfaceColor,
        border: Border(bottom: BorderSide(color: context.borderColor)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: activeTimeColWidth,
            child: InkWell(
              onTap: () => _pickWeek(context),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '第$selectedWeek周',
                    style:  TextStyle(fontSize: AppTheme.fontCaption, fontWeight: FontWeight.bold, color: AppTheme.primaryColor),
                    textAlign: TextAlign.center,
                  ),
                   Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: AppTheme.primaryColor),
                ],
              ),
            ),
          ),
          for (int i = 0; i < 7; i++)
            Expanded(
              child: Container(
                color: i + 1 == todayWeekday &&
                        CourseStorage.highlightTodayCache
                    ? AppTheme.primaryColor.withValues(alpha: 0.05)
                    : Colors.transparent,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        courseDayLabels[i],
                        style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: i + 1 == todayWeekday
                              ? FontWeight.bold
                              : FontWeight.w500,
                          color: i + 1 == todayWeekday
                              ? AppTheme.primaryColor
                              : (isDark
                                  ? Colors.grey.shade400
                                  : const Color(0xFF6B7280)),
                        ),
                      ),
                      // 2026-10-13：设置里可隐藏「月/日」（只留周几）
                      if (!CourseStorage.hideDateRowCache) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${monday.add(Duration(days: i)).month}/${monday.add(Duration(days: i)).day}',
                          style: TextStyle(
                            fontSize: AppTheme.fontCaption,
                            color: i + 1 == todayWeekday
                                ? AppTheme.primaryColor.withValues(alpha: 0.85)
                                : (isDark
                                    ? Colors.grey.shade600
                                    : Colors.grey.shade500),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _pickWeek(BuildContext context) {
    // 🔴 白色弹层内的文字一律用固定深色常量，不再跟 isDark 走三元。
    //    弹层底色写死纯白（与 semester_picker 一致），若文字仍取深色主题的浅灰
    //    就是白底浅灰字，深色模式下几乎读不出来（v1.0.9 修正）。
    const ink = Color(0xFF1F1F1F);
    const sub = Color(0xFF9CA3AF);
    final currentWeek = CourseStorage.teachingWeek(DateTime.now(), semesterStart);
    final startStr =
        '${semesterStart.year}-${semesterStart.month.toString().padLeft(2, '0')}-${semesterStart.day.toString().padLeft(2, '0')}';
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFFE8E8EE)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 560),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 标题行 + 右上角 ×（UI 死律：居中 Dialog 必须可关）
                Row(
                  children: [
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('选择周数',
                          style: TextStyle(
                              fontSize: AppTheme.fontTitle,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1F1F1F))),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close_rounded,
                          size: 20, color: Color(0xFF9CA3AF)),
                      tooltip: '关闭',
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '点击「调整」可修改开学日期，周次随之变化',
                  style: const TextStyle(fontSize: AppTheme.fontCaption, color: sub),
                ),
                const SizedBox(height: 12),
                // 开学日期卡片
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.15)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                        ),
                        child:  Icon(Icons.event_rounded, size: 17, color: AppTheme.primaryColor),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('开学日期（第 1 周周一）',
                                style: TextStyle(
                                    fontSize: AppTheme.fontSmall,
                                    fontWeight: FontWeight.w600,
                                    color: ink)),
                            const SizedBox(height: 2),
                            Text(
                              startStr,
                              style: const TextStyle(fontSize: AppTheme.fontSmall, color: ink),
                            ),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          final picked = await showCourseDatePicker(
                            context: ctx,
                            initialDate: semesterStart,
                            firstDate: DateTime(2020, 1, 1),
                            lastDate: DateTime(2035, 12, 31),
                            helpText: '选择开学日期（用于计算教学周）',
                          );
                          if (picked != null && ctx.mounted) {
                            onSemesterStartChanged(picked);
                            Navigator.of(ctx).pop();
                          }
                        },
                        icon: const Icon(Icons.edit_calendar_rounded, size: 16),
                        label: const Text('调整'),
                        style: TextButton.styleFrom(foregroundColor: AppTheme.primaryColor),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 4),
                SizedBox(
                  height: 260,
                  child: ListView.builder(
                    itemCount: 25,
                    itemBuilder: (_, i) {
                      final week = i + 1;
                      final isCurrent = week == currentWeek;
                      final isSelected = week == selectedWeek;
                      // 该周日期范围（周一 ~ 周日）
                      final wm = semesterStart.add(Duration(days: (week - 1) * 7));
                      final dateText = '${wm.month}/${wm.day} - ${wm.add(const Duration(days: 6)).month}/${wm.add(const Duration(days: 6)).day}';
                      return ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                        leading: isCurrent
                            ? Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.primaryColor,
                                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                                ),
                                child: const Text('本周', style: TextStyle(fontSize: AppTheme.fontCaption, color: Colors.white, fontWeight: FontWeight.w600)),
                              )
                            : null,
                        title: Text(
                          '第$week周',
                          style: TextStyle(
                            fontSize: AppTheme.fontBody,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected
                                ? AppTheme.primaryColor
                                : ink,
                          ),
                        ),
                        subtitle: Text(
                          dateText,
                          style: const TextStyle(fontSize: AppTheme.fontCaption, color: sub),
                        ),
                        trailing: isSelected ?  Icon(Icons.check_circle_rounded, color: AppTheme.primaryColor, size: 20) : null,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
                        selectedTileColor: AppTheme.primaryColor.withValues(alpha: 0.08),
                        onTap: () {
                          onWeekChanged(week);
                          Navigator.of(ctx).pop();
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
