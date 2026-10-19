import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/todo.dart';
import '../providers/course_provider.dart';
import '../repositories/todo_repository.dart';
import '../services/course_storage.dart';
import '../services/exam_storage.dart';
import '../services/home_prefs.dart';
import '../theme/app_theme.dart';
import '../widgets/course_grid_widgets.dart' show CourseBlock, kDefaultCourseBlocks;
import 'add_todo_dialog.dart';
import 'todo_detail_dialog.dart';

/// 新版首页（2026-10-17 第二版）。
///
/// 结构：问候行 → 添加待办条 → 接下来 → 概览一行 → **考试倒计时 + 待考列表**
///      → 逾期（红）→ 今天 + 已完成折叠
///
/// 第二版按用户反馈修正：
///   ① **逾期真的生效**：同一天但时刻已过的也算逾期（原来只算「昨天及更早」）；
///   ② 考试新增**倒计时**并**列出所有待考**；
///   ③ 卡片内部改**纯白**（只有「添加待办」那一条保持虚色）；
///   ④ 课程加**实时倒计时**（每秒刷新）；
///   ⑤ 点任务弹出**新增时填的内容**。
class HomeNewView extends ConsumerStatefulWidget {
  const HomeNewView({super.key});

  @override
  ConsumerState<HomeNewView> createState() => _HomeNewViewState();
}

enum _Kind { course, exam, todo }

class _Upcoming {
  const _Upcoming({
    required this.kind,
    required this.title,
    required this.when,
    this.endAt,
  });

  final _Kind kind;
  final String title;

  /// 排序与倒计时的基准时刻（课程=上课时刻，考试=开考时刻，待办=截止时刻）。
  final DateTime when;

  /// 课程的下课时刻（用于「进行中 · 剩 X」）。
  final DateTime? endAt;
}

class _ExamItem {
  const _ExamItem({
    required this.name,
    required this.at,
    required this.place,
  });

  final String name;
  final DateTime at;
  final String place;
}

