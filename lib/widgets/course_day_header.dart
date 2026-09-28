import 'package:flutter/material.dart';

import '../services/course_storage.dart';
import '../theme/app_theme.dart';
import 'course_date_picker.dart';

/// 课表页表头：周次选择 + 一周日期行（v2.3.1 自 course_table_home_page 拆出）。
const double kCourseTimeColWidth = 48.0;
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
    final surfaceColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;

    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: surfaceColor,
        border: Border(bottom: BorderSide(color: context.borderColor)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: kCourseTimeColWidth,
            child: InkWell(
              onTap: () => _pickWeek(context),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '第$selectedWeek周',
                    style:  TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.primaryColor),
                    textAlign: TextAlign.center,
                  ),
                   Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: AppTheme.primaryColor),
                ],
              ),
            ),
          ),
          for (int i = 0; i < 7; i++)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                    courseDayLabels[i],
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: i + 1 == todayWeekday ? FontWeight.bold : FontWeight.w500,
                      color: i + 1 == todayWeekday ? AppTheme.primaryColor : (isDark ? Colors.grey.shade400 : const Color(0xFF6B7280)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${monday.add(Duration(days: i)).month}/${monday.add(Duration(days: i)).day}',
                    style: TextStyle(
                      fontSize: 11,
                        color: i + 1 == todayWeekday
                            ? AppTheme.primaryColor.withOpacity(0.85)
                            : (isDark ? Colors.grey.shade600 : Colors.grey.shade500),
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

  void _pickWeek(BuildContext context) {
    final currentWeek = CourseStorage.teachingWeek(DateTime.now(), semesterStart);
    final startStr =
        '${semesterStart.year}-${semesterStart.month.toString().padLeft(2, '0')}-${semesterStart.day.toString().padLeft(2, '0')}';
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 12),
              Text('选择周数', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary)),
              const SizedBox(height: 4),
              Text(
                '点击「调整」可修改开学日期，周次随之变化',
                style: TextStyle(fontSize: 11, color: isDark ? Colors.grey.shade500 : const Color(0xFF9CA3AF)),
              ),
              const SizedBox(height: 12),
              // 开学日期卡片
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.primaryColor.withOpacity(0.15)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child:  Icon(Icons.event_rounded, size: 17, color: AppTheme.primaryColor),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('开学日期（第 1 周周一）',
                              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(
                            startStr,
                            style: TextStyle(fontSize: 12.5, color: isDark ? Colors.grey.shade300 : const Color(0xFF374151)),
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
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text('本周', style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
                            )
                          : null,
                      title: Text(
                        '第$week周',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected
                              ? AppTheme.primaryColor
                              : (isDark ? Colors.grey.shade300 : const Color(0xFF374151)),
                        ),
                      ),
                      subtitle: Text(
                        dateText,
                        style: TextStyle(fontSize: 11, color: isDark ? Colors.grey.shade600 : const Color(0xFF9CA3AF)),
                      ),
                      trailing: isSelected ?  Icon(Icons.check_circle_rounded, color: AppTheme.primaryColor, size: 20) : null,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      selectedTileColor: AppTheme.primaryColor.withOpacity(0.08),
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
    );
  }
}
