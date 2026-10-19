import 'package:flutter/material.dart';

import '../models/todo.dart';
import '../repositories/todo_repository.dart';
import '../theme/app_theme.dart';

/// 待办日历（2026-10-18 新增）。
///
/// 上半部分是月历：**有任务的日子按当天未完成数量染红，从很淡到很深**
/// （1 件 → 最淡，4 件及以上 → 最深）。下半部分是选中那天的待办清单。
///
/// 只做「看」，不做拖拽改期：改期在详情/编辑里做，避免误触。
class TodoCalendarPage extends StatefulWidget {
  const TodoCalendarPage({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TodoCalendarPage()),
    );
  }

  @override
  State<TodoCalendarPage> createState() => _TodoCalendarPageState();
}

class _TodoCalendarPageState extends State<TodoCalendarPage> {
  static const _weekCn = ['一', '二', '三', '四', '五', '六', '日'];

  /// 红色由浅到深四档（0 件不着色）。
  static const List<Color> _heat = [
    Color(0x00FFFFFF), // 0
    Color(0xFFFDEDED), // 1
    Color(0xFFF8CFCF), // 2
    Color(0xFFEFA9A9), // 3
    Color(0xFFDB7070), // 4+
  ];

  late DateTime _month;
  late DateTime _selected;
  List<Todo> _all = const <Todo>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selected = DateTime(now.year, now.month, now.day);
    _month = DateTime(now.year, now.month);
    _load();
  }

  Future<void> _load() async {
    final all = await TodoRepository.instance.getAll();
    if (!mounted) return;
    setState(() {
      _all = all;
      _loading = false;
    });
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _line => _isDark ? const Color(0xFF2C2C2C) : const Color(0xFFEDEEF1);
  Color get _faint => _isDark ? const Color(0xFF8B8B8B) : const Color(0xFF9CA3AF);
  Color get _text => _isDark ? const Color(0xFFEDEDED) : const Color(0xFF1F1F1F);
  Color get _surface => _isDark ? const Color(0xFF1C1C1E) : Colors.white;

  static String _key(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 每一天「未完成」的待办数量（重复任务按规则展开计算）。
  Map<String, int> get _counts {
    final map = <String, int>{};
    // 只统计当月前后一格范围内，避免每次遍历几十年的日期。
    final first = DateTime(_month.year, _month.month, 1);
    final last = DateTime(_month.year, _month.month + 1, 0);
    for (var d = first;
        !d.isAfter(last);
        d = DateTime(d.year, d.month, d.day + 1)) {
      var n = 0;
      for (final t in _all) {
        if (t.occursOn(d) && !t.isDoneOn(d)) n++;
      }
      if (n > 0) map[_key(d)] = n;
    }
    return map;
  }

  List<Todo> _todosOf(DateTime day) {
    final list = _all.where((t) => t.occursOn(day)).toList()
      ..sort((a, b) {
        final ad = a.dueAt ?? a.date;
        final bd = b.dueAt ?? b.date;
        return ad.compareTo(bd);
      });
    return list;
  }

  void _shiftMonth(int delta) {
    setState(() => _month = DateTime(_month.year, _month.month + delta));
  }

  void _goToday() {
    final now = DateTime.now();
    setState(() {
      _selected = DateTime(now.year, now.month, now.day);
      _month = DateTime(now.year, now.month);
    });
  }

  @override
  Widget build(BuildContext context) {
    final counts = _counts;
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final leading = DateTime(_month.year, _month.month, 1).weekday - 1;
    final today = DateTime.now();

    final cells = <Widget>[];
    for (var i = 0; i < leading; i++) {
      cells.add(const SizedBox.shrink());
    }
    for (var day = 1; day <= daysInMonth; day++) {
      cells.add(_dayCell(DateTime(_month.year, _month.month, day), today, counts));
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
              child:
                  i + j < cells.length ? cells[i + j] : const SizedBox.shrink(),
            ),
        ],
      ));
    }

    final dayTodos = _todosOf(_selected);

    return Scaffold(
      backgroundColor: _isDark ? const Color(0xFF121212) : const Color(0xFFF8F9FC),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        title: Text(
          '待办日历',
          style: TextStyle(
              fontSize: 16, fontWeight: FontWeight.bold, color: _text),
        ),
        iconTheme: IconThemeData(color: _text),
        actions: [
          TextButton(
            onPressed: _goToday,
            child: Text('今天',
                style: TextStyle(fontSize: 13, color: AppTheme.primaryColor)),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
                  decoration: BoxDecoration(
                    color: _surface,
                    border: Border.all(color: _line),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            onPressed: () => _shiftMonth(-1),
                            icon: const Icon(Icons.chevron_left_rounded,
                                size: 22),
                            color: _faint,
                            visualDensity: VisualDensity.compact,
                          ),
                          Expanded(
                            child: Center(
                              child: Text(
                                '${_month.year} 年 ${_month.month} 月',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: _text),
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => _shiftMonth(1),
                            icon: const Icon(Icons.chevron_right_rounded,
                                size: 22),
                            color: _faint,
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          for (final w in _weekCn)
                            Expanded(
                              child: Center(
                                child: Text(w,
                                    style: TextStyle(
                                        fontSize: 11, color: _faint)),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ...rows,
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // 下半部分：选中那天的待办
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                  decoration: BoxDecoration(
                    color: _surface,
                    border: Border.all(color: _line),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '${_selected.month} 月 ${_selected.day} 日 · '
                            '周${_weekCn[_selected.weekday - 1]}',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: _text),
                          ),
                          const Spacer(),
                          Text(
                            '${dayTodos.length} 条',
                            style: TextStyle(fontSize: 12, color: _faint),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (dayTodos.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Text('这一天没有待办',
                              style: TextStyle(fontSize: 13, color: _faint)),
                        )
                      else
                        for (final t in dayTodos) _todoLine(t),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _dayCell(DateTime day, DateTime today, Map<String, int> counts) {
    final n = counts[_key(day)] ?? 0;
    final level = n == 0 ? 0 : (n >= 4 ? 4 : n);
    final bg = _heat[level];
    final selected = _key(day) == _key(_selected);
    final isToday = _key(day) == _key(today);
    // 深色格子（4+）改用白字，保证对比度。
    final fg = level >= 3 ? Colors.white : _text;

    return GestureDetector(
      onTap: () => setState(() => _selected = day),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Container(
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? AppTheme.primaryColor
                  : (isToday ? _faint : Colors.transparent),
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${day.day}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isToday || selected ? FontWeight.w600 : FontWeight.w400,
                  color: fg,
                ),
              ),
              if (n > 0)
                Text(
                  '$n',
                  style: TextStyle(
                    fontSize: 9,
                    height: 1,
                    color: level >= 3 ? Colors.white : const Color(0xFFA32D2D),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _todoLine(Todo t) {
    final done = t.isDoneOn(_selected);
    final time = t.dueAt != null
        ? '${t.dueAt!.hour.toString().padLeft(2, '0')}:'
            '${t.dueAt!.minute.toString().padLeft(2, '0')}'
        : '全天';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Container(
            width: 15,
            height: 15,
            decoration: BoxDecoration(
              color: done ? AppTheme.primaryColor : Colors.transparent,
              border: Border.all(
                color: done ? AppTheme.primaryColor : _faint,
                width: 1.4,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: done
                ? const Icon(Icons.check_rounded, size: 11, color: Colors.white)
                : null,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: done ? _faint : _text,
                      decoration: done ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
                if (t.isRepeating) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.repeat_rounded, size: 12, color: _faint),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(time, style: TextStyle(fontSize: 11.5, color: _faint)),
        ],
      ),
    );
  }
}
