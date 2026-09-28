import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// 无锡学院校历（独立页面，2026-2027 学年）。
///
/// 数据取自学校官方《2026～2027学年校历》，两学期各 25 行（周次行 + 假期行）。
/// 配色沿用官方校历的习惯并映射到 App 已有色板：
///   - 周一~周五：正文色；周六/周日：红色；假期期间的 7 天全部红色
///   - 周次 / 寒假 / 暑假：蓝色（与官方一致，App 里用于一卡通卡片的同款蓝）
///   - 今天：蓝色实心圆（沿用 App 日期选择器的圆形高亮语言）
class XylCalendarPage extends StatefulWidget {
  const XylCalendarPage({super.key});

  @override
  State<XylCalendarPage> createState() => _XylCalendarPageState();
}

/// 一行 = 一周。month 仅在该月第一行填字，其余留空（与官方校历合并单元格一致）。
class _CalRow {
  final String month;
  final String week;
  final List<int> days;
  final bool vacation;
  final int? holidayCol;
  final String? holidayName;

  const _CalRow(
    this.month,
    this.week,
    this.days, {
    this.vacation = false,
    this.holidayCol,
    this.holidayName,
  });
}

class _XylCalendarPageState extends State<XylCalendarPage> {
  static const Color _accent = Color(0xFF3B82F6); // 周次 / 假期标签 / 今天高亮
  static const Color _weekendColor = Color(0xFFEF4444); // 周末、假期、节日

  /// 第一学期第一行（含开学前那一周）的周一。
  static final DateTime _term1Start = DateTime(2026, 8, 31);
  static final DateTime _term2Start = DateTime(2027, 2, 22);

  static const List<String> _termNames = ['第一学期', '第二学期'];
  static const List<String> _termNotes = [
    '2026 级本科新生 9 月 3 日报到；其他年级 9 月 5、6 日报到，9 月 7 日开始上课。',
    '2027 年 2 月 20、21 日报到，2 月 22 日开始上课。',
  ];

  /// 第一学期：九月 ~ 次年二月（含寒假）
  static const List<_CalRow> _term1 = [
    _CalRow('九月', '', [31, 1, 2, 3, 4, 5, 6]),
    _CalRow('九月', '1', [7, 8, 9, 10, 11, 12, 13]),
    _CalRow('九月', '2', [14, 15, 16, 17, 18, 19, 20]),
    _CalRow('九月', '3', [21, 22, 23, 24, 25, 26, 27],
        holidayCol: 4, holidayName: '中秋'),
    _CalRow('十月', '4', [28, 29, 30, 1, 2, 3, 4],
        holidayCol: 3, holidayName: '国庆'),
    _CalRow('十月', '5', [5, 6, 7, 8, 9, 10, 11]),
    _CalRow('十月', '6', [12, 13, 14, 15, 16, 17, 18]),
    _CalRow('十月', '7', [19, 20, 21, 22, 23, 24, 25]),
    _CalRow('十一月', '8', [26, 27, 28, 29, 30, 31, 1]),
    _CalRow('十一月', '9', [2, 3, 4, 5, 6, 7, 8]),
    _CalRow('十一月', '10', [9, 10, 11, 12, 13, 14, 15]),
    _CalRow('十一月', '11', [16, 17, 18, 19, 20, 21, 22]),
    _CalRow('十一月', '12', [23, 24, 25, 26, 27, 28, 29]),
    _CalRow('十二月', '13', [30, 1, 2, 3, 4, 5, 6]),
    _CalRow('十二月', '14', [7, 8, 9, 10, 11, 12, 13]),
    _CalRow('十二月', '15', [14, 15, 16, 17, 18, 19, 20]),
    _CalRow('十二月', '16', [21, 22, 23, 24, 25, 26, 27]),
    _CalRow('一月', '17', [28, 29, 30, 31, 1, 2, 3],
        holidayCol: 4, holidayName: '元旦'),
    _CalRow('一月', '18', [4, 5, 6, 7, 8, 9, 10]),
    _CalRow('一月', '19', [11, 12, 13, 14, 15, 16, 17]),
    _CalRow('一月', '寒假', [18, 19, 20, 21, 22, 23, 24], vacation: true),
    _CalRow('一月', '寒假', [25, 26, 27, 28, 29, 30, 31], vacation: true),
    _CalRow('二月', '寒假', [1, 2, 3, 4, 5, 6, 7],
        vacation: true, holidayCol: 5, holidayName: '春节'),
    _CalRow('二月', '寒假', [8, 9, 10, 11, 12, 13, 14], vacation: true),
    _CalRow('二月', '寒假', [15, 16, 17, 18, 19, 20, 21], vacation: true),
  ];

