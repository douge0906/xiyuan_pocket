import 'dart:async';

import 'package:flutter/material.dart';
import 'home/home_cards.dart';
import '../widgets/home_week_strip.dart';
import '../widgets/home_todo_list.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/todo.dart';
import '../repositories/todo_repository.dart';
import '../providers/course_provider.dart';
import '../services/course_todo_service.dart';
import '../services/storage_service.dart';
import '../services/app_locale.dart';
import '../services/course_storage.dart';
import '../services/exam_storage.dart';
import '../services/notification_health.dart';
import '../services/notification_service.dart';
import '../services/campus_net_service.dart';
import '../services/home_prefs.dart';
import '../services/ui_prefs.dart';
import '../services/haptics.dart';
import '../theme/app_theme.dart';

import '../app.dart';
import 'add_todo_dialog.dart';
import 'todo_calendar_page.dart';

class _DaySnapshot {
  const _DaySnapshot({required this.courseCount, this.nextExam});
  final int courseCount;
  final ExamCountdown? nextExam;
}

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  HomePageState createState() => HomePageState();
}

class HomePageState extends ConsumerState<HomePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late DateTime _selectedDate;

  /// 已加载数据的日期（待办列表按它取）。
  ///
  /// 🔴 不能用 `late`：赋值点在 [_load] 的 setState 里（异步链跑完才赋值），
  ///    而首帧 build 就会读它 → LateInitializationError → 整页 ErrorWidget
  ///    （冷启动首页白屏且不会自愈）。这里给同步初值兜底。
  DateTime _dataDay = DateTime.now();

  /// 待办数据是否正在加载。
  ///
  /// 🔴 切日期时**立刻**置 true：否则标题已经变成「明天」，列表却还是
  /// 「今天」的旧数据（今天早上的课已经被自动划掉 → 显示成完成态），
  /// 看起来就是「切到明天，早上没上的课却显示完成」。
  bool _loadingTodos = false;

  /// [_load] 的请求世代号：同日并发时只让最后一次生效。
  int _loadSeq = 0;
  List<Todo> _todos = [];

  /// 待办排序方式：'time'（默认）/ 'priority'（2026-11-03 新增）。
  String _sortMode = 'time';
  Timer? _courseEndTicker;

  /// 切日期时的数据加载防抖：拖动周次条时连续触发，先只更新选中日期，
  /// 数据加载等手指停下来再跑一次（避免每扫过一格就重读一遍待办/课表）。
  Timer? _selectDebounce;

  // ---------------- 教程锚点（v2.4.0 指向性提示）----------------
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
  final Map<String, _DaySnapshot> _dayStats = <String, _DaySnapshot>{};
  int _refreshTick = 0;
  DateTime? _semesterStart;
  Future<void>? _statsInflight;
  int _statsEpoch = 0;

  int get _selectedWeek => _semesterStart == null
      ? ref.read(courseProvider).currentWeek
      : CourseStorage.teachingWeek(_selectedDate, _semesterStart!);

  String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    // 语言切换：问候语要立刻跟着变（首页是被 IndexedStack 保活的同一实例）。
    AppLocale.notifier.addListener(_onLocaleChanged);
    _selectedDate = DateTime.now();
    _selectedDate = DateTime(
        _selectedDate.year, _selectedDate.month, _selectedDate.day);
    // 与 _selectedDate 对齐，避免首帧 key 与后续不一致导致列表重建。
    _dataDay = _selectedDate;
    _courseEndTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && TickerMode.of(context)) _refreshCourseEndState();
    });
    _ensureStats();
    // 排序方式要在首次 _load 之前读出来，否则首屏会先按时间排一遍再跳。
    StorageService.loadTodoSortMode().then((m) {
      if (!mounted || m == _sortMode) return;
      setState(() => _sortMode = m);
      _load(forDay: _selectedDate);
    });
    _load();
    // 整周课程待办一次性预排（内部只读一次课表/待办），之后切任意一天都有数据。
    // 放到首帧之后：不要和首屏的当天加载抢同一把锁，否则首屏要多等 7 天。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      CourseTodoService.syncCoursesForWeek(_selectedDate);
    });
    _rescheduleAll();
    _loadOverview();
    _initCampusNet();
    // 监听「点击通知」事件：payload 为被点待办的 id，定位到对应日期并高亮。
    NotificationService.pendingTodoId.addListener(_handleNotificationTap);
    // 监听 App 生命周期：回到前台时隐式重测校园网状态。
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
    // 🔴 重复待办库里只有一行、`date` = **创建起始日**（没有任何代码把 date
    //    往前滚），所以「取 occursOn 命中的那条」等于取 `matches.first`：
    //    今天 8:00 的每日待办通知点进去，跳到的还是几个月前的创建日，
    //    页面上什么都没有 —— 上一版「优先跳到今天那条」的写法对重复待办
    //    完全无效，因为库里就只有那一条。
    //
    // 正确做法：跳转日期取「提醒发生的这一天」。
    //   · 只出现过一次（非重复）：它自己的 date 就是答案；
    //   · 今天也会出现：跳到今天；
    //   · 都不满足（比如点的是历史通知）：退回它自己的 date。
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = matches.firstWhere(
      (t) => t.occursOn(now),
      orElse: () => matches.first,
    );
    final jumpTo = target.isRepeating && target.occursOn(today)
        ? today
        : DateTime(target.date.year, target.date.month, target.date.day);
    setState(() => _selectedDate = jumpTo);
    await _load();
    _loadOverview();
  }

  Future<void> _ensureStats() async {
    final key = _dayKey(_selectedDate);
    if (_dayStats.containsKey(key)) return;
    final running = _statsInflight;
    if (running != null) {
      await running;
      if (_dayStats.containsKey(key)) return;
    }
    final f = _precomputeWeek();
    _statsInflight = f;
    try {
      await f;
    } finally {
      if (identical(_statsInflight, f)) _statsInflight = null;
    }
  }

  /// 提前算好本周 7 天的课程数 / 最近考试，切日期时不用再等网络或遍历。
  Future<void> _precomputeWeek() async {
    final epoch = _statsEpoch;
    final now = DateTime.now();
    final state = ref.read(courseProvider);
    final start = await CourseStorage.loadSemesterStart();
    final week = state.currentWeek;
    final monday =
        _selectedDate.subtract(Duration(days: _selectedDate.weekday - 1));
    final rawExams = await ExamStorage.loadExams();
    final exams = <({String name, DateTime at, String place, String time})>[];
    for (final e in rawExams) {
      final raw = (e['date'] as String?)?.trim() ?? '';
      final m = RegExp(r'(\d{4})\D+(\d{1,2})\D+(\d{1,2})').firstMatch(raw);
      if (m == null) continue;
      final y = int.tryParse(m.group(1)!);
      final mo = int.tryParse(m.group(2)!);
      final d = int.tryParse(m.group(3)!);
      if (y == null || mo == null || d == null) continue;
      final time = (e['start_time'] as String?)?.trim() ?? '';
      var at = DateTime(y, mo, d);
      final hm = time.split(':');
      if (hm.length >= 2) {
        final h = int.tryParse(hm[0]);
        final mi = int.tryParse(hm[1]);
        if (h != null && mi != null) at = DateTime(y, mo, d, h, mi);
      }
      exams.add((
        name: (e['name'] as String?)?.trim().isNotEmpty == true
            ? (e['name'] as String).trim()
            : '未命名考试',
        at: at,
        place: (e['classroom'] as String?)?.trim() ?? '',
        time: time,
      ));
    }
    final map = <String, _DaySnapshot>{};
    for (var i = 0; i < 7; i++) {
      final day = monday.add(Duration(days: i));
      final dayWeek = start == null
          ? week
          : CourseStorage.teachingWeek(day, start);
      final count = state.courses
          .where((c) => c.occursOn(day.weekday, dayWeek))
          .length;
      // 🔴 「最近考试」口径必须与 ExamStorage.nextExam() 一致：**不早于今天**。
      //    之前只按 day 过滤 → 切到本周较早的日期时，会把**已经过去几天的考试**
      //    当成「最近考试」显示（首页概览与桌面小组件显示不同的考试）。
      final todayNow = DateTime(now.year, now.month, now.day);
      final later = exams
          .where((e) =>
              !e.at.isBefore(day) && !e.at.isBefore(todayNow))
          .toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      ExamCountdown? next;
      if (later.isNotEmpty) {
        final e = later.first;
        next = ExamCountdown(
          name: e.name,
          date: DateTime(e.at.year, e.at.month, e.at.day),
          daysLeft: DateTime(e.at.year, e.at.month, e.at.day)
              .difference(DateTime(day.year, day.month, day.day))
              .inDays,
          classroom: e.place,
          startTime: e.time,
        );
      }
      map[_dayKey(day)] = _DaySnapshot(courseCount: count, nextExam: next);
    }
    if (mounted && epoch == _statsEpoch) {
      setState(() {
        _semesterStart = start;
        _dayStats.addAll(map);
      });
    }
  }

  /// 计算今日概览：今天上课门数 + 最近一场考试倒计时。
  Future<void> _loadOverview() async {
      // 课表取自 courseProvider（应用内唯一数据源）——
      // 别的页面改了课表，这里会通过下面的 ref.listen 自动重算
      final courseState = ref.read(courseProvider);
      final selected = _selectedDate;
      if (!_dayStats.containsKey(_dayKey(selected))) {
        await _ensureStats();
      }
      if (!mounted || !_sameDay(selected, _selectedDate)) return;
      final snap = _dayStats[_dayKey(selected)];
      final week = _semesterStart == null
          ? courseState.currentWeek
          : CourseStorage.teachingWeek(selected, _semesterStart!);
      final count = snap?.courseCount ??
          courseState.courses
              .where((c) => c.occursOn(selected.weekday, week))
              .length;
    final exam = snap?.nextExam ?? await ExamStorage.nextExam();
    final allTodos = await TodoRepository.instance.getAll();
    // 🔴 与列表口径统一：重复待办按 occursOn 展开、完成态按 isDoneOn 读。
    //    否则概览的「完成 x/y」与首页列表对不上。
    final todayTodos =
        allTodos.where((t) => t.occursOn(selected)).toList();
    final done = todayTodos.where((t) => t.isDoneOn(selected)).length;
    if (!mounted || !_sameDay(selected, _selectedDate)) return;
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
    AppLocale.notifier.removeListener(_onLocaleChanged);
    _courseEndTicker?.cancel();
    _selectDebounce?.cancel();
    NotificationService.pendingTodoId.removeListener(_handleNotificationTap);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 启动时重新排程所有未来提醒：Android 会在重启/强制停止后清除定时通知，
  /// 在 APP 打开时补排一次（由仓库统一完成，幂等安全）。
  /// 启动时全量重排一次待办提醒。
  ///
  /// 🔴 2026-11-02 修「通知不到位」：
  ///    原来这里 `await` 完就把结果丢了，而 `rescheduleAll()` 那时还是 void ——
  ///    三级降级全失败时**没有任何一处知道排程失败了**。
  ///    现在拿回 `(scheduled, failed)`：失败条数记进 [NotificationHealth]，
  ///    由提醒设置页展示，也让「通知自检」能说真话。
  Future<void> _rescheduleAll() async {
    final r = await TodoRepository.instance.rescheduleAll();
    NotificationHealth.instance.report(scheduled: r.scheduled, failed: r.failed);
    if (r.failed > 0) {
      debugPrint('⚠️ 有 ${r.failed} 条待办提醒排程失败（系统拒绝了所有排程模式）');
    }
  }

  Future<void> _toggleTodo(Todo todo) async {
    // 勾待办给一次更重的触感：这是一个「有结果」的动作，比普通点击值钱。
    // 普通点击已由 TapHapticsScope 统一处理，这里显式补一次「强」。
    if (UiPrefs.haptics) {
      Haptics.fire(UiPrefs.hapticLevel > 2 ? 3 : 2);
    }
    // 重复待办的完成态存在 completedDates（按天），非重复才用 completed 布尔位。
    // 🔴 之前统一调 toggleComplete → 重复待办只翻了 completed 布尔位，
    //    而读取端 isDoneOn 读的是 completedDates → 勾了也不算数，
    //    日历页与热力图永远显示未完成。
    final day = _dataDay;
    final willComplete = !todo.isDoneOn(day);
    // 乐观 UI：立刻更新本地状态，不等存储写入
    setState(() {
      // ⚠️ 按 (id, 日期) 定位：同 id 不同日期时不能改到别的行。
      // 🔴 重复待办的 date 只是「起始日」，次日 _sameDay 不成立 → idx = -1
      //    → 乐观更新空转，列表纹丝不动，而 toggleCompleteOn 已经落库成功、
      //    _loadOverview 现算的计数也 +1，用户看到「勾选框不动但顶部的数字变了」。
      //    与 _load 里 `all.where((t) => t.occursOn(target))` 必须同口径。
      final idx = _todos.indexWhere((t) => t.id == todo.id && t.occursOn(day));
      if (idx >= 0) {
        final cur = _todos[idx];
        _todos[idx] = cur.isRepeating
            ? cur.copyWith(completedDates: _toggledDates(cur, day, willComplete))
            // 完成态按天归属：勾「明天」只影响明天，不会带到今天。
            // 🔴 取消完成必须 clearCompletedDay：copyWith 的 completedDay
            //    是 `?? this.completedDay` —— 传 null 是「不改」不是「清空」。
            //    这里漏掉的话，即使仓库层写对了，乐观 UI 仍会立刻把
            //    「已完成」画回去，用户看到的就是「点完就取消不掉」。
            : cur.copyWith(
                completed: willComplete,
                completedDay:
                    willComplete ? Todo.dayKeyOf(day) : null,
                clearCompletedDay: !willComplete,
              );
      }
    });
    // 落库 + 通知（完成即取消 / 未完成且未来则重排）全部交由仓库编排
    await TodoRepository.instance.toggleCompleteOn(todo, day);
    if (!mounted) return;
    _loadOverview();
  }

  /// 重复待办完成态的乐观更新：把当天加入 / 移出 completedDates。
  static List<String> _toggledDates(Todo todo, DateTime day, bool complete) {
    final dates = List<String>.from(todo.completedDates);
    final key = Todo.dayKeyOf(day);
    if (complete) {
      if (!dates.contains(key)) dates.add(key);
    } else {
      dates.remove(key);
    }
    return dates;
  }

  /// 从其他 Tab 切回首页时调用：重新加载待办 + 播放一次整体入场。
  void onHomeTabResumed() {
    if (!mounted) return;
    setState(() => _refreshTick++);
    _load(forDay: _selectedDate);
    _loadOverview();
  }

  void _onLocaleChanged() {
    if (mounted) setState(() {});
  }

  /// 课程结束检查：结束的课程待办自动标记完成，列表原位压缩。
  Future<void> _refreshCourseEndState() async {
    final n = await CourseTodoService.autoCompleteFinishedCourses();
    if (n > 0 && mounted) {
      await _load();
      _loadOverview();
    }
  }

  Future<void> _load({DateTime? forDay}) async {
    final target = forDay ?? _selectedDate;
    // 🔴 请求世代号：同日并发时只允许最后一次生效。
    // 原来唯一守卫是「目标日 != 当前选中日」，同一天的并发请求全部放行、
    // 后完成者覆盖先完成者 —— 两个可观察后果：
    //   ① `_loadingTodos` 被先完成者复位 → 骨架提前消失，露出旧列表；
    //   ② 删除与自动完成交错时，后写者可短暂让已删项复活。
    final seq = ++_loadSeq;
    try {
      // 顺序不能颠倒：
      //   ① 迁移历史脏数据（清理同 id 撞号、回填完成归属日）
      //   ② 修复脏数据（未来日期却被标完成的课程待办）
      //   ③ 同步课程待办
      //   ④ 自动划掉已结束课程
      // ① 必须最先：撞号没清掉时，②③ 的 (id,日期) 定位仍会命中错的行。
      await CourseTodoService.migrateCourseTodoHistory();
      await CourseTodoService.repairFutureCompletedCourses();
      await CourseTodoService.syncCoursesForDate(target);
      await CourseTodoService.autoCompleteFinishedCourses();
      final all = await TodoRepository.instance.getAll();
      if (!mounted || seq != _loadSeq || !_sameDay(target, _selectedDate)) {
        return;
      }
      // 🔴 重复待办的 date 只是「起始日」，按它精确匹配会让重复待办
      //    次日就消失（日历页用 occursOn 是对的，两处口径必须一致）。
      final today = all.where((t) => t.occursOn(target)).toList();
      _sortTodos(today);
      setState(() {
        _todos = today;
        _dataDay = target;
      });
    } finally {
      // 无论成功失败都要退出加载态，否则异常时骨架会一直挂着。
      if (mounted && seq == _loadSeq && _sameDay(target, _selectedDate)) {
        setState(() => _loadingTodos = false);
      }
    }
  }

  /// 待办排序逻辑：未完成在前、已完成置底；同组内按提醒时间升序，
  /// 全天/无提醒时间的排在有时间的后面，让时间线自然呈现一天的先后顺序。
  ///
  /// 2026-11-03：增加「排序方式」切换（`_sortMode`）。两种：
  ///   · `time`（默认）—— 原来的纯时间序，时间线感最强；
  ///   · `priority` —— 先按优先级（紧急 → 重要 → 普通），同档内再按时间。
  /// 为什么值得加：待办一多，「今天三件事先干哪件」是真实决策，
  /// 而优先级在列表里只能靠左边那条色条看，排不到前面就等于白设。
  void _sortTodos(List<Todo> list) {
    list.sort((a, b) {
      // 完成不改变位置：只按时间排，完成项仍留在原来的位置。
      //
      // 🔴 时间口径与**显示**保持一致：`reminderTime ?? dueAt`。
      //    原来只看 reminderTime → 新版弹窗新增的待办（时间在 dueAt）
      //    会被当成「全天」排到最后一组，与用户看到的时刻对不上。
      // 三级兜底到 date —— 永远非空，所以不用再判 null。
      if (_sortMode == 'priority' && a.priority != b.priority) {
        return b.priority.compareTo(a.priority); // 2 紧急 > 1 重要 > 0 普通
      }
      final at = a.reminderTime ?? a.dueAt ?? a.date;
      final bt = b.reminderTime ?? b.dueAt ?? b.date;
      return at.compareTo(bt);
    });
  }

  /// 切换排序方式（写盘 + 重排当前列表）。
  Future<void> _setSortMode(String mode) async {
    if (_sortMode == mode) return;
    setState(() => _sortMode = mode);
    await StorageService.saveTodoSortMode(mode);
    await _load(forDay: _selectedDate);
  }

  /// 删除待办：先从当前列表移除（避免 Dismissible 滑走后组件仍留在树中报错），
  /// 再异步取消通知、持久化删除，最后**以存储为唯一真相重新加载列表**，
  /// 确保删除真正落盘；若存储删除失败，列表会恢复该条，不会静默「假删除」。
  ///
  /// v2.4.0：删除后提供「撤销」——误滑删除不再不可挽回。
  /// 撤销时用同一个 [Todo] 重新入库，id 不变 → notifyId 不变，提醒会被重新排上。
  Future<void> _deleteTodo(Todo todo) async {
    // 与 [_toggleTodo] 一致：按 (id, 日期) 定位，同 id 不同日期时不能误删别的行。
    setState(() => _todos.removeWhere(
        (t) => t.id == todo.id && _sameDay(t.date, todo.date)));
    // 删库 + 取消通知由仓库一并完成
    //
    // 🔴 顺序：先 suppress 再 delete。
    //    原来反着来：delete 之后才登记抑制键，中间那段窗口里 30 秒 ticker
    //    的 `_refreshCourseEndState` → `_load` → `syncCoursesForDate` 读到
    //    旧抑制集合，会把刚删的课程待办重建回来；之后整个运行期它都在库里
    //    （历史「课程待办删不掉」就是这个症状）。
    if (todo.id.startsWith('course_')) {
      await CourseTodoService.suppress(todo.id, todo.date);
    }
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
              // 撤销的顺序与删除相反：先解除抑制再入库。
              // 反着来的话，中间窗口里同步会把它当成「用户不要了」跳过。
              if (todo.id.startsWith('course_')) {
                await CourseTodoService.unsuppress(todo.id, todo.date);
              }
              await TodoRepository.instance.add(todo);
              await _load();
              _loadOverview();
            },
          ),
        ),
      );
  }

  /// 编辑待办：长按待办项弹出**居中弹窗**编辑，预填已有数据。
  ///
  /// ⚠️ 2026-10-31：原来用的是底部抽屉 `AddTodoSheet`，
  ///    违反项目死律「弹窗一律居中、右上角可关」，且两套表单字段各写各的。
  ///    现在统一用 [AddTodoDialog]，编辑与新增同一套交互。
  Future<void> _editTodo(Todo todo) async {
    final updated = await AddTodoDialog.show(context, editTodo: todo);
    if (updated == null || !mounted) return;

    // 🔴 课程待办改期必须**同步改 id**（日期就在 id 里）。
    //    只改 date 会让 id 与日期脱钩 → 这条永远不会被自动完成、
    //    那天的课程不会生成、用户的编辑还会被同步静默回滚。
    if (todo.id.startsWith('course_')) {
      // 🔴 moveCourseTodo 有 3 条 return false（非课程待办 / 新 id 撞号 /
      //    异常），原来把返回值直接丢掉了：弹窗已经关闭、改动丢失，用户
      //    看起来是「保存成功了」。非课程分支一直是接住并 toast 的，两条
      //    分支口径必须一致。
      final ok = await CourseTodoService.moveCourseTodo(todo, updated);
      if (!ok && mounted) {
        _toast('改期失败：那天已有同一节课的待办，请先删除旧的再改');
        return;
      }
    } else {
      // 找不到记录时不要静默当成功 —— 之前就是这样把改动吞掉的。
      final ok = await TodoRepository.instance.update(updated);
      if (!ok && mounted) {
        _toast('保存失败：这条待办已不存在，请下拉刷新后重试');
        return;
      }
    }
    if (!mounted) return;
    await _load(forDay: _selectedDate);
    _loadOverview();
  }

  bool _sameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  void _selectDate(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    setState(() {
      _selectedDate = day;
      _loadingTodos = true;
      _todos = [];
    });
    _load(forDay: d);
    _loadOverview();
  }

  void _shiftWeek(int delta) {
    final target = _selectedDate.add(Duration(days: 7 * delta));
    final day = DateTime(target.year, target.month, target.day);
    setState(() {
      _selectedDate = day;
      _loadingTodos = true;
      _todos = [];
    });
    _ensureStats();
    _selectDebounce?.cancel();
    _selectDebounce = Timer(const Duration(milliseconds: 90), () {
      if (!mounted) return;
      _load(forDay: day);
      _loadOverview();
    });
  }

  /// 轻量提示（浮动 SnackBar）。
  void _toast(String msg) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 80),
        ),
      );
  }

  Future<void> showAddTodoSheet() async {
    // 首页新增待办改用新版待办器（居中弹窗），与新版首页保持一致。
    final todo = await AddTodoDialog.show(context, initialDate: _selectedDate);
    if (todo == null || !mounted) return;
    await _ensureNotifyPermissionIfNeeded(todo);
    await TodoRepository.instance.add(todo);
    // 🔴 落库是真实 IO，await 期间页面可能已销毁 → setState 会抛
    //    「setState() called after dispose()」。
    if (!mounted) return;
    setState(() => _selectedDate = todo.date);
    await _load(forDay: todo.date);
    _loadOverview();
  }

  /// 用户刚建了一条**带提醒**的待办 —— 这是唯一该问通知权限的时刻。
  ///
  /// 🔴 2026-11-02 修「通知不到位」的核心：
  ///    在此之前全仓只有「设置页」和「测一次」会申请 `POST_NOTIFICATIONS`，
  ///    启动与创建路径一次都没有。Android 13+ 用户建完提醒待办，
  ///    到点什么都收不到（系统静默丢弃），也不会想到去设置页找权限。
  ///
  /// 只在 `todo` 真的带提醒时才问，且被拒绝过就不再纠缠（见
  /// `NotificationService.ensureFirstRunPermission`）。
  Future<void> _ensureNotifyPermissionIfNeeded(Todo todo) async {
    if (todo.reminderTime == null) return;
    final ok = await NotificationService.ensureFirstRunPermission();
    if (!ok && mounted) {
      // 不弹阻断式对话框：待办已经建好了，提示一句就够。
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('提醒已保存，但通知权限未开启 —— 到系统设置里允许通知才会响'),
          duration: Duration(seconds: 4),
        ),
      );
    }
  }


  @override
  Widget build(BuildContext context) {
    // 课表一变就立刻重算今日概览（旧做法是回到页面时靠 RouteObserver 重载）
    ref.listen<CourseState>(courseProvider, (prev, next) {
      if (!identical(prev?.courses, next.courses)) {
        // 课程加载/增删发生变化：旧统计全部失效，必须重算。
        _statsEpoch++;
        _dayStats.clear();
        _ensureStats();
        _load();
        _loadOverview();
      }
    });
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return Scaffold(
      backgroundColor: bg,
      // 2026-10-16：首页板块显隐变了 → 立即重建（不用手动 listener）
      body: ValueListenableBuilder<int>(
        valueListenable: HomePrefs.notifier,
        builder: (_, __, ___) => _body(isDark),
      ),
    );
  }

  /// 打开**设置页**（右上角齿轮）。
  ///
  /// 🔴 2026-11-03：不再进「首页独立设置页」，改为**切到「我的」并打开**
  /// 那一套唯一完整的设置页。原来有三套互不相通的设置入口：
  ///   1. 用户页 → 设置（`SettingsPage`，完整）
  ///   2. 首页齿轮 → `HomeSettingsPage`（82 行，只有一张「通知提醒」卡）
  ///   3. 用户页「关于」里的「设置」（又是第 1 个）
  /// 第 2 套是残页：注释写着「下面保留一个『账号与隐私』入口」，代码里
  /// 根本没有。用户在首页点齿轮就掉进死胡同，找不到主题/隐私/退出登录。
  ///
  /// 走 [AppTabs.openSettings]：置位信号 + 切 Tab，「我的」页在可见时
  /// 消费信号并打开设置（首页造不出那一页要的回调）。
  /// `home_settings_page.dart` 已删除。
  void _openSettings() {
    AppTabs.openSettings();
  }



  /// 退出登录：清会话 + 清本地数据 + 重置内存态 provider（与用户页同一套）。

  Widget _homeActions() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _overlayAction(
          icon: Icons.calendar_month_outlined,
          tooltip: '待办日历',
          onTap: () => TodoCalendarPage.open(context),
        ),
        const SizedBox(width: 2),
        _overlayAction(
          icon: Icons.settings_outlined,
          tooltip: '设置',
          onTap: _openSettings,
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _overlayAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        backgroundColor: context.surfaceColor.withValues(alpha: .86),
        minimumSize: const Size(34, 34),
        padding: const EdgeInsets.all(6),
      ),
      icon: Icon(icon, size: 19, color: context.textTertiary),
    );
  }

  Widget _body(bool isDark) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding:
                  EdgeInsets.only(top: MediaQuery.of(context).padding.top),
              child: CustomScrollView(
                slivers: [
          // ---------------- 信息栏（首页个性化：可隐藏）----------------
          if (HomePrefs.showHeader)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 🔴 2026-11-03（UI P0 / A1-1 + A1-2）：顶部原本是四行字
                  //   「掌上锡院 31px」+「周一 20px + MON 10.5px」+
                  //   「问候语 18px」+「年月日 11px」，四种字号、四种颜色，
                  //   全是 textPrimary —— 没有主次，眼睛不知道先看哪。
                  //   收成两行：标题独占一行，其余压成一行元信息；
                  //   问候语降级到 12.5px textSecondary 挪到标题右侧（不删，见方案 A1-2）。
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '掌上锡院',
                        style: TextStyle(
                          fontSize: AppTheme.fontHero,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.6,
                          height: AppTheme.lineTight,
                          color: context.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '$_greeting，同学',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTheme.fontSmall,
                            height: AppTheme.lineTitle,
                            color: context.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '周$_weekdayLabel · ${_selectedDate.month}月${_selectedDate.day}日 · 第$_selectedWeek周',
                    style: TextStyle(
                      fontSize: AppTheme.fontSmall,
                      height: AppTheme.lineTitle,
                      color: context.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      HomeCampusNetStatus(
                        isDark: isDark,
                        status: _campusNetStatus,
                        onRefresh: _refreshCampusNet,
                      ),
                      const Spacer(),
                      Text(
                        '交流群 853204403',
                        style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          color: context.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // ---------------- 周次选择栏（首页个性化：可隐藏）----------------
          if (HomePrefs.showWeekStrip)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: HomeWeekStrip(
                selected: _selectedDate,
                onSelected: _selectDate,
                onPreviousWeek: () => _shiftWeek(-1),
                onNextWeek: () => _shiftWeek(1),
              ),
            ),
          ),
          // ---------------- 今日待办小卡片 · 今日概览（首页个性化：可隐藏）----------------
          if (HomePrefs.showOverview)
          SliverToBoxAdapter(
            child: KeyedSubtree(
              key: _kOverview,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: _fadeOnly,
                child: HomeTodayOverview(
                  key: ValueKey(
                      '$_todayCourseCount-$_todayTodoTotal-$_todayTodoDone-${_nextExam?.date}'),
                  isDark: isDark,
                  loaded: _overviewLoaded,
                  todayCourseCount: _todayCourseCount,
                  todoDone: _todayTodoDone,
                  todoTotal: _todayTodoTotal,
                  nextExam: _nextExam,
                  courseLabel: _sameDay(_selectedDate, DateTime.now())
                      ? '今天课程'
                      : '当天课程',
                ),
              ),
            ),
          ),
          // ---------------- 待办事项：标题栏（含 + 号）（首页个性化：可隐藏）----------------
          if (HomePrefs.showTodos)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '待办事项',
                      style: TextStyle(fontSize: AppTheme.fontHeading, fontWeight: FontWeight.bold, color: context.textPrimary),
                    ),
                  ),
                  // 排序切换（2026-11-03）：时间 ⇄ 优先级。
                  // 列表里 priority 只能靠左侧色条看，排不到前面就等于白设。
                  Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                      onTap: () => _setSortMode(
                          _sortMode == 'time' ? 'priority' : 'time'),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          _sortMode == 'time'
                              ? Icons.schedule_rounded
                              : Icons.sort_rounded,
                          size: 22,
                          color: _sortMode == 'time'
                              ? context.textTertiary
                              : AppTheme.primaryColor,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
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
          // ---------------- 待办事项：列表本体（首页个性化：可隐藏）----------------
          if (HomePrefs.showTodos)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
              sliver: SliverToBoxAdapter(
                child: _loadingTodos
                    // 加载中：显示骨架占位，**绝不显示上一天的旧数据**
                    // （否则切到明天会看到「今天早上的课已完成」）。
                    ? Column(
                        children: [
                          for (var i = 0; i < 3; i++)
                            Container(
                              height: 62,
                              margin: const EdgeInsets.only(bottom: 10),
                              decoration: BoxDecoration(
                                color: context.surfaceColor,
                                borderRadius:
                                    BorderRadius.circular(AppTheme.radiusLg),
                                border: Border.all(color: context.borderColor),
                              ),
                            ),
                        ],
                      )
                    : HomeTodoList(
                        key: ValueKey(_dataDay),
                        todos: _todos,
                        date: _dataDay,
                        restPhrase: _restPhrase,
                        refreshTick: _refreshTick,
                        onToggle: _toggleTodo,
                        onDelete: _deleteTodo,
                        onEdit: _editTodo,
                      ),
              ),
            ),
                ],
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 2,
            right: 6,
            child: _homeActions(),
          ),
        ],
      ),
    );
  }

  /// 概览卡的切换过渡：**只做透明度**。
  ///
  /// 之前带模糊（ImageFiltered），概览数字一刷新就整卡重新光栅化 → 明显闪一下。
  /// 现在纯合成层属性，零重绘。
  Widget _fadeOnly(Widget child, Animation<double> animation) {
    final t = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return AnimatedBuilder(
      animation: t,
      builder: (_, __) {
        final v = t.value.clamp(0.0, 1.0);
        return Opacity(opacity: v, child: child);
      },
    );
  }

  String get _weekdayLabel {
    const labels = ['一', '二', '三', '四', '五', '六', '日'];
    return labels[_selectedDate.weekday - 1];
  }

  String get _restPhrase {
    const phrases = [
      '休息休息吧！',
      '刷一会儿短剧吧！',
      '喝口水休息休息吧！',
      '出来转一转吧！',
    ];
    return phrases[_selectedDate.day % phrases.length];
  }

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 6) return S.t('greeting_late');
    if (h < 11) return S.t('greeting_morning');
    if (h < 14) return S.t('greeting_noon');
    return S.t('greeting_evening');
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
      _ensureStats();
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
}
