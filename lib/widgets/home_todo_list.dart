import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/todo.dart';
import '../pages/home/home_widgets.dart';
import '../services/ui_prefs.dart';
import '../theme/app_theme.dart';
import 'empty_todo_art.dart';

/// 首页待办列表：负责增删、切日期的过渡动画。
///
/// - 插入到任意位置：AnimatedList 自己让相邻项让位，新项模糊放大进入；
/// - 删除：相邻项收拢合并；
/// - 切换日期：旧待办逐个模糊收起，新待办再逐个模糊出现；
/// - 首次进入：逐个模糊出现。
class HomeTodoList extends StatefulWidget {
  const HomeTodoList({
    super.key,
    required this.todos,
    required this.date,
    required this.restPhrase,
    this.refreshTick = 0,
    required this.onToggle,
    required this.onDelete,
    required this.onEdit,
  });

  final List<Todo> todos;
  final DateTime date;
  final String restPhrase;

  /// 切回首页时 +1：触发一次轻柔的整体重入场（模糊淡入），不删不插。
  final int refreshTick;
  final void Function(Todo) onToggle;
  final void Function(Todo) onDelete;
  final void Function(Todo) onEdit;

  @override
  State<HomeTodoList> createState() => _HomeTodoListState();
}

class _HomeTodoListState extends State<HomeTodoList>
    // ⚠️ 必须是 TickerProviderStateMixin（不是 Single）：
    //    本类有**两个** AnimationController（_shake 震动 / _refreshCtrl 重入场），
    //    SingleTickerProviderStateMixin 只允许一个 → 运行时抛
    //    「multiple tickers were created」→ 待办列表整块报错。
    with TickerProviderStateMixin {
  final GlobalKey<AnimatedListState> _key = GlobalKey<AnimatedListState>();

  /// 未完成任务的「震动一下」提示。
  late final AnimationController _shake;
  final List<Todo> _items = <Todo>[];
  int _generation = 0;
  bool _ready = false;
  bool _switching = false;
  int _slideDir = 1;
  bool _showAllDoneArt = false;
  DateTime? _pendingDate;

  /// 重入场动画（切回首页时播放一次）。
  late final AnimationController _refreshCtrl;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _refreshCtrl = AnimationController(
      vsync: this,
      duration: UiPrefs.dur(const Duration(milliseconds: 420)),
      value: 1,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _enterInitial());
  }

  @override
  void dispose() {
    _shake.dispose();
    _refreshCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant HomeTodoList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready) return;
    if (_switching) {
      _pendingDate = widget.date;
      return;
    }
    if (!_sameDay(oldWidget.date, widget.date)) {
      _slideDir = widget.date.isAfter(oldWidget.date) ? 1 : -1;
    }
    // 手绘「今日已完成」的出现/收回规则：
    //   · **只在用户点底部按钮、且确实全部完成时出现**（不自动弹）；
    //   · 新增待办 / 取消完成 → 收回手绘，回到待办列表。
    // 🔴 按**这一天**判定完成态：完成态按天归属，读裸 `completed`
    //    会把「另一天的完成」显示成今天已完成。
    final nowAllDone = widget.todos.isNotEmpty &&
        widget.todos.every((t) => t.isDoneOn(widget.date));
    final grew = widget.todos.length > oldWidget.todos.length;
    if (_showAllDoneArt && (grew || !nowAllDone)) {
      _showAllDoneArt = false;
    }
    if (oldWidget.refreshTick != widget.refreshTick) {
      // 切回首页：整体柔和重入场（不删不插，避免列表跳变）。
      _refreshCtrl.forward(from: 0);
    }
    if (!_sameDay(oldWidget.date, widget.date) ||
        (oldWidget.todos.isEmpty && widget.todos.isNotEmpty)) {
      _switchDay();
      return;
    }
    _applyDiff();
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _enterInitial() async {
    if (!mounted) return;
    _ready = true;
    _switching = true;
    final gen = ++_generation;
    // 等 AnimatedList 真正挂载，否则 insertItem 会被丢弃（列表空白）。
    await _waitForList();
    for (var i = 0; i < widget.todos.length; i++) {
      if (!mounted || gen != _generation) return;
      if (!await _insertAt(i, widget.todos[i])) return;
      await Future<void>.delayed(const Duration(milliseconds: 55));
    }
    _switching = false;
  }

  /// 等待 AnimatedList 的 State 就绪（最多约 10 帧）。
  Future<bool> _waitForList() async {
    for (var i = 0; i < 10; i++) {
      if (!mounted) return false;
      if (_key.currentState != null) return true;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    return _key.currentState != null;
  }

  /// 插入一条待办：**先确认列表可用**，再改 _items，保证两者计数始终一致。
  Future<bool> _insertAt(int index, Todo todo) async {
    if (!await _waitForList()) return false;
    final listState = _key.currentState;
    if (listState == null) return false;
    setState(() => _items.insert(index, todo));
    listState.insertItem(index, duration: const Duration(milliseconds: 280));
    return true;
  }

  Future<void> _switchDay() async {
    _switching = true;
    _showAllDoneArt = false;
    final gen = ++_generation;
    // 旧项从尾部开始逐个模糊收起。
    await _waitForList();
    for (var i = _items.length - 1; i >= 0; i--) {
      if (!mounted || gen != _generation) return;
      final removed = _items.removeAt(i);
      _key.currentState?.removeItem(
        i,
        (context, animation) => _item(removed, animation, removing: true, index: i),
        duration: UiPrefs.dur(const Duration(milliseconds: 180)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 45));
    }
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted || gen != _generation) return;
    _items.clear();
    await _waitForList();
    for (var i = 0; i < widget.todos.length; i++) {
      if (!mounted || gen != _generation) return;
      if (!await _insertAt(i, widget.todos[i])) return;
      await Future<void>.delayed(const Duration(milliseconds: 55));
    }
    _switching = false;
    final pending = _pendingDate;
    _pendingDate = null;
    if (pending != null && !_sameDay(pending, widget.date)) {
      _slideDir = widget.date.isAfter(pending) ? 1 : -1;
      _switchDay();
    }
  }

  void _applyDiff() {
    final oldIds = _items.map((e) => e.id).toSet();
    final newIds = widget.todos.map((e) => e.id).toSet();

    // 同一条待办完成态变化：原地替换数据，不重新插入。
    for (var i = 0; i < _items.length; i++) {
      final match = widget.todos.where((t) => t.id == _items[i].id);
      if (match.isEmpty) continue;
      final next = match.first;
      if (next.isDoneOn(widget.date) != _items[i].isDoneOn(widget.date) ||
          next.priority != _items[i].priority ||
          next.title != _items[i].title) {
        _items[i] = next;
      }
    }
    // 当前在 didUpdateWidget 阶段，不能 setState；更新 _items 后
    // 本次父级 build 会重新读取新数据（完成态/优先级变化）。

    // 先删：从后往前，保持索引稳定。
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      if (newIds.contains(item.id)) continue;
      _items.removeAt(i);
      _key.currentState?.removeItem(
        i,
        (context, animation) => _item(item, animation, removing: true, index: i),
        duration: UiPrefs.dur(const Duration(milliseconds: 220)),
      );
    }

    // 再插：按目标列表顺序找位置，相邻项由 AnimatedList 自动让位。
    for (var i = 0; i < widget.todos.length; i++) {
      final target = widget.todos[i];
      if (oldIds.contains(target.id)) continue;
      final at = i.clamp(0, _items.length);
      final listState = _key.currentState;
      if (listState == null) {
        // 列表还没挂载：直接记入 _items，等列表就绪后由 _enterInitial 补齐。
        _items.insert(at, target);
        continue;
      }
      _items.insert(at, target);
      listState.insertItem(at, duration: const Duration(milliseconds: 300));
    }
  }

  Widget _item(
    Todo todo,
    Animation<double> animation, {
    bool removing = false,
    required int index,
  }) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return AnimatedSize(
      duration: UiPrefs.dur(const Duration(milliseconds: 240)),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedBuilder(
        animation: curved,
        builder: (_, child) {
          final dx =
              (removing ? -1 : 1) * _slideDir * (1 - curved.value) * 0.10;
          return FractionalTranslation(
            translation: Offset(dx, 0),
            child: child,
          );
        },
        child: SizeTransition(
          sizeFactor: curved,
          axisAlignment: -1,
          child: AnimatedBuilder(
            animation: curved,
            builder: (_, child) {
              final v = removing ? 1 - curved.value : curved.value;
              // 淡入淡出即可：模糊会让整块文字反复重绘，观感很怪。
              return Opacity(opacity: v.clamp(0.0, 1.0), child: child);
            },
            child: AnimatedBuilder(
              animation: _shake,
              builder: (_, child) {
                if (todo.isDoneOn(widget.date) || !_shake.isAnimating) {
                  return child!;
                }
                final t = _shake.value;
                final dx = math.sin(t * math.pi * 6) * 7 * (1 - t);
                return Transform.translate(
                    offset: Offset(dx, 0), child: child);
              },
              child: TodoTimelineItem(
                key: ValueKey(todo.id),
                todo: todo,
                date: widget.date,
                compact: todo.isDoneOn(widget.date),
                isFirst: index == 0,
                isLast: index == _items.length - 1,
                onToggle: () => widget.onToggle(todo),
                onDelete: () => widget.onDelete(todo),
                onEdit: () => widget.onEdit(todo),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 底部按钮：点一下检查今天是否全部完成。
  void _onCheckAllDone() {
    if (_showAllDoneArt) {
      setState(() => _showAllDoneArt = false);
      return;
    }
    if (widget.todos.isEmpty) {
      _toast('今天还没有待办哦');
      return;
    }
    final allDone = widget.todos.every((t) => t.isDoneOn(widget.date));
    if (allDone) {
      setState(() => _showAllDoneArt = true);
      return;
    }
    _shake.forward(from: 0);
    _toast('还有任务未完成');
  }

  void _toast(String msg) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 1600),
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 80),
        ),
      );
  }

  /// 空状态：**恢复原本的「勾选圈 + 星光」手绘**。
  ///
  /// ⚠️ 这里刻意不用通用的 [AppEmptyState]：
  ///    待办空状态是首页出现频率最高的插画，原来那枚「勾选圈 + 三道星光」
  ///    是全 App 手绘里最好看的一枚，换成通用插画后观感明显退步。
  Widget _artBlock(String title, String subtitle) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 4),
          EmptyTodoArt(
            size: 76,
            color: isDark
                ? const Color(0xFF8B8B8B)
                : const Color(0xFFB8BFC9),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            style: TextStyle(
              fontFamily: 'serif',
              fontSize: 19,
              fontWeight: FontWeight.w600,
              color: context.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              fontFamily: 'serif',
              fontSize: AppTheme.fontSmall,
              color: context.textTertiary,
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEmpty = widget.todos.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_showAllDoneArt)
          _artBlock('今日待办已完成', widget.restPhrase)
        else if (isEmpty)
          _artBlock('今日没有待办！', '玩去吧！'),
        // ⚠️ AnimatedList 必须**常驻树内**（不可见时用 Visibility 隐藏）。
        // 之前「无待办/手绘态」时整棵列表被移除 → insertItem 找不到 state，
        // 数据到了也插不进去 → 切回该日期时待办列表一片空白。
        Visibility(
          visible: !_showAllDoneArt && !isEmpty,
          maintainState: true,
          child: AnimatedBuilder(
            animation: _refreshCtrl,
            builder: (context, child) {
              final v = _refreshCtrl.value;
              if (v >= 1) return child!;
              // 只做透明度 + 轻微位移；**不用模糊**（整块文字重绘会闪）。
              return Opacity(
                opacity: 0.45 + 0.55 * v,
                child: Transform.translate(
                  offset: Offset(0, 8 * (1 - v)),
                  child: child,
                ),
              );
            },
            child: AnimatedList(
            key: _key,
            initialItemCount: 0,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemBuilder: (context, index, animation) {
              if (index >= _items.length) return const SizedBox.shrink();
              return _item(_items[index], animation, index: index);
            },
            ),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: _onCheckAllDone,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.primaryColor,
            side: BorderSide(color: context.borderColor),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            minimumSize: const Size(0, 38),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
          ),
          child: Text(
            _showAllDoneArt ? '不对，我作业还没写完' : '你今天的任务都完成了吗？',
            style: const TextStyle(fontSize: AppTheme.fontSmall),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
