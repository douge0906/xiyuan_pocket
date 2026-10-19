import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 极简日期选择面板（2026-10-18 新增）。
///
/// **不自己开弹窗**：由「新增待办」弹窗在同一盒子里切换内容，
/// 避免两层 Dialog 叠加（下层白底会在上层四周透出一圈灰边）。
///
/// 风格与全站一致：纯白底、1px 细边框、20 圆角、无阴影、只有主色 + 两级灰。
/// 超出 [first]~[last] 的日期置灰且不可点；选中项为主色实心圆；今天为主色细环。
class DatePickPanel extends StatefulWidget {
  const DatePickPanel({
    super.key,
    required this.initial,
    required this.first,
    required this.last,
    required this.onCancel,
    required this.onConfirm,
  });

  final DateTime initial;
  final DateTime first;
  final DateTime last;
  final VoidCallback onCancel;
  final ValueChanged<DateTime> onConfirm;

  @override
  State<DatePickPanel> createState() => _DatePickPanelState();
}

class _DatePickPanelState extends State<DatePickPanel> {
  static const _weekCn = ['一', '二', '三', '四', '五', '六', '日'];

  late DateTime _sel;
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    _sel = _d(widget.initial);
    _month = DateTime(_sel.year, _sel.month);
  }

  DateTime _d(DateTime v) => DateTime(v.year, v.month, v.day);

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _line => _isDark ? const Color(0xFF2C2C2C) : const Color(0xFFEDEEF1);
  Color get _faint => _isDark ? const Color(0xFF8B8B8B) : const Color(0xFF9CA3AF);
  Color get _text => _isDark ? const Color(0xFFEDEDED) : const Color(0xFF1F1F1F);

  bool get _canPrev {
    final prev = DateTime(_month.year, _month.month - 1);
    return !prev.isBefore(DateTime(widget.first.year, widget.first.month));
  }

  bool get _canNext {
    final next = DateTime(_month.year, _month.month + 1);
    return !next.isAfter(DateTime(widget.last.year, widget.last.month));
  }

  void _shiftMonth(int delta) {
    setState(() => _month = DateTime(_month.year, _month.month + delta));
  }

  void _goToday() {
    final today = _d(DateTime.now());
    final lo = _d(widget.first);
    final hi = _d(widget.last);
    final target = today.isBefore(lo) ? lo : (today.isAfter(hi) ? hi : today);
    setState(() {
      _sel = target;
      _month = DateTime(target.year, target.month);
    });
  }

  bool _inRange(DateTime date) =>
      !date.isBefore(_d(widget.first)) && !date.isAfter(_d(widget.last));

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final leading = DateTime(_month.year, _month.month, 1).weekday - 1;
    final today = _d(DateTime.now());

    final cells = <Widget>[];
    for (var i = 0; i < leading; i++) {
      cells.add(const SizedBox.shrink());
    }
    for (var day = 1; day <= daysInMonth; day++) {
      cells.add(_dayCell(DateTime(_month.year, _month.month, day), today));
    }
    while (cells.length % 7 != 0) {
      cells.add(const SizedBox.shrink());
    }
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += 7) {
      rows.add(Row(
        children: [
          for (var j = 0; j < 7; j++)
            Expanded(
              child: i + j < cells.length
                  ? cells[i + j]
                  : const SizedBox.shrink(),
            ),
        ],
      ));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '选择日期',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: _text,
              ),
            ),
            const Spacer(),
            IconButton(
              onPressed: widget.onCancel,
              icon: const Icon(Icons.close_rounded, size: 20),
              color: _faint,
              tooltip: '关闭',
            ),
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            _arrow(Icons.chevron_left_rounded, _canPrev, () => _shiftMonth(-1)),
            Expanded(
              child: Center(
                child: Text(
                  '${_month.year} 年 ${_month.month} 月',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _text,
                  ),
                ),
              ),
            ),
            _arrow(Icons.chevron_right_rounded, _canNext, () => _shiftMonth(1)),
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            for (final w in _weekCn)
              Expanded(
                child: Center(
                  child: Text(w, style: TextStyle(fontSize: 11, color: _faint)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        ...rows,
        const SizedBox(height: 8),
        Container(height: 1, color: _line),
        const SizedBox(height: 8),
        Row(
          children: [
            GestureDetector(
              onTap: _goToday,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text(
                  '今天',
                  style: TextStyle(
                      fontSize: 13,
                      color: _faint,
                      fontWeight: FontWeight.w500),
                ),
              ),
            ),
            const Spacer(),
            GestureDetector(
              onTap: widget.onCancel,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Text('取消',
                    style: TextStyle(fontSize: 13, color: _faint)),
              ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => widget.onConfirm(_sel),
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  '确定',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _arrow(IconData icon, bool enabled, VoidCallback onTap) {
    return IconButton(
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 20),
      color: _faint,
      disabledColor: _faint.withOpacity(0.3),
      visualDensity: VisualDensity.compact,
      tooltip: icon == Icons.chevron_left_rounded ? '上个月' : '下个月',
    );
  }

  Widget _dayCell(DateTime date, DateTime today) {
    final inRange = _inRange(date);
    final selected = _sameDay(date, _sel);
    final isToday = _sameDay(date, today);

    Color fg;
    if (selected) {
      fg = Colors.white;
    } else if (!inRange) {
      fg = _faint.withOpacity(0.35);
    } else if (isToday) {
      fg = AppTheme.primaryColor;
    } else {
      fg = _text;
    }

    return GestureDetector(
      onTap: inRange ? () => setState(() => _sel = date) : null,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 38,
        child: Center(
          child: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? AppTheme.primaryColor : Colors.transparent,
              shape: BoxShape.circle,
              border: isToday && !selected
                  ? Border.all(color: AppTheme.primaryColor, width: 1)
                  : null,
            ),
            child: Text(
              '${date.day}',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
