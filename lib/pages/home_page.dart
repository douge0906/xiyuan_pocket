import 'dart:async';
import 'package:flutter/material.dart';
import 'home/home_widgets.dart';
import 'home/home_cards.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/todo.dart';
import '../repositories/todo_repository.dart';
import '../providers/course_provider.dart';
import '../services/course_todo_service.dart';
import '../services/exam_storage.dart';
import '../services/notification_service.dart';
import '../services/campus_net_service.dart';
import '../theme/app_theme.dart';

import 'add_todo_sheet.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  HomePageState createState() => HomePageState();
}

class HomePageState extends ConsumerState<HomePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late DateTime _selectedDate;
  List<Todo> _todos = [];
  final ScrollController _dateScroll = ScrollController();

  // ---------------- 教程锚点（v2.4.0 指向性提示）----------------
  final GlobalKey _kDateStrip = GlobalKey();
  final GlobalKey _kOverview = GlobalKey();
  final GlobalKey _kAddTodo = GlobalKey();

  // 今日概览
  int _todayCourseCount = 0;
  int _todayTodoTotal = 0;
  int _todayTodoDone = 0;
  ExamCountdown? _nextExam;
  bool _overviewLoaded = false;
  /// 校园网状态：优先取服务内静态缓存（Tab 切走再切回时 State 重建，
  /// 用上次结果直显而不重新探测），冷启动无缓存则显示「检测中」。
  CampusNetStatus _campusNetStatus =
      CampusNetService.lastStatus ?? CampusNetStatus.unknown;
  bool _campusDetecting = false; // 避免并发重测
  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime.now();
    _load();
    _rescheduleAll();
    _loadOverview();
    _initCampusNet();
    // 监听「点击通知」事件：payload 为被点待办的 id，定位到对应日期并高亮。
    NotificationService.pendingTodoId.addListener(_handleNotificationTap);
    // 监听 App 生命周期：回到前台时隐式重测校园网状态。
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToSelected();
      // 冷启动若由通知拉起，此时 pendingTodoId 可能已有值，主动消费一次。
      _handleNotificationTap();
    });
  }

  /// 处理通知点击：根据 payload（Todo id）跳转到该待办所在日期。
  Future<void> _handleNotificationTap() async {
    final todoId = NotificationService.pendingTodoId.value;
    if (todoId == null || todoId.isEmpty) return;
    // 消费后立即清空，避免重复触发。
    NotificationService.pendingTodoId.value = null;
    final all = await TodoRepository.instance.getAll();
    final matches = all.where((t) => t.id == todoId);
    if (matches.isEmpty || !mounted) return;
    final target = matches.first;
    setState(() => _selectedDate = target.date);
    await _load();
    _loadOverview();
    if (mounted) _scrollToSelected();
  }

  /// 计算今日概览：今天上课门数 + 最近一场考试倒计时。
  Future<void> _loadOverview() async {
      // 课表取自 courseProvider（应用内唯一数据源）——
      // 别的页面改了课表，这里会通过下面的 ref.listen 自动重算
      final courseState = ref.read(courseProvider);
      final now = DateTime.now();
      final week = courseState.currentWeek;
      final todayWeekday = now.weekday;
      final count = courseState.courses
          .where((c) => c.occursOn(todayWeekday, week))
        .length;
    final exam = await ExamStorage.nextExam();
    final allTodos = await TodoRepository.instance.getAll();
    final todayTodos = allTodos.where((t) => _sameDay(t.date, now)).toList();
    final done = todayTodos.where((t) => t.completed).length;
    if (!mounted) return;
    setState(() {
      _todayCourseCount = count;
      _nextExam = exam;
      _todayTodoTotal = todayTodos.length;
      _todayTodoDone = done;
      _overviewLoaded = true;
    });
  }

  @override
  void dispose() {
    NotificationService.pendingTodoId.removeListener(_handleNotificationTap);
    WidgetsBinding.instance.removeObserver(this);
    _dateScroll.dispose();
    super.dispose();
  }

  void _scrollToSelected() {
    if (!_dateScroll.hasClients) return;
    final selIndex = _selectedDate.weekday - 1; // 周一=0
    const itemWidth = 68.0; // 56 宽度 + 左右各 6 边距
    final vp = _dateScroll.position.viewportDimension;
    final offset = (selIndex * itemWidth) - (vp - itemWidth) / 2;
    _dateScroll.animateTo(
      offset.clamp(0.0, _dateScroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
    );
  }

  /// 启动时重新排程所有未来提醒：Android 会在重启/强制停止后清除定时通知，
  /// 在 APP 打开时补排一次（由仓库统一完成，幂等安全）。
  Future<void> _rescheduleAll() async {
    await TodoRepository.instance.rescheduleAll();
  }

  Future<void> _toggleTodo(Todo todo) async {
    final willComplete = !todo.completed;
    // 乐观 UI：立刻更新本地状态，不等存储写入
    setState(() {
      final idx = _todos.indexWhere((t) => t.id == todo.id);
      if (idx >= 0) _todos[idx] = _todos[idx].copyWith(completed: willComplete);
    });
    // 落库 + 通知（完成即取消 / 未完成且未来则重排）全部交由仓库编排
    await TodoRepository.instance.toggleComplete(todo);
    _loadOverview();
  }

  Future<void> _load() async {
    // v2.4.0：先自动划掉「今天已结束的课程」对应的待办，再读取展示。
    await CourseTodoService.autoCompleteFinishedCourses();
    final all = await TodoRepository.instance.getAll();
    if (!mounted) return;
    final today = all.where((t) => _sameDay(t.date, _selectedDate)).toList();
    _sortTodos(today);
    setState(() => _todos = today);
  }

  /// 待办排序逻辑：未完成在前、已完成置底；同组内按提醒时间升序，
  /// 全天/无提醒时间的排在有时间的后面，让时间线自然呈现一天的先后顺序。
  void _sortTodos(List<Todo> list) {
    list.sort((a, b) {
      if (a.completed != b.completed) return a.completed ? 1 : -1;
      final at = a.reminderTime;
      final bt = b.reminderTime;
      if (at == null && bt == null) return 0;
      if (at == null) return 1; // 全天/无时间靠后
      if (bt == null) return -1;
      return at.compareTo(bt);
    });
  }

  /// 删除待办：先从当前列表移除（避免 Dismissible 滑走后组件仍留在树中报错），
  /// 再异步取消通知、持久化删除，最后**以存储为唯一真相重新加载列表**，
  /// 确保删除真正落盘；若存储删除失败，列表会恢复该条，不会静默「假删除」。
  ///
  /// v2.4.0：删除后提供「撤销」——误滑删除不再不可挽回。
  /// 撤销时用同一个 [Todo] 重新入库，id 不变 → notifyId 不变，提醒会被重新排上。
  Future<void> _deleteTodo(Todo todo) async {
    setState(() => _todos.removeWhere((t) => t.id == todo.id));
    // 删库 + 取消通知由仓库一并完成
    await TodoRepository.instance.delete(todo);
    _load(); // 从存储重新加载，确保持久化生效
    _loadOverview();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已删除「${todo.title}」'),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () async {
              await TodoRepository.instance.add(todo);
              await _load();
              _loadOverview();
            },
          ),
        ),
      );
  }

  /// 编辑待办：长按待办项弹出编辑表单，预填已有数据。
  Future<void> _editTodo(Todo todo) async {
    final updatedDate = await showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddTodoSheet(initialDate: todo.date, editTodo: todo),
    );
    if (updatedDate != null) {
      _load();
      _loadOverview();
    }
  }

  bool _sameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  void _selectDate(DateTime d) {
    setState(() => _selectedDate = d);
    _load();
  }

  Future<void> showAddTodoSheet() async {
    final result = await showModalBottomSheet<DateTime?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => AddTodoSheet(initialDate: _selectedDate),
    );
    if (result != null) {
      setState(() => _selectedDate = result);
      _load();
      _loadOverview();
      _scrollToSelected();
    }
  }


  @override
  Widget build(BuildContext context) {
    // 课表一变就立刻重算今日概览（旧做法是回到页面时靠 RouteObserver 重载）
    ref.listen<CourseState>(courseProvider, (prev, next) {
      if (!identical(prev?.courses, next.courses)) _loadOverview();
    });
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return Scaffold(
      backgroundColor: bg,
      body: _body(isDark),
    );
  }

  Widget _body(bool isDark) {
    final weekStart = _selectedDate.subtract(Duration(days: _selectedDate.weekday - 1));
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        // M3 的 AppBar 在内容滚到其下方（scrolledUnder）时会自动叠加
        // surfaceTint + 阴影，表现为顶部突现一块固定的"导航栏"色块，故禁用。
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '掌上锡院',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: context.textTertiary,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _formatDateHeader(_selectedDate),
                              style: TextStyle(fontSize: 14, color: context.textTertiary),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Today',
                              style: TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                                color: context.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: AppTheme.primaryColor.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child:  Icon(Icons.person_rounded, color: AppTheme.primaryColor, size: 24),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  HomeClockWidget(isDark: isDark),
                  const SizedBox(height: 4),
                  // 原来这里是「服务器状态 + 校园网状态」两列，服务器那一列删掉后
                  // 左边空出一大块 → 把下方的 QQ 群文字并到同一行，两行合一、不再有空挡。
                  Row(
                    children: [
                      HomeCampusNetStatus(
                        isDark: isDark,
                        status: _campusNetStatus,
                        onRefresh: _refreshCampusNet,
                      ),
                      const Spacer(),
                      Text(
                        'QQ 内测群 853204403',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark
                              ? Colors.grey.shade600
                              : const Color(0xFFB0B7C3),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              // v1.5.1 压缩：原 vertical:20，让「待办事项」上移
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        _buildWeekNavButton(Icons.chevron_left_rounded, () {
                          setState(() => _selectedDate = _selectedDate.subtract(const Duration(days: 7)));
                          _load();
                          _scrollToSelected();
                        }),
                        Expanded(
                          child: Center(
                            child: Text(
                              _weekRangeLabel(weekStart),
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: context.textSecondary,
                              ),
                            ),
                          ),
                        ),
                        _buildWeekNavButton(Icons.chevron_right_rounded, () {
                          setState(() => _selectedDate = _selectedDate.add(const Duration(days: 7)));
                          _load();
                          _scrollToSelected();
                        }),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8), // v1.5.1 压缩：原 12
                  SizedBox(
                    key: _kDateStrip, // v2.4.0 教程锚点
                    height: 72, // v1.5.1 压缩：原 84
                    child: ListView.builder(
                      controller: _dateScroll,
                      scrollDirection: Axis.horizontal,
                      itemCount: 7,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemBuilder: (ctx, i) {
                        final day = weekStart.add(Duration(days: i));
                        final isSelected = _sameDay(day, _selectedDate);
                        return GestureDetector(
                      onTap: () => _selectDate(day),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 56,
                        margin: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppTheme.textPrimaryLight
                              : (context.surfaceColor),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: isSelected
                              ? [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 12, offset: const Offset(0, 4))]
                              : AppTheme.cardShadow,
                          // v2.4.3：未选中的日期块补灰线（选中态是深色实块，不加）
                          border: isSelected
                              ? null
                              : Border.all(color: context.borderColor, width: 1),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              ['一', '二', '三', '四', '五', '六', '日'][i],
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: isSelected ? Colors.white70 : (context.textTertiary),
                              ),
                            ),
                            const SizedBox(height: 4), // v1.5.1 压缩：原 8
                            Text(
                              '${day.day}',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: isSelected ? Colors.white : (context.textPrimary),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
          ),
          SliverToBoxAdapter(
child: HomeTodayOverview(
              key: _kOverview,
              isDark: isDark,
              loaded: _overviewLoaded,
              todayCourseCount: _todayCourseCount,
              todoDone: _todayTodoDone,
              todoTotal: _todayTodoTotal,
              nextExam: _nextExam,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '待办事项',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.textPrimary),
                    ),
                  ),
                  Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      key: _kAddTodo, // v2.4.0 教程锚点
                      onTap: () => showAddTodoSheet(),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(Icons.add_rounded, size: 24, color: AppTheme.primaryColor),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_todos.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.inbox_outlined, size: 56, color: isDark ? Colors.grey.shade700 : Colors.grey.shade300),
                    const SizedBox(height: 16),
                    Text(
                      '今天没有待办',
                      style: TextStyle(fontSize: 14, color: context.textTertiary),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '点击右上角 + 号创建新待办',
                      style: TextStyle(fontSize: 12.5, color: isDark ? Colors.grey.shade600 : const Color(0xFF9CA3AF)),
                    ),
                  ],
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => TodoTimelineItem(
                    todo: _todos[i],
                    isFirst: i == 0,
                    isLast: i == _todos.length - 1,
                    onToggle: () => _toggleTodo(_todos[i]),
                    onDelete: () => _deleteTodo(_todos[i]),
                    onEdit: () => _editTodo(_todos[i]),
                  ),
                  childCount: _todos.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _formatDateHeader(DateTime d) {
    final now = DateTime.now();
    if (_sameDay(d, now)) return '今天';
    final tomorrow = now.add(const Duration(days: 1));
    if (_sameDay(d, tomorrow)) return '明天';
    return '${d.year}年${d.month}月${d.day}日';
  }

  String _weekRangeLabel(DateTime weekStart) {
    final end = weekStart.add(const Duration(days: 6));
    if (weekStart.month == end.month) {
      return '${weekStart.month}月${weekStart.day}日 - ${end.day}日';
    }
    return '${weekStart.month}月${weekStart.day}日 - ${end.month}月${end.day}日';
  }

  /// 初始化校园网状态：仅当无缓存（冷启动）才发起首次检测；
  /// 此后 Tab 切回只直显缓存，不再重新探测。
  void _initCampusNet() {
    if (CampusNetService.lastStatus == null) _refreshCampusNet();
  }

  /// 应用回到前台：网络可能已变（如连上/断开校园网），静默重测一次；
  /// 结果与当前显示一致则不刷新，避免闪屏。
  /// 同时重新判定「课程是否已结束」并刷新待办列表（下课回来看一眼即自动划掉）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshCampusNet();
      _load();
      _loadOverview();
    }
  }

  /// 检测校园网（隐式刷新）：不置「检测中」、不打断显示，
  /// 结束后仅当结果与当前不同才更新 UI。
  Future<void> _refreshCampusNet() async {
    if (_campusDetecting) return;
    _campusDetecting = true;
    try {
      final s = await CampusNetService.detect();
      if (!mounted) return;
      if (s != _campusNetStatus) setState(() => _campusNetStatus = s);
    } finally {
      _campusDetecting = false;
    }
  }

  Widget _buildWeekNavButton(IconData icon, VoidCallback onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: context.surfaceColor,
          shape: BoxShape.circle,
          boxShadow: AppTheme.cardShadow,
        ),
        child: Icon(icon, size: 20, color: isDark ? Colors.white70 : AppTheme.primaryColor),
      ),
    );
  }
}

