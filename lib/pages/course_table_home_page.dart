import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/course_model.dart';
import '../models/todo.dart';
import '../repositories/todo_repository.dart';
import '../services/course_reminder_service.dart';
import '../services/course_storage.dart';
import '../services/course_sync_service.dart';
import '../providers/course_provider.dart';
import '../services/course_todo_service.dart';
import 'reminder_settings_page.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/course_day_header.dart';
import '../widgets/course_date_picker.dart';
import 'course/course_form_sheet.dart';
import 'tools/course_table_settings_page.dart';
import '../widgets/course_grid_widgets.dart';


class CourseTableHomePage extends ConsumerStatefulWidget {
  const CourseTableHomePage({super.key});

  @override
  ConsumerState<CourseTableHomePage> createState() =>
      _CourseTableHomePageState();
}

class _CourseTableHomePageState extends ConsumerState<CourseTableHomePage> {
  // ---------------- 功能教程锚点（v1.9.0）----------------
  // 用 GlobalKey 标记要讲解的按钮，教程浮层据此取屏幕坐标做高亮挖洞。
  final GlobalKey _kAlarmBtn = GlobalKey();
  final GlobalKey _kMoreBtn = GlobalKey();

  List<Course> _courses = [];
  /// 正在手动同步课表（刷新键转圈 + 挡住重复点击）。
  bool _syncing = false;

  /// 「第 1 周从哪天开始」的首次提醒本页面生命周期内只弹一次。
  bool _semesterAsked = false;
  late int _selectedWeek;
  DateTime? _semesterStart;
  /// v2.4.0：改为 getter——原先 `final` 只在 initState 取一次，
  /// App 跨零点仍在后台时「今天」永远停在启动那天（高亮、今日课程判定全错）。
  int get _todayWeekday => DateTime.now().weekday;
  late final PageController _pageController;
  /// 上课时间块（可自定义并持久化）；未自定义时用默认表。
  List<CourseBlock> _blocks = List.of(kDefaultCourseBlocks);

  DateTime get _effectiveStart =>
      _semesterStart ?? CourseStorage.defaultSemesterStart(DateTime.now());