  /// 第二学期：二月 ~ 八月（含暑假）
  static const List<_CalRow> _term2 = [
    _CalRow('二月', '1', [22, 23, 24, 25, 26, 27, 28]),
    _CalRow('三月', '2', [1, 2, 3, 4, 5, 6, 7]),
    _CalRow('三月', '3', [8, 9, 10, 11, 12, 13, 14]),
    _CalRow('三月', '4', [15, 16, 17, 18, 19, 20, 21]),
    _CalRow('三月', '5', [22, 23, 24, 25, 26, 27, 28]),
    _CalRow('四月', '6', [29, 30, 31, 1, 2, 3, 4]),
    _CalRow('四月', '7', [5, 6, 7, 8, 9, 10, 11],
        holidayCol: 0, holidayName: '清明'),
    _CalRow('四月', '8', [12, 13, 14, 15, 16, 17, 18]),
    _CalRow('四月', '9', [19, 20, 21, 22, 23, 24, 25]),
    _CalRow('五月', '10', [26, 27, 28, 29, 30, 1, 2],
        holidayCol: 5, holidayName: '劳动'),
    _CalRow('五月', '11', [3, 4, 5, 6, 7, 8, 9]),
    _CalRow('五月', '12', [10, 11, 12, 13, 14, 15, 16]),
    _CalRow('五月', '13', [17, 18, 19, 20, 21, 22, 23]),
    _CalRow('五月', '14', [24, 25, 26, 27, 28, 29, 30]),
    _CalRow('六月', '15', [31, 1, 2, 3, 4, 5, 6]),
    _CalRow('六月', '16', [7, 8, 9, 10, 11, 12, 13],
        holidayCol: 2, holidayName: '端午'),
    _CalRow('六月', '17', [14, 15, 16, 17, 18, 19, 20]),
    _CalRow('六月', '18', [21, 22, 23, 24, 25, 26, 27]),
    _CalRow('七月', '19', [28, 29, 30, 1, 2, 3, 4]),
    _CalRow('七月', '暑假', [5, 6, 7, 8, 9, 10, 11], vacation: true),
    _CalRow('七月', '暑假', [12, 13, 14, 15, 16, 17, 18], vacation: true),
    _CalRow('七月', '暑假', [19, 20, 21, 22, 23, 24, 25], vacation: true),
    _CalRow('八月', '暑假', [26, 27, 28, 29, 30, 31, 1], vacation: true),
    _CalRow('八月', '暑假', [2, 3, 4, 5, 6, 7, 8], vacation: true),
    _CalRow('八月', '暑假', [9, 10, 11, 12, 13, 14, 15], vacation: true),
  ];

  // 列宽（日内列宽由剩余空间均分，320dp 小屏下仍 ≥ 31dp，不溢出）
  static const double _monthW = 36;
  static const double _weekW = 30;
  static const double _rowH = 36;

  late int _term;

  @override
  void initState() {
    super.initState();
    _term = _resolveDefaultTerm();
  }

  List<_CalRow> get _rows => _term == 0 ? _term1 : _term2;

  DateTime get _termStart => _term == 0 ? _term1Start : _term2Start;

  /// 今天落在哪个学期就默认显示哪个学期，都不在则显示第一学期。
  int _resolveDefaultTerm() {
    final now = DateTime.now();
    for (var i = 0; i < 2; i++) {
      final rows = i == 0 ? _term1 : _term2;
      final start = i == 0 ? _term1Start : _term2Start;
      final end = start.add(Duration(days: rows.length * 7 - 1));
      if (!now.isBefore(start) && !now.isAfter(end)) return i;
    }
    return 0;
  }

