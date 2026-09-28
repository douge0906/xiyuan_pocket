import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 自定义主题化日期选择器（v2.1.0 引入，v2.3.1 自 course_table_home_page 拆出）：
/// 替换系统 showDatePicker，更美观、符合 App 主题。

/// 自定义主题化日期选择器（v2.1.0）：替换系统 showDatePicker，更美观、符合 App 主题。
Future<DateTime?> showCourseDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  DateTime? firstDate,
  DateTime? lastDate,
  String? helpText,
}) {
  return showDialog<DateTime?>(
    context: context,
    builder: (ctx) => _CourseDatePickerDialog(
      initialDate: initialDate,
      firstDate: firstDate ?? DateTime(2020, 1, 1),
      lastDate: lastDate ?? DateTime(2035, 12, 31),
      helpText: helpText,
    ),
  );
}

class _CourseDatePickerDialog extends StatefulWidget {
  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final String? helpText;
  const _CourseDatePickerDialog({
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
    this.helpText,
  });

  @override
  State<_CourseDatePickerDialog> createState() => _CourseDatePickerDialogState();
}

class _CourseDatePickerDialogState extends State<_CourseDatePickerDialog> {
  late DateTime _viewMonth; // 当前展示月份的第 1 天
  late DateTime _selected;

  @override
  void initState() {
    super.initState();
    _selected = DateTime(widget.initialDate.year, widget.initialDate.month, widget.initialDate.day);
    _viewMonth = DateTime(_selected.year, _selected.month, 1);
  }

  bool _inRange(DateTime d) =>
      !d.isBefore(widget.firstDate) && !d.isAfter(widget.lastDate);

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  void _shiftMonth(int delta) {
    setState(() {
      final m = _viewMonth.month + delta;
      final y = _viewMonth.year + (m - 1) ~/ 12;
      final mm = ((m - 1) % 12) + 1;
      _viewMonth = DateTime(y, mm, 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final subColor = isDark ? Colors.grey.shade400 : const Color(0xFF6B7280);

    // 当月天数与首日星期（周一=1）
    final daysInMonth = DateTime(_viewMonth.year, _viewMonth.month + 1, 0).day;
    final firstWeekday = _viewMonth.weekday; // 1=周一
    final blanks = (firstWeekday - 1) % 7;

    return Dialog(
      backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.helpText != null)
              Text(widget.helpText!, style: TextStyle(fontSize: 12.5, color: subColor)),
            const SizedBox(height: 4),
            Text(
              '${_selected.year} 年 ${_selected.month} 月 ${_selected.day} 日',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                  color: context.textPrimary),
            ),
            const SizedBox(height: 12),
            // 月份切换行
            Row(
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_left_rounded, size: 20),
                  onPressed: _viewMonth.year > widget.firstDate.year ||
                          (_viewMonth.year == widget.firstDate.year && _viewMonth.month > widget.firstDate.month)
                      ? () => _shiftMonth(-1)
                      : null,
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      '${_viewMonth.year} 年 ${_viewMonth.month} 月',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                          color: context.textPrimary),
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_right_rounded, size: 20),
                  onPressed: _viewMonth.year < widget.lastDate.year ||
                          (_viewMonth.year == widget.lastDate.year && _viewMonth.month < widget.lastDate.month)
                      ? () => _shiftMonth(1)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 星期表头（周一开头）
            Row(
              children: ['一', '二', '三', '四', '五', '六', '日']
                  .map((w) => Expanded(
                        child: Center(
                          child: Text(w, style: TextStyle(fontSize: 12.5, color: subColor)),
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 4),
            // 日期网格
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisExtent: 40,
              ),
              itemCount: blanks + daysInMonth,
              itemBuilder: (_, i) {
                if (i < blanks) return const SizedBox.shrink();
                final day = i - blanks + 1;
                final date = DateTime(_viewMonth.year, _viewMonth.month, day);
                final enabled = _inRange(date);
                final isSelected = _sameDay(date, _selected);
                final isToday = _sameDay(date, today);
                return GestureDetector(
                  onTap: enabled ? () => setState(() => _selected = date) : null,
                  child: Center(
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: isSelected ? AppTheme.primaryColor : Colors.transparent,
                        shape: BoxShape.circle,
                        border: isToday && !isSelected
                            ? Border.all(color: AppTheme.primaryColor, width: 1)
                            : null,
                      ),
                      child: Center(
                        child: Text(
                          '$day',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected
                                ? Colors.white
                                : enabled
                                    ? (context.textPrimary)
                                    : (isDark ? Colors.grey.shade700 : Colors.grey.shade300),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _selected = today;
                    _viewMonth = DateTime(today.year, today.month, 1);
                  }),
                  child: const Text('今天', style: TextStyle(fontSize: 12.5)),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: const Text('取消', style: TextStyle(fontSize: 12.5)),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(_selected),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('确定', style: TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
