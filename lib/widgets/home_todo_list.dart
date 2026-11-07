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

  /// 切换动画期间收到过数据更新 → 结束后要补一次 `_applyDiff`。
  ///
  /// 🔴 2026-11-03 修「任务列表不更新」：没有这个标记时，动画期间到达的
  /// 同一天增删改会被整段丢弃（日期没变，切完也没人补账）。
  bool _pendingSync = false;

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
      // 🔴 2026-11-03 修「任务列表不更新」：切换动画进行中收到的更新**不能只记日期**。
      //
      // 原来这里只 `_pendingDate = widget.date; return;`，问题有两个：
      //   1. 同一天的待办增删改（勾选、新增、删除）被整段丢弃 ——
      //      日期没变，所以切换结束后也没人再补一次 `_applyDiff`，
      //      列表就停在旧内容上，用户怎么点都不动。
      //   2. 只要 `_switching` 卡住（见 `_enterInitial` /`_switchDay` 的
      //      finally 注释），这个分支就永远不会再走到 `_applyDiff`。
      // 现在用一个脏标记，等切换结束统一补一次。
      _pendingDate = widget.date;
      _pendingSync = true;
      return;
    }
    _applyWidgetUpdate(oldWidget);
  }

  /// 把「父级传来新数据」这件事真正落到列表上。
  ///
  /// 抽出来是因为它在两个地方要用：`didUpdateWidget`（正常路径）
  /// 和切换动画结束后补账（`_pendingSync` 路径）。
  void _applyWidgetUpdate(covariant HomeTodoList oldWidget) {
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
    // 🔴 2026-11-03 修「任务列表不更新」：`_switching` 必须用 finally 复位。
    //
    // 原来只在函数末尾 `_switching = false`，但中间有三处 `return`
    // （挂载丢失 / 代数过期 / `_insertAt` 返回 false）。任意一处提前返回，
    // `_switching` 就**永久卡在 true** —— 之后 `didUpdateWidget` 每次进来
    // 都走 `if (_switching) { _pendingDate = widget.date; return; }`，
    // 父级传什么都进不了 `_applyDiff()`，列表从此再也不刷新。
    // 用户的体感就是「待办改了、数据也变了，但列表一直不动」。
    try {
      // 等 AnimatedList 真正挂载，否则 insertItem 会被丢弃（列表空白）。
      await _waitForList();
      for (var i = 0; i < widget.todos.length; i++) {
        if (!mounted || gen != _generation) return;
        if (!await _insertAt(i, widget.todos[i])) return;
        await Future<void>.delayed(const Duration(milliseconds: 55));
      }
    } finally {
      // 只有代数没被更新的那次调用才有资格解锁，避免旧协程
      // 把新协程正在进行的切换提前放开。
      if (gen == _generation) {
        _switching = false;
        // 🔴 2026-11-03：入场动画期间到达的「换一天」也必须补切。
        //   原来这里只 `_switching = false` 就结束 —— `didUpdateWidget`
        //   在 `_switching` 为 true 时只把日期记进 `_pendingDate`，
        //   而 `_enterInitial` 从不消费它 → 用户入场动画那 200ms 内点了
        //   「明天」，列表就永远停在今天的内容上（点几次都不动）。
        final pending = _pendingDate;
        _pendingDate = null;
        if (pending != null && !_sameDay(pending, widget.date)) {
          _slideDir = widget.date.isAfter(pending) ? 1 : -1;
          _switchDay();
        } else if (pending != null) {
          _flushPendingSync();
        }
      }
    }
  }

  /// 切换动画结束后补上动画期间错过的数据更新。
  void _flushPendingSync() {
    if (!_pendingSync || !mounted) return;
    _pendingSync = false;
    // 此刻 widget 已是最新数据，拿它自己当 oldWidget 的基准不可行
    // （拿不到上一帧的值），所以直接整体重算：日期若变了就走切日，
    // 否则按 id 对齐 `_items`。
    final sameCount = _items.length == widget.todos.length;
    final sameOrder = sameCount &&
        List.generate(_items.length, (i) => _items[i].id == widget.todos[i].id)
            .every((x) => x);
    if (sameOrder) {
      // 顺序没变：只同步内容（完成态 / 优先级 / 标题）。
      for (var i = 0; i < widget.todos.length; i++) {
        _items[i] = widget.todos[i];
      }
      setState(() {});
      return;
    }
    _applyDiff();
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
    // 🔴 2026-11-03 修「任务列表不更新」：与 `_enterInitial` 同一个坑 ——
    // 函数里三处 `return` 会在 `_switching = false` 之前跑掉，
    // 只要切换日期的过程中用户又点了别的（或者某次 insert 失败），
    // `_switching` 就永久 true，`didUpdateWidget` 全部被挡在门外。
    try {
      // 旧项从尾部开始逐个模糊收起。
      await _waitForList();
      for (var i = _items.length - 1; i >= 0; i--) {
        if (!mounted || gen != _generation) return;
        final removed = _items.removeAt(i);
        _key.currentState?.removeItem(
          i,
          (context, animation) =>
              _item(removed, animation, removing: true, index: i),
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
    } finally {
      if (gen == _generation) {
        _switching = false;
        final pending = _pendingDate;
        _pendingDate = null;
        if (pending != null && !_sameDay(pending, widget.date)) {
          _slideDir = widget.date.isAfter(pending) ? 1 : -1;
          _switchDay();
        } else {
          _flushPendingSync();
        }
      }
    }
  }

  void _applyDiff() {
    final oldIds = _items.map((e) => e.id).toSet();
    final newIds = widget.todos.map((e) => e.id).toSet();

    // 同一条待办内容变化：原地替换数据，不重新插入。
    //
    // 🔴 原来只在「完成态 / 优先级 / 标题」三者变化时才替换，于是编辑只改
    // 提醒时间或描述后卡片仍显旧时刻（要切一天再切回来才刷新）。
    // 换成「对象不同就替换」——identical 比字段比较便宜，也不会漏。
    for (var i = 0; i < _items.length; i++) {
      final match = widget.todos.where((t) => t.id == _items[i].id);
      if (match.isEmpty) continue;
      final next = match.first;
      if (!identical(next, _items[i])) {
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

    // 最后重排：只处理「同一批 id、顺序变了」这种纯置换
    // （切换排序方式 / 改优先级 / 改提醒时间都会改变 `_sortTodos` 的结果）。
    //
    // 🔴 不做这一步的表现是：点「排序方式」完全没反应 —— 增删两段循环
    //    都会被 oldIds/newIds 挡住，`_items` 顺序纹丝不动，而 key 是
    //    `ValueKey(_dataDay)`、日期没变所以 State 也不会重建。
    //
    // ⚠️ 只在**纯置换**时这么做：一旦同时有增删，AnimatedList 正在按
    //    `insertItem(at)` 记录的索引播放入场动画，此刻再动 `_items` 会让
    //    itemBuilder 取到错的元素（动画里的那格变成别人）。增删场景交给
    //    上面两段循环，顺序差一格可以等下一帧。
    if (oldIds.length == newIds.length && oldIds.every(newIds.contains)) {
      final wantOrder = widget.todos.map((e) => e.id).toList();
      final haveOrder = _items.map((e) => e.id).toList();
      if (!_sameOrder(haveOrder, wantOrder)) {
        final byId = {for (final t in _items) t.id: t};
        _items
          ..clear()
          ..addAll([for (final id in wantOrder) if (byId[id] != null) byId[id]!]);
      }
    }
  }

  static bool _sameOrder(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
        // 2026-11-03：样式交给全局 snackBarTheme，只留时长。
        SnackBar(
          content: Text(msg),
          duration: const Duration(milliseconds: 1600),
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
