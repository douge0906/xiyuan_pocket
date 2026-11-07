part of 'course_table_home_page.dart';

/// 教务里的一节课在多数学校由两节小课组成，但这里只关心「第几周」。
const List<String> _kWeekdayNames = ['', '一', '二', '三', '四', '五', '六', '日'];

/// 「确认第 1 周」对话框（v1.0.9 重做）。
///
/// ## 为什么不再直接开日历
///
/// 老实现一打开就是 7×6 的月历，唯一的说明文字是「请确认本学期第 1 周的周一
/// （默认 9 月 8 日）」。用户要做的事其实是：**判断今天该算第几周**，
/// 而日历只给日期、不给周次，换算全靠脑内做减法和除法——这就是用户说的
/// 「首周选择」体感差。
///
/// 现在的做法是**结果导向**：
/// 1. 主体第一行直接给结论「今天 = 第 N 周 · 周三」，用户一眼能验证对不对；
/// 2. 给两个高频选项（本周一 / 上一周周一），二者覆盖绝大多数情况；
/// 3. 只有这两个都不对，才展开日历手动挑，挑完立刻把新周次回显到第一行。
///
/// 这样最坏情况（手动挑）才需要看日历，最好情况（默认对）一眼点确定。
class _SemesterStartDialog extends StatefulWidget {
  const _SemesterStartDialog({
    required this.suggested,
    required this.firstDate,
    required this.lastDate,
  });

  /// 估算出的第 1 周周一（进入页面时的默认值）。
  final DateTime suggested;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_SemesterStartDialog> createState() => _SemesterStartDialogState();
}

class _SemesterStartDialogState extends State<_SemesterStartDialog> {
  late DateTime _start;
  bool _pickerOpen = false;

  @override
  void initState() {
    super.initState();
    _start = widget.suggested;
  }

  /// 今天按 [_start] 算应该是第几周（与 `CourseStorage.teachingWeek` 同口径）。
  int get _weekOfToday {
    final now = DateTime.now();
    final diff = DateTime(now.year, now.month, now.day)
        .difference(DateTime(_start.year, _start.month, _start.day))
        .inDays;
    if (diff < 0) return 1;
    return diff ~/ 7 + 1;
  }

  String get _rangeText {
    final end = _start.add(const Duration(days: 6));
    return '${_start.month}月${_start.day}日 - ${end.month}月${end.day}日';
  }

  Future<void> _openPicker() async {
    final picked = await showCourseDatePicker(
      context: context,
      initialDate: _start,
      firstDate: widget.firstDate,
      lastDate: widget.lastDate,
      helpText: '选择本学期第 1 周的任意一天，会自动对到那一周的周一',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _start = CourseStorage.mondayOf(picked);
      _pickerOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final week = _weekOfToday;
    final weekday = DateTime.now().weekday;
    final todayText = '今天 = 第 $week 周 · 周${_kWeekdayNames[weekday]}';

    return AlertDialog(
      backgroundColor: context.cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(color: AppTheme.cardStrokeColor(context.isDark)),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      title: Row(
        children: [
          Icon(Icons.event_available_rounded,
              size: 20, color: AppTheme.primaryColor),
          const SizedBox(width: 8),
          const Text('确认第 1 周',
              style: TextStyle(
                  fontSize: AppTheme.fontTitle, fontWeight: FontWeight.bold)),
        ],
      ),
      content: SizedBox(
        width: (MediaQuery.of(context).size.width - 96).clamp(280.0, 400.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 结论行：用户唯一需要核对的东西
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                border: Border.all(
                    color: AppTheme.primaryColor.withValues(alpha: 0.20)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    todayText,
                    style: TextStyle(
                      fontSize: AppTheme.fontHeading,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryColor,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '第 1 周：$_rangeText',
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall,
                        color: context.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // 2026-11-04（用户 m20950 #1）：去掉下方「本周一开始 / 上一周的
            // 周一 / 都不对」这一组可能性判断 —— 用户明确要求「直接换成在
            // 日历中选择」。少一次猜测，也就少一次猜错。
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _pickerOpen ? null : _openPicker,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  side: BorderSide(color: context.borderColor),
                  foregroundColor: context.textPrimary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMd)),
                ),
                icon: Icon(Icons.calendar_month_rounded,
                    size: 17, color: AppTheme.primaryColor),
                label: const Text('在日历里选第 1 周'),
              ),
            ),
            const SizedBox(height: 6),
            Text('选这一周里的任意一天即可，会自动对到那一周的周一。',
                style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    color: context.textTertiary)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('用默认值',
              style: TextStyle(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.grey.shade400
                      : const Color(0xFF6B7280))),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _start),
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.primaryColor,
            minimumSize: const Size(76, 40),
          ),
          child: const Text('确定'),
        ),
      ],
    );
  }

}