class _HomeNewViewState extends ConsumerState<HomeNewView>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _showDone = false;

  Timer? _ticker;

  /// 上一次 _load() 对应的「今天」，用于跨天检测（P1 修复）。
  DateTime? _loadedDay;

  List<_Upcoming> _upcoming = const <_Upcoming>[];
  List<Todo> _todayTodos = const <Todo>[];
  List<Todo> _overdueTodos = const <Todo>[];

  /// 之后（今天以后）的待办。2026-10-18 修：原来只为「今天 / 逾期」建列表，
  /// 用户给其他日子建的待办既不进今天也不进逾期 → 建完就「消失」。
  List<Todo> _futureTodos = const <Todo>[];
  List<Todo> _doneTodos = const <Todo>[];
  List<_ExamItem> _exams = const <_ExamItem>[];

  int _todayCourseCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    // 实时倒计时（1s 一次）。2026-10-18 P1 修复两件事：
    //   ① 页面不可见（切到别的 Tab）时**不再重建** —— 用 TickerMode 门控；
    //   ② 顺带做跨天检测：日期一变就 _load()，不必等用户下拉刷新。
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!TickerMode.of(context)) return;
      final today = _dayOf(DateTime.now());
      if (_loadedDay != null && today != _loadedDay) {
        _load();
        return;
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从后台回到前台：跨天就重载。
  /// （原来只在 initState 后加载一次，App 挂一夜第二天还是昨天的日期与待办。）
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!mounted) return;
    final today = _dayOf(DateTime.now());
    if (_loadedDay == null || today != _loadedDay) _load();
  }

  // ------------------------------------------------------------ 工具

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

  static String _hm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  /// 倒计时文案：X 天 X 小时 / X 小时 X 分 / X 分 X 秒
  static String _countdown(DateTime target, DateTime now) {
    var d = target.difference(now);
    if (d.isNegative) d = Duration.zero;
    final days = d.inDays;
    final hours = d.inHours % 24;
    final mins = d.inMinutes % 60;
    final secs = d.inSeconds % 60;
    if (days > 0) return '$days 天 $hours 小时';
    if (hours > 0) return '$hours 小时 $mins 分';
    if (mins > 0) return '$mins 分 ${secs.toString().padLeft(2, '0')} 秒';
    return '$secs 秒';
  }

  /// 节次 → (开始, 结束) 时刻。自定义时间块优先，与课表显示一致。
  static (int, int, int, int)? _slotRange(List<CourseBlock> blocks, int slot) {
    for (final b in blocks) {
      if (slot >= b.start && slot <= b.end) {
        final parts = b.time.split('\n');
        final s = parts.first.trim().split(':');
        final e = parts.length > 1
            ? parts[1].trim().split(':')
            : parts.first.trim().split(':');
        if (s.length == 2 && e.length == 2) {
          final sh = int.tryParse(s[0]);
          final sm = int.tryParse(s[1]);
          final eh = int.tryParse(e[0]);
          final em = int.tryParse(e[1]);
          if (sh != null && sm != null && eh != null && em != null) {
            return (sh, sm, eh, em);
          }
        }
      }
    }
    return null;
  }

  // ------------------------------------------------------------ 数据

  Future<void> _load() async {
    final now = DateTime.now();
    final today = _dayOf(now);
    final state = ref.read(courseProvider);
    final week = state.currentWeek;
    final courses = state.courses;

    List<CourseBlock> blocks = kDefaultCourseBlocks;
    final saved = await CourseStorage.loadTimeBlocks();
    if (saved != null && saved.isNotEmpty) {
      blocks = saved.map((j) => CourseBlock.fromJson(j)).toList();
    }

    final todayCourses = courses
        .where((c) => c.occursOn(now.weekday, week))
        .toList()
      ..sort((a, b) => a.startSlot.compareTo(b.startSlot));

    final all = await TodoRepository.instance.getAll();

    // 逾期：**包含「今天但时刻已过」**——这是上一版漏掉的口子
    // 2026-10-18：重复任务不参与逾期，否则「每天」那类任务天天刷出红条。
    bool isOverdue(Todo t) {
      if (t.isRepeating) return false;
      if (t.completed) return false;
      final d = _dayOf(t.date);
      if (d.isBefore(today)) return true;
      if (d == today && t.dueAt != null && t.dueAt!.isBefore(now)) return true;
      return false;
    }

    final overdue = all.where(isOverdue).toList()
      ..sort((a, b) {
        final ad = a.dueAt ?? a.date;
        final bd = b.dueAt ?? b.date;
        return ad.compareTo(bd);
      });

    // 今天：**按重复规则展开**（occursOn），不是简单的日期相等。
    final todayAll = all.where((t) => t.occursOn(today)).toList();

    // 之后：今天以后、未完成、且不是重复任务。
    // 重复任务不进「之后」——它每天都会出现在「今天」，放这里会重复表达。
    final futureTodos = all
        .where((t) =>
            !t.isRepeating && !t.completed && _dayOf(t.date).isAfter(today))
        .toList()
      ..sort((a, b) {
        final ad = a.dueAt ?? a.date;
        final bd = b.dueAt ?? b.date;
        return ad.compareTo(bd);
      });

    final done = todayAll.where((t) => t.isDoneOn(today)).toList();
    final todayOpen =
        todayAll.where((t) => !t.isDoneOn(today) && !isOverdue(t)).toList()
          ..sort((a, b) {
            final ad = a.dueAt;
            final bd = b.dueAt;
            if (ad == null && bd == null) return a.title.compareTo(b.title);
            if (ad == null) return 1;
            if (bd == null) return -1;
            return ad.compareTo(bd);
          });

    // 考试：**所有未考的**，按时间升序
    final exams = <_ExamItem>[];
    for (final e in await ExamStorage.loadExams()) {
      final raw = (e['date'] as String?)?.trim() ?? '';
      final d = DateTime.tryParse(raw);
      if (d == null) continue;
      final dd = _dayOf(d);
      final name = (e['name'] as String?)?.trim();
      final time = (e['start_time'] as String?)?.trim() ?? '';
      final place = (e['classroom'] as String?)?.trim() ?? '';
      var at = dd;
      final hm = time.split(':');
      if (hm.length >= 2) {
        final h = int.tryParse(hm[0]);
        final m = int.tryParse(hm[1]);
        if (h != null && m != null) {
          at = DateTime(dd.year, dd.month, dd.day, h, m);
        }
      }
      // 已考完的不算（有开始时刻就按时刻，没有就按整天）
      if (at.isBefore(now)) continue;
      exams.add(_ExamItem(
        name: (name == null || name.isEmpty) ? '未命名考试' : name,
        at: at,
        place: place,
      ));
    }
    exams.sort((a, b) => a.at.compareTo(b.at));

    // 接下来：进行中/未开始的课 + 今天有截止的待办 + 最近一场考试
    final items = <_Upcoming>[];

    for (final t in todayOpen) {
      if (t.dueAt == null) continue;
      items.add(_Upcoming(
        kind: _Kind.todo,
        title: t.title,
        when: t.dueAt!,
      ));
    }

    for (final c in todayCourses) {
      final r = _slotRange(blocks, c.startSlot);
      if (r == null) continue;
      final start = DateTime(today.year, today.month, today.day, r.$1, r.$2);
      final end = DateTime(today.year, today.month, today.day, r.$3, r.$4);
      if (end.isBefore(now)) continue; // 已下课的不进「接下来」
      items.add(_Upcoming(
        kind: _Kind.course,
        title: c.name,
        when: start,
        endAt: end,
      ));
    }

    if (exams.isNotEmpty) {
      items.add(_Upcoming(
        kind: _Kind.exam,
        title: exams.first.name,
        when: exams.first.at,
      ));
    }

    items.sort((a, b) => a.when.compareTo(b.when));

    if (!mounted) return;
    setState(() {
      _upcoming = items.take(3).toList();
      _todayTodos = todayOpen;
      _doneTodos = done;
      _overdueTodos = overdue;
      _futureTodos = futureTodos;
      _loadedDay = today;
      _exams = exams;
      _todayCourseCount = todayCourses.length;
      _loading = false;
    });
  }

  // ------------------------------------------------------------ 操作

  Future<void> _addTodo() async {
    final todo = await AddTodoDialog.show(context);
    if (todo == null) return;
    await TodoRepository.instance.add(todo);
    await _load();
  }

  Future<void> _toggle(Todo t) async {
    // 2026-10-18：重复任务只翻转「今天」这一次，不动其它日期。
    await TodoRepository.instance.toggleCompleteOn(t, DateTime.now());
    await _load();
  }

  Future<void> _openDetail(Todo t) async {
    final action = await TodoDetailDialog.show(context, t);
    if (action == null) return;
    if (action == 'toggle') {
      await TodoRepository.instance.toggleCompleteOn(t, DateTime.now());
    } else if (action == 'delete') {
      await TodoRepository.instance.delete(t);
    }
    await _load();
  }

  // ------------------------------------------------------------ UI

  static const Color _red = Color(0xFFB91C1C);
  static const Color _redBorder = Color(0xFFF3C6C6);

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 6) return '夜深了';
    if (h < 11) return '上午好';
    if (h < 14) return '中午好';
    if (h < 18) return '下午好';
    return '晚上好';
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  Color get _faint =>
      _isDark ? const Color(0xFF8B8B8B) : const Color(0xFF9CA3AF);

  Color get _line =>
      _isDark ? const Color(0xFF2C2C2C) : const Color(0xFFEDEEF1);

  /// 卡片：内部**纯白**（用户要求：除「添加待办」外都改亮白）。
  Widget _card({required Widget child, Color? bg, Color? border}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: bg ?? (_isDark ? const Color(0xFF1C1C1E) : Colors.white),
        border: Border.all(color: border ?? _line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  /// 概览小卡：只有「数字 + 标签」，垂直内边距 10 —— 整卡约 62dp，刻意压扁
  ///（用户要求「卡片上下高度不过高」）。
  Widget _statCard(String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: _isDark ? const Color(0xFF1C1C1E) : Colors.white,
          border: Border.all(color: _line),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              maxLines: 1,
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w600, height: 1.1),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              style: TextStyle(fontSize: 11, color: _faint),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, {Color? color, Widget? trailing}) {
    return Row(
      children: [
        Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: color ??
                (_isDark ? const Color(0xFFD4D4D8) : const Color(0xFF374151)),
          ),
        ),
        const Spacer(),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _upcomingRow(_Upcoming u, DateTime now) {
    final icon = switch (u.kind) {
      _Kind.course => Icons.menu_book_outlined,
      _Kind.exam => Icons.assignment_outlined,
      _Kind.todo => Icons.check_circle_outline,
    };

    // 倒计时**每帧重算**（存在 _Upcoming 里的只有基准时刻），这样每秒都会跳动
    late final String trailing;
    late final bool urgent;
    if (u.kind == _Kind.course) {
      final ongoing = !u.when.isAfter(now);
      if (ongoing) {
        trailing = '进行中 · 剩 ${_countdown(u.endAt ?? u.when, now)}';
        urgent = true;
      } else {
        trailing = '${_hm(u.when)} · ${_countdown(u.when, now)}后';
        urgent = u.when.difference(now).inHours < 2;
      }
    } else if (u.kind == _Kind.exam) {
      trailing = '距 ${_countdown(u.when, now)}';
      urgent = false;
    } else {
      trailing = '今天 ${_hm(u.when)} 截止';
      urgent = u.when.difference(now).inHours < 24;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(icon,
              size: 15,
              color: u.kind == _Kind.exam
                  ? _red
                  : (_isDark ? const Color(0xFF8B8B8B) : const Color(0xFF6B7280))),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              u.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            trailing,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: urgent ? FontWeight.w600 : FontWeight.w400,
              color: urgent ? _red : _faint,
            ),
          ),
        ],
      ),
    );
  }

  /// 待办行。2026-10-18 用户要求：
  ///   · **整行点击直接勾选/取消**，不再弹详情；
  ///   · 有内容（description 非空）的，在**名称后面**加一个小图标，点图标才进居中详情盒。
  Widget _todoRow(Todo t, {bool dim = false}) {
    final hasNote = (t.description ?? '').trim().isNotEmpty;
    final today0 = _dayOf(DateTime.now());
    final d = _dayOf(t.date);
    // 重复任务的 date 是「起始日」，可能早于今天，所以用 occursOn 判断是否属于今天。
    final isToday = t.occursOn(today0);
    // 完成态也要按「今天这一次」判断（重复任务每天独立）。
    final done = t.isDoneOn(today0);
    final hot = isToday && !dim;

    return GestureDetector(
      onTap: () => _toggle(t),
      // 长按进详情：没有内容的待办没有小图标，否则就再也没有删除入口了。
      onLongPress: () => _openDetail(t),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            // 勾选框只作视觉指示（点击交给整行），用 IgnorePointer 避免抢手势。
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 6, 8),
              child: IgnorePointer(
                child: Container(
                  width: 17,
                  height: 17,
                  decoration: BoxDecoration(
                    color: done ? AppTheme.primaryColor : Colors.transparent,
                    border: Border.all(
                      color: done ? AppTheme.primaryColor : _redBorder,
                      width: 1.5,
                    ),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: done
                      ? const Icon(Icons.check_rounded,
                          size: 12, color: Colors.white)
                      : null,
                ),
              ),
            ),
            Expanded(
              child: Padding(
                // 行高：垂直 10 + 文字 ≈ 40dp，比原来的 4 更好点。
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              t.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                color: done ? _faint : null,
                                decoration:
                                    done ? TextDecoration.lineThrough : null,
                              ),
                            ),
                          ),
                          // 重复标记（每天 / 每周几），让人一眼看出这条会反复出现。
                          if (t.isRepeating) ...[
                            const SizedBox(width: 4),
                            Icon(Icons.repeat_rounded, size: 13, color: _faint),
                          ],
                          if (hasNote) ...[
                            const SizedBox(width: 5),
                            GestureDetector(
                              onTap: () => _openDetail(t),
                              behavior: HitTestBehavior.opaque,
                              child: Padding(
                                padding: const EdgeInsets.all(3),
                                child: Icon(Icons.notes_rounded,
                                    size: 14, color: _faint),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // 倒计时 / 日期：只有「今天的未完成」用红色（紧急），其余灰色。
                    const SizedBox(width: 8),
                    Text(
                      isToday
                          ? _countdown(t.dueAt ?? t.date, DateTime.now())
                          : '${d.difference(today0).inDays} 天后 · ${d.month}月${d.day}日',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: hot ? FontWeight.w600 : FontWeight.w400,
                        color: hot ? _red : _faint,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _hm(t.dueAt ?? t.date),
                      style: TextStyle(fontSize: 11.5, color: _faint),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final weekdayLabel =
        const ['一', '二', '三', '四', '五', '六', '日'][now.weekday - 1];

    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.only(top: 60),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 2, 2, 10),
            child: Row(
              children: [
                Text(
                  '${now.month}月${now.day}日 周$weekdayLabel',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(_greeting,
                    style: TextStyle(fontSize: 12.5, color: _faint)),
              ],
            ),
          ),

          // 添加待办（**唯一保持虚色的框**）
          GestureDetector(
            onTap: _addTodo,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              decoration: BoxDecoration(
                // 2026-10-18 用户要求：「添加待办」改成白色（与其他卡片同底）。
                color: _isDark ? const Color(0xFF1C1C1E) : Colors.white,
                border: Border.all(color: _line),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(Icons.add_rounded,
                      size: 18,
                      color: _isDark
                          ? const Color(0xFFD4D4D8)
                          : const Color(0xFF3F3F46)),
                  const SizedBox(width: 8),
                  // 2026-10-18 用户要求：「添加待办」文字改深灰色（原为 _faint 浅灰）。
                  Text('添加待办',
                      style: TextStyle(
                          fontSize: 14,
                          color: _isDark
                              ? const Color(0xFFD4D4D8)
                              : const Color(0xFF3F3F46))),
                ],
              ),
            ),
          ),

          // 概览三卡（2026-10-18 用户要求：从原来的「一行文字」改成三张卡片，
          // 位置移到添加待办下方；高度刻意压扁，只放「数字 + 标签」。）
          const SizedBox(height: 10),
          Row(
            children: [
              _statCard('$_todayCourseCount', '今日课节'),
              const SizedBox(width: 8),
              _statCard(
                  '${_doneTodos.length}/${_doneTodos.length + _todayTodos.length}',
                  '待办完成'),
              const SizedBox(width: 8),
              _statCard('${_exams.length}', '待考'),
            ],
          ),
          const SizedBox(height: 12),

          // 接下来
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionTitle('接下来'),
                const SizedBox(height: 4),
                if (_upcoming.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text('今天没有要紧的事',
                        style: TextStyle(fontSize: 13, color: _faint)),
                  )
                else
                  ..._upcoming.map((u) => _upcomingRow(u, now)),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 考试：倒计时 + 全部待考
          if (_exams.isNotEmpty) ...[
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionTitle('考试 · 待考 ${_exams.length} 场'),
                  const SizedBox(height: 8),
                  // 最近一场：大倒计时
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Text(
                          _exams.first.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(
                        _countdown(_exams.first.at, now),
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: _red,
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      '${_exams.first.at.month}月${_exams.first.at.day}日'
                      ' ${_hm(_exams.first.at)}'
                      '${_exams.first.place.isEmpty ? '' : ' · ${_exams.first.place}'}',
                      style: TextStyle(fontSize: 12, color: _faint),
                    ),
                  ),
                  if (_exams.length > 1) ...[
                    Divider(height: 20, color: _line),
                    for (final e in _exams.skip(1))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                e.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13.5),
                              ),
                            ),
                            Text(
                              '${e.at.month}月${e.at.day}日',
                              style: TextStyle(fontSize: 11.5, color: _faint),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              _countdown(e.at, now),
                              style: const TextStyle(
                                  fontSize: 11.5,
                                  color: _red,
                                  fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],

          // 逾期
          if (_overdueTodos.isNotEmpty) ...[
            _card(
              border: _redBorder,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionTitle(
                    '逾期 · ${_overdueTodos.length}',
                    color: _red,
                    // 折叠状态改为持久化（原来只有内存里的 _showOverdue）。
                    trailing: InkWell(
                      onTap: () => HomePrefs.setSectionOpen(
                          HomePrefs.secIdOverdue, !HomePrefs.secOverdue),
                      child: Icon(
                        HomePrefs.secOverdue
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: _faint,
                      ),
                    ),
                  ),
                  if (HomePrefs.secOverdue)
                    for (final t in _overdueTodos)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          children: [
                            GestureDetector(
                              onTap: () => _toggle(t),
                              behavior: HitTestBehavior.opaque,
                              child: Container(
                                width: 17,
                                height: 17,
                                margin: const EdgeInsets.only(right: 10),
                                decoration: BoxDecoration(
                                  border:
                                      Border.all(color: _redBorder, width: 1.5),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                              ),
                            ),
                            Expanded(
                              child: InkWell(
                                // 点击直接勾选完成；长按进详情（逾期行没有小图标）。
                                onTap: () => _toggle(t),
                                onLongPress: () => _openDetail(t),
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          t.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 14),
                                        ),
                                      ),
                                      if ((t.description ?? '')
                                          .trim()
                                          .isNotEmpty) ...[
                                        const SizedBox(width: 5),
                                        GestureDetector(
                                          onTap: () => _openDetail(t),
                                          behavior: HitTestBehavior.opaque,
                                          child: Padding(
                                            padding: const EdgeInsets.all(3),
                                            child: Icon(Icons.notes_rounded,
                                                size: 14, color: _faint),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            Text(
                              () {
                                final diff =
                                    _dayOf(now).difference(_dayOf(t.date)).inDays;
                                if (diff > 0) return '逾期 $diff 天';
                                return '已过 ${_hm(t.dueAt ?? t.date)}';
                              }(),
                              style: const TextStyle(
                                  fontSize: 11.5,
                                  color: _red,
                                  fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],

          // 今天
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionTitle(
                  '今天 · ${_todayTodos.length}',
                  // 2026-10-18 用户要求：待办板块可折叠 + 记忆状态（HomePrefs 落盘）。
                  trailing: InkWell(
                    onTap: () => HomePrefs.setSectionOpen(
                        HomePrefs.secIdToday, !HomePrefs.secToday),
                    child: Icon(
                      HomePrefs.secToday
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: _faint,
                    ),
                  ),
                ),
                if (HomePrefs.secToday) ...[
                  const SizedBox(height: 2),
                  if (_todayTodos.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text('今天没有待办',
                          style: TextStyle(fontSize: 13, color: _faint)),
                    )
                  else
                    for (final t in _todayTodos) _todoRow(t),
                  if (_doneTodos.isNotEmpty) ...[
                    Divider(height: 20, color: _line),
                    InkWell(
                      onTap: () => setState(() => _showDone = !_showDone),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Text('已完成 ${_doneTodos.length} 项',
                                style:
                                    TextStyle(fontSize: 12.5, color: _faint)),
                            const Spacer(),
                            Icon(
                              _showDone
                                  ? Icons.keyboard_arrow_up_rounded
                                  : Icons.keyboard_arrow_right_rounded,
                              size: 18,
                              color: _faint,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_showDone)
                      for (final t in _doneTodos) _todoRow(t, dim: true),
                  ],
                ],
              ],
            ),
          ),

          // 之后（今天以后）——修「给别的日子建的待办建完就消失」
          if (_futureTodos.isNotEmpty) ...[
            const SizedBox(height: 10),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionTitle(
                    '之后 · ${_futureTodos.length}',
                    trailing: InkWell(
                      onTap: () => HomePrefs.setSectionOpen(
                          HomePrefs.secIdFuture, !HomePrefs.secFuture),
                      child: Icon(
                        HomePrefs.secFuture
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: _faint,
                      ),
                    ),
                  ),
                  if (HomePrefs.secFuture) ...[
                    const SizedBox(height: 2),
                    for (final t in _futureTodos) _todoRow(t),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