  /// 当前教学周（1 起）。今天不在教学周内返回 null。
  int? _currentWeekIndex() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    for (var i = 0; i < _rows.length; i++) {
      final monday = _termStart.add(Duration(days: i * 7));
      final inRow = !today.isBefore(monday) &&
          today.isBefore(monday.add(const Duration(days: 7)));
      if (!inRow) continue;
      final int? w = int.tryParse(_rows[i].week);
      if (w == null) return null; // 假期行
      // 开学前那一周（week 为空）不计周次
      return _rows[i].week.isEmpty ? null : w;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = context.textPrimary;
    final subColor = isDark ? Colors.grey.shade500 : const Color(0xFF9CA3AF);
    final borderColor = context.borderColor;
    final bgColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('无锡学院校历',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        foregroundColor: isDark ? Colors.white : AppTheme.primaryColor,
        elevation: 0.5,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _buildSummaryCard(isDark, titleColor, subColor),
          const SizedBox(height: 12),
          _buildTermSwitch(isDark, subColor),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor),
            ),
            child: Column(
              children: [
                _buildWeekdayHeader(subColor),
                Divider(height: 1, thickness: 1, color: borderColor),
                for (var i = 0; i < _rows.length; i++)
                  _buildWeekRow(_rows[i], i, titleColor, isDark,
                      showDivider: i < _rows.length - 1),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _buildLegend(isDark, subColor),
          const SizedBox(height: 12),
          _buildNote(subColor, isDark),
        ],
      ),
    );
  }

  /// 顶部概览：学年 + 当前所处周次
  Widget _buildSummaryCard(bool isDark, Color titleColor, Color subColor) {
    final week = _currentWeekIndex();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A1A) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: context.borderColor),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _accent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.calendar_month_rounded,
                size: 22, color: _accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('2026 - 2027 学年',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: titleColor)),
                const SizedBox(height: 3),
                Text(
                  week != null
                      ? '${_termNames[_term]} · 第 $week 周'
                      : '${_termNames[_term]} · 假期中',
                  style: TextStyle(fontSize: 12.5, color: subColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTermSwitch(bool isDark, Color subColor) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (var i = 0; i < 2; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _term = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: _term == i ? _accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: Text(
                      _termNames[i],
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            _term == i ? FontWeight.w600 : FontWeight.normal,
                        color: _term == i ? Colors.white : subColor,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWeekdayHeader(Color subColor) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const SizedBox(width: _monthW),
          const SizedBox(width: _weekW),
          for (final w in const ['一', '二', '三', '四', '五', '六', '日'])
            Expanded(
              child: Center(
                child: Text(w,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: subColor)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWeekRow(
    _CalRow row,
    int rowIndex,
    Color titleColor,
    bool isDark, {
    required bool showDivider,
  }) {
    final monday = _termStart.add(Duration(days: rowIndex * 7));
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var isCurrentWeek = false;
    for (var i = 0; i < 7; i++) {
      if (_sameDay(monday.add(Duration(days: i)), today)) {
        isCurrentWeek = true;
        break;
      }
    }

    final rowWidget = Container(
      height: _rowH,
      decoration: isCurrentWeek
          ? BoxDecoration(
              color: _accent.withOpacity(isDark ? 0.16 : 0.07),
              borderRadius: BorderRadius.circular(8),
            )
          : null,
      child: Row(
        children: [
          SizedBox(
            width: _monthW,
            child: Center(
              child: Text(
                row.month,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: isDark ? Colors.grey.shade400 : const Color(0xFF6B7280),
                ),
              ),
            ),
          ),
          SizedBox(
            width: _weekW,
            child: Center(
              child: Text(
                row.week,
                maxLines: 1,
                style: TextStyle(
                  fontSize: row.vacation ? 10.5 : 12,
                  fontWeight: FontWeight.w600,
                  color: _accent,
                ),
              ),
            ),
          ),
          for (var i = 0; i < 7; i++)
            Expanded(
              child: _buildDayCell(
                row: row,
                colIndex: i,
                date: monday.add(Duration(days: i)),
                today: today,
                titleColor: titleColor,
              ),
            ),
        ],
      ),
    );

    if (!showDivider) return rowWidget;
    return Column(
      children: [
        rowWidget,
        Divider(
          height: 1,
          thickness: 1,
          color: isDark ? const Color(0xFF232323) : const Color(0xFFF1F2F4),
        ),
      ],
    );
  }

  Widget _buildDayCell({
    required _CalRow row,
    required int colIndex,
    required DateTime date,
    required DateTime today,
    required Color titleColor,
  }) {
    final isToday = _sameDay(date, today);
    final isRed = row.vacation || colIndex >= 5; // 假期期间 7 天全红（官方同款）
    final isHoliday = row.holidayCol == colIndex;

    final Color numColor;
    if (isToday) {
      numColor = Colors.white;
    } else if (isRed) {
      numColor = _weekendColor;
    } else {
      numColor = titleColor;
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: isToday
                ? const BoxDecoration(color: _accent, shape: BoxShape.circle)
                : null,
            child: Text(
              '${row.days[colIndex]}',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: isToday ? FontWeight.bold : FontWeight.w500,
                color: numColor,
              ),
            ),
          ),
          if (isHoliday)
            Text(
              row.holidayName!,
              maxLines: 1,
              style: const TextStyle(
                fontSize: 8.5,
                height: 1.1,
                fontWeight: FontWeight.w600,
                color: _weekendColor,
              ),
            ),
        ],
      ),
    );
  }

  /// 颜色图例：说明红色 / 蓝色 / 圆点各代表什么
  Widget _buildLegend(bool isDark, Color subColor) {
    Widget dot(Color c, bool filled) => Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: filled ? c : null,
            border: filled ? null : Border.all(color: c, width: 1.2),
            shape: BoxShape.circle,
          ),
        );

    Widget item(Widget mark, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            mark,
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 11, color: subColor)),
          ],
        );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        children: [
          item(const Text('红',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: _weekendColor)),
              '周末 / 假期'),
          item(const Text('蓝',
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w700, color: _accent)),
              '周次'),
          item(dot(_accent, true), '今天'),
          item(const Text('小字',
              style: TextStyle(
                  fontSize: 9, fontWeight: FontWeight.w600, color: _weekendColor)),
              '节假日'),
        ],
      ),
    );
  }

  Widget _buildNote(Color subColor, bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF1F2F4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('报到与开课',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.grey.shade300 : const Color(0xFF6B7280))),
          const SizedBox(height: 4),
          for (var i = 0; i < 2; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${_termNames[i]}：${_termNotes[i]}',
                style: TextStyle(fontSize: 11, height: 1.55, color: subColor),
              ),
            ),
        ],
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