  @override
  void initState() {
    super.initState();
    _selectedWeek = CourseStorage.teachingWeek(DateTime.now(), _effectiveStart);
    _pageController = PageController(
      initialPage: (_selectedWeek - 1).clamp(0, kMaxCourseWeeks - 1),
    );
    _loadTimeBlocks();
    _loadSemesterStart();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final dismissed = await StorageService.loadJwglNoticeDismissed();
      if (mounted && !dismissed) _showJwglNotice();
    });
  }

  /// 读取自定义上课时间块（允许用户在设置里调整）；无记录则用默认表。
  Future<void> _loadTimeBlocks() async {
    final saved = await CourseStorage.loadTimeBlocks();
    if (!mounted) return;
    if (saved != null && saved.isNotEmpty) {
      setState(() => _blocks = saved.map((j) => CourseBlock.fromJson(j)).toList());
    }
  }

  void _showJwglNotice() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.info_outline_rounded, color: Color(0xFFF59E0B)),
            SizedBox(width: 8),
            Text('温馨提示'),
          ],
        ),
        content: const Text('由于教务系统关闭，00:00-6:00 期间可能无法查询成绩、课表与考试安排，请避开该时段使用。'),
        actions: [
          TextButton(
            onPressed: () async {
              await StorageService.saveJwglNoticeDismissed(true);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('不再提醒', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadSemesterStart() async {
    final s = await CourseStorage.loadSemesterStart();
    if (!mounted) return;
    setState(() {
      _semesterStart = s;
      _selectedWeek = CourseStorage.teachingWeek(DateTime.now(), _effectiveStart);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = (_selectedWeek - 1).clamp(0, kMaxCourseWeeks - 1);
      if (_pageController.hasClients && _pageController.page?.round() != target) {
        _pageController.jumpToPage(target);
      }
    });
  }

  Future<void> _changeSemesterStart(DateTime date) async {
    // 对齐到周一：教学周以周一为界，否则日期列错位（9.7 bug 修复）
    final aligned = CourseStorage.mondayOf(date);
    // byUser: true —— 用户亲手定的。既不再提醒，也不会被后续自动同步覆盖
    // （见 CourseStorage.loadSemesterStartConfirmed / shouldAdoptSemesterStart）。
    await CourseStorage.saveSemesterStart(aligned, byUser: true);
    if (!mounted) return;
    setState(() {
      _semesterStart = aligned;
      _selectedWeek = CourseStorage.teachingWeek(DateTime.now(), _effectiveStart);
    });
    // 改开学日期后同步 PageView 定位
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = (_selectedWeek - 1).clamp(0, kMaxCourseWeeks - 1);
      if (_pageController.hasClients && _pageController.page?.round() != target) {
        _pageController.jumpToPage(target);
      }
    });
    // 开学日变更后同步推送快照
    CourseReminderService.rescheduleAll(); // v2.2.21 开学日影响教学周→重排上课提醒
  }

  /// 首次自动导入后，提醒用户确认「第 1 周从哪天开始」——**只提醒一次**。
  ///
  /// 为什么要提醒：自动导入是按月份估的（秋季 9/7、春季 2/24），估错一周
  /// 整张课表的周次就全偏了，单双周课程还会跟着错。
  /// 以前的「手动导入」路径导入完会弹这个选择器，改成自动导入之后没人弹了，
  /// 用户就只能对着一个偏了一周的「第 N 周」发呆。
  ///
  /// 没有课表就不打扰（周次还没有意义）；用户定过（或明确跳过）过也不再问。
  Future<void> _maybeAskSemesterStart() async {
    if (_semesterAsked || _courses.isEmpty) return;
    if (await CourseStorage.loadSemesterStartConfirmed()) return;
    if (!mounted) return;
    _semesterAsked = true; // 无论用户选不选都只弹一次
    await _askSemesterStart();
  }

  /// 弹「选择第 1 周」的居中对话框（复刻原来手动导入后的那一步）。
  Future<void> _askSemesterStart() async {
    final suggested = CourseStorage.mondayOf(_effectiveStart);
    final picked = await showCourseDatePicker(
      context: context,
      initialDate: suggested,
      firstDate: DateTime(suggested.year - 1, 1, 1),
      lastDate: DateTime(suggested.year + 1, 12, 31),
      helpText: '请确认本学期第 1 周的周一（默认 ${suggested.month} 月 ${suggested.day} 日）',
    );
    // 用户直接关掉也算「确认过」——保留估算值（秋季 9/7），不再反复打扰
    await CourseStorage.markSemesterStartConfirmed();
    if (picked == null || !mounted) return;
    await _changeSemesterStart(picked);
    if (!mounted) return;
    final m = CourseStorage.mondayOf(_effectiveStart);
    _toast('第 1 周已设为 ${m.month}/${m.day}，可在顶部「第 N 周」随时修改');
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// 读取课表设置（网格线 / 非本周课程 / 背景图 / 进入 App 自动更新课表）。
  Future<void> _loadDisplaySettings() async {
    final s = await CourseStorage.loadDisplaySettings();
    if (!mounted) return;
    // v1.1.0：显示设置同步到内存缓存（供网格绘制组件直接读取）
    CourseStorage.showGridLinesCache = s['showGridLines'] != false;
    CourseStorage.showOtherWeeksCache = s['showOtherWeeks'] == true;
    CourseStorage.backgroundImageCache = (s['backgroundImage'] ?? '').toString();
    // 缺字段时给默认值（true）——老用户升级上来不会因为没这个 key 而变成「不自动更新」
    CourseStorage.autoUpdateOnLaunchCache = s['autoUpdateOnLaunch'] != false;
    setState(() {}); // 触发重建，让网格按新设置重绘
  }

  /// 手动同步课表（右上角刷新键）。
  ///
  /// 和自动同步走**同一条** [CourseSyncService.sync]，只是这里要说话：
  /// 转圈 + 一句结果提示。自动同步那两处是静默的（用户没主动要求，不该被打扰）。
  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    final r = await CourseSyncService.sync(
        ProviderScope.containerOf(context, listen: false));
    if (!mounted) return;
    setState(() => _syncing = false);
    // 只提示，不 setState 课表：课程列表由 `ref.listen(courseProvider)` 统一镜像，
    // 免得这里和监听器各写一份、日后口径不一致。
    _toast(r.message);
  }

  /// 打开「课表设置」页（v1.1.0：取代原来的「三个点」菜单）。
  ///
  /// 具体动作由本页回调转发；返回后**无条件重读显示设置**
  /// （pop(true) 之类的约定曾漏过，导致开关改完不生效）。
  Future<void> _openCourseSettings() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CourseTableSettingsPage(
        onAddCourse: () => showCourseFormSheet(
          context,
          onSave: _saveCourse,
          onDelete: (c) =>
              confirmDeleteCourse(context, c, onConfirmed: _deleteCourse),
        ),
        onEditTime: _showTimeEditDialog,
        onSyncTodos: () => _syncTodayCoursesToTodos(manual: true),
        onClearAll: _clearAll,
      ),
    ));
    await _loadDisplaySettings();
  }

  Future<void> _load() async {
    _loadDisplaySettings(); // 读网格线开关（独立异步，不阻塞课表加载）
    final list = await CourseStorage.loadCourses();
    if (!mounted) return;
    setState(() => _courses = list);
    // 进入课表自动把今日课程同步为待办（去重，不打扰）。
    await _syncTodayCoursesToTodos();
    // v2.4.0：课程已结束的自动划掉（与首页共用同一判定，避免两处口径不一致）。
    await CourseTodoService.autoCompleteFinishedCourses();
    // 首次有课表时提醒确认「第 1 周」（只弹一次）
    unawaited(_maybeAskSemesterStart());
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 将今日课程同步为待办（去重）。[manual]=true 时由用户手动触发并提示结果。
  Future<void> _syncTodayCoursesToTodos({bool manual = false}) async {
    if (_courses.isEmpty) {
      if (manual) _toast('暂无可同步的课程');
      return;
    }
    final now = DateTime.now();
    final week = CourseStorage.teachingWeek(now, _effectiveStart);
    final wd = now.weekday;
    final todayCourses =
        _courses.where((c) => c.occursOn(wd, week)).toList();
    if (todayCourses.isEmpty) {
      if (manual) _toast('今天没有课程需要同步');
      return;
    }
    final day = DateTime(now.year, now.month, now.day);
    final existing = await TodoRepository.instance.getByDate(day);
    int added = 0;
    for (final c in todayCourses) {
      final marker = '【课程】${c.name}';
      final slotText = '第${c.startSlot}-${c.endSlot}节';
      final desc = '${c.classroom} · $slotText';
      final todoId = 'course_${c.id}_${now.year}${now.month}${now.day}';
      final dup = existing.any((t) =>
          t.id == todoId ||
          (t.title == marker && (t.description ?? '').contains(slotText)));
      if (dup) continue;
      // 提醒时间：取起始节所在时间块的开始时刻
      DateTime? reminder;
      for (final b in _blocks) {
        if (c.startSlot >= b.start && c.startSlot <= b.end) {
          final parts = b.time.split('\n');
          final hhmm = parts.isNotEmpty ? parts[0].split(':') : const [];
          if (hhmm.length == 2) {
            final hh = int.tryParse(hhmm[0]);
            final mm = int.tryParse(hhmm[1]);
            if (hh != null && mm != null) {
              reminder = DateTime(now.year, now.month, now.day, hh, mm);
            }
          }
          break;
        }
      }
      final todo = Todo(
        id: todoId,
        title: marker,
        description: desc,
        date: day,
        reminderTime: reminder,
        completed: false,
      );
      await TodoRepository.instance.add(todo);
      added++;
    }
    if (manual) {
      _toast(added > 0 ? '已同步 $added 门课程到待办' : '今日课程已在待办中');
    }
  }

  /// 调整上课时间：编辑每节课的开始/结束时刻，作用于整个课表并持久化。
  Future<void> _showTimeEditDialog() async {
    final startCtls = <TextEditingController>[];
    final endCtls = <TextEditingController>[];
    for (final b in _blocks) {
      final parts = b.time.split('\n');
      startCtls.add(TextEditingController(text: parts.isNotEmpty ? parts[0] : ''));
      endCtls.add(TextEditingController(text: parts.length > 1 ? parts[1] : ''));
    }
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('调整上课时间'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('修改每节课的开始 / 结束时间（如 08:00 / 09:40），将作用于整个课表。',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey)),
              const SizedBox(height: 12),
              for (int i = 0; i < _blocks.length; i++) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: startCtls[i],
                        decoration: InputDecoration(
                          labelText: '第${_blocks[i].label}节 开始',
                          hintText: '08:00',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: endCtls[i],
                        decoration: const InputDecoration(
                          labelText: '结束',
                          hintText: '09:40',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final updated = <CourseBlock>[];
              for (int i = 0; i < _blocks.length; i++) {
                updated.add(CourseBlock(
                  label: _blocks[i].label,
                  period: _blocks[i].period,
                  start: _blocks[i].start,
                  end: _blocks[i].end,
                  time:
                      '${startCtls[i].text.trim()}\n${endCtls[i].text.trim()}',
                ));
              }
              Navigator.of(ctx).pop();
              if (!mounted) return;
              setState(() => _blocks = updated);
              CourseStorage.saveTimeBlocks(
                updated.map((b) => b.toJson()).toList(),
              );
              _toast('上课时间已更新');
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveCourse(Course course) async {
    final list = await ref.read(courseProvider.notifier).upsert(course);
    if (!mounted) return;
    setState(() => _courses = list);
    CourseReminderService.rescheduleAll(); // v2.2.21 课表变更→重排上课提醒
  }

  Future<void> _deleteCourse(Course course) async {
    final list = await ref.read(courseProvider.notifier).remove(course.id);
    if (!mounted) return;
    setState(() => _courses = list);
    CourseReminderService.rescheduleAll(); // v2.2.21 课表变更→重排上课提醒
  }



  /// 当前学期开始日 ISO 字符串（供单双周判断使用）。
  /// 公共实现见 CourseStorage.semesterStartIso（审查报告前端第 6 项）。
  ///
  /// 注：原「导入后提示学期开始周」(_promptSemesterStartAfterImport) 已删除 ——
  /// 同步改成自动/静默之后它没有调用点了；调整开学日的入口在顶部
  /// 「第 N 周」下拉里（CourseDayHeader → showCourseDatePicker），并未丢失。

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空全部课程'),
        content: const Text('将删除所有自主添加与导入的课程，确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(courseProvider.notifier).clear();
      setState(() => _courses = []);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 🔴 课程列表统一从 provider 镜像过来。
    //
    // 本页原来是「谁改谁自己 setState」（添加/删除/清空都手写一遍），
    // 这在只有本页能动课表时没问题；加入**自动同步**之后就不成立了 ——
    // 登录时、启动时那两趟同步发生在别处，本页 State 还活着的话，
    // 用户切回课表看到的会是上一次的旧列表（“我都登录了怎么还是空的”）。
    // 所以这里挂一个监听，任何来源的课表变化都同步到本页。
    ref.listen(courseProvider, (prev, next) {
      if (!mounted) return;
      if (identical(prev?.courses, next.courses)) return;
      setState(() => _courses = next.courses);
      // 本页已建好、自动同步才回来的情况（登录后 / 启动时那两趟），
      // 也要在这里补一次首次提醒 —— 否则用户永远等不到那个对话框。
      unawaited(_maybeAskSemesterStart());
    });

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = Theme.of(context).scaffoldBackgroundColor;
    final surfaceColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    final now = DateTime.now();
    final currentWeek = CourseStorage.teachingWeek(now, _effectiveStart);
    final weekOffset = _selectedWeek - currentWeek;
    final monday = now.subtract(Duration(days: now.weekday - 1 - weekOffset * 7));

    final int todayCount = _courses
        .where((c) => c.occursOn(_todayWeekday, currentWeek))
        .length;

    return Scaffold(
      backgroundColor: bgColor,
      // v2.3.9 适配：底部也留安全区，避免课程表最后一行被全面屏手势条遮挡
      body: SafeArea(
        child: Column(
          children: [
            _buildHomeHeader(context, isDark, surfaceColor, now, monday, todayCount),
            CourseDayHeader(
              selectedWeek: _selectedWeek,
              todayWeekday: _todayWeekday,
              semesterStart: _effectiveStart,
              onSemesterStartChanged: _changeSemesterStart,
              onWeekChanged: (w) {
                setState(() => _selectedWeek = w);
                // 周选择器与下方 PageView 双向同步
                if (_pageController.hasClients) {
                  _pageController.animateToPage(
                    (w - 1).clamp(0, kMaxCourseWeeks - 1),
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  );
                }
              },
              isDark: isDark,
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: kMaxCourseWeeks,
                onPageChanged: (i) {
                  final w = i + 1;
                  if (w != _selectedWeek && mounted) setState(() => _selectedWeek = w);
                },
                itemBuilder: (ctx, i) => _buildWeekGrid(i + 1, isDark, surfaceColor),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建某一教学周的课表网格。
  /// 课程卡片作为绝对定位的 overlay，支持连续多节合并成一块。
  Widget _buildWeekGrid(int week, bool isDark, Color surfaceColor) {
    return CourseWeekGrid(
      blocks: _blocks,
      todayWeekday: _todayWeekday,
      selectedWeek: week,
      courses: _courses,
      isDark: isDark,
      surfaceColor: surfaceColor,
      onOpenAdd: (weekday, startSlot, endSlot) => showCourseFormSheet(
        context,
        presetWeekday: weekday,
        presetStartSlot: startSlot,
        presetEndSlot: endSlot,
        onSave: _saveCourse,
        onDelete: (c) => confirmDeleteCourse(
          context,
          c,
          onConfirmed: _deleteCourse,
        ),
      ),
      onOpenDetail: (course) => showCourseDetailSheet(
        context,
        course,
        onDelete: (c) => confirmDeleteCourse(
          context,
          c,
          onConfirmed: _deleteCourse,
        ),
        onEdit: (c) => showCourseFormSheet(
          context,
          course: c,
          onSave: _saveCourse,
          onDelete: (x) => confirmDeleteCourse(
            context,
            x,
            onConfirmed: _deleteCourse,
          ),
        ),
      ),
    );
  }

  /// 首页风格顶部卡片：日期 + 教学周 + 今日课程数 + 刷新/导入/更多，铺满宽度。
  /// 已按要求缩小高度，给下方课表留出更大空间。
  Widget _buildHomeHeader(
    BuildContext context,
    bool isDark,
    Color surfaceColor,
    DateTime now,
    DateTime monday,
    int todayCount,
  ) {
    final subColor = isDark ? Colors.grey.shade400 : const Color(0xFF6B7280);
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 2, 10, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: context.borderColor),
        color: surfaceColor,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${now.year}/${now.month}/${now.day}',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      '第$_selectedWeek周',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: subColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        '今日 $todayCount 门',
                        style:  TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.primaryColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: _kAlarmBtn,
                icon:  Icon(Icons.alarm_rounded, color: AppTheme.primaryColor),
                tooltip: '上课提醒',
                onPressed: () {
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const ReminderSettingsPage()));
                },
              ),
              // 右上角刷新键 = **手动同步课表**（v1.2.0）。
              // 原来这里是「重读本地」，旁边还有个云朵按钮专门从教务导入。
              // 开源版把云朵按钮去掉了（它点开只有「一键导入」一个选项，
              // 属于白多一次点击），同步改由「登录后 / 进入 App（可关）」自动做，
              // 想手动更新时用户点这个刷新键 —— 直觉上它就是「更新课表」。
              IconButton(
                icon: _syncing
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          valueColor:
                              AlwaysStoppedAnimation(AppTheme.primaryColor),
                        ),
                      )
                    : Icon(Icons.refresh_rounded,
                        color: isDark
                            ? Colors.grey.shade500
                            : const Color(0xFF6B7280)),
                tooltip: '同步课表',
                onPressed: _syncing ? null : _syncNow,
              ),
              // v1.1.0：右上角「三个点」→ 齿轮（进课表设置页）。
              // 原菜单四项（添加课程 / 调整上课时间 / 同步今日课程到待办 / 清空全部课程）
              // 已全部搬进设置页 —— 入口更直观，也不再和页面内「添加课程」主按钮重复。
              IconButton(
                key: _kMoreBtn,
                icon: Icon(Icons.settings_rounded,
                    color: isDark
                        ? Colors.grey.shade500
                        : const Color(0xFF6B7280)),
                tooltip: '课表设置',
                onPressed: _openCourseSettings,
              ),
            ],
          ),
        ],
      ),
    );
  }

}


