import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/course_model.dart';
import '../models/todo.dart';
import '../repositories/todo_repository.dart';
import '../services/api_service.dart';
import '../services/course_reminder_service.dart';
import '../services/course_storage.dart';
import '../providers/course_provider.dart';
import '../providers/user_config_provider.dart';
import '../services/course_todo_service.dart';
import 'reminder_settings_page.dart';
import '../services/storage_service.dart';
import '../services/auth_gate.dart';
import '../theme/app_theme.dart';
import '../widgets/course_day_header.dart';
import '../widgets/course_date_picker.dart';
import 'course/course_form_sheet.dart';
import 'course/course_import_dialogs.dart';
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
  final GlobalKey _kImportBtn = GlobalKey();
  final GlobalKey _kMoreBtn = GlobalKey();

  List<Course> _courses = [];
  bool _loading = false;
  int _seconds = 0;
  Timer? _importTimer;
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
    await CourseStorage.saveSemesterStart(aligned);
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

  @override
  void dispose() {
    _importTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  /// 读取课表显示设置（当前只有网格线开关）。
  Future<void> _loadDisplaySettings() async {
    final s = await CourseStorage.loadDisplaySettings();
    if (!mounted) return;
    // v1.1.0：三项显示设置同步到内存缓存（供网格绘制组件直接读取）
    final grid = s['showGridLines'] != false;
    CourseStorage.showGridLinesCache = grid;
    CourseStorage.showOtherWeeksCache = s['showOtherWeeks'] == true;
    CourseStorage.backgroundImageCache = (s['backgroundImage'] ?? '').toString();
    setState(() {}); // 触发重建，让网格按新设置重绘
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

  /// 导入后提示学期开始周（v2.1.0）：默认 9/7 为第 1 周，可更改。
  Future<void> _promptSemesterStartAfterImport(DateTime autoStart, int count) async {
    if (!mounted) return;
    final defaultStart = CourseStorage.mondayOf(DateTime(autoStart.year, 9, 7));
    final picked = await showCourseDatePicker(
      context: context,
      initialDate: defaultStart,
      firstDate: DateTime(autoStart.year - 1, 1, 1),
      lastDate: DateTime(autoStart.year + 1, 12, 31),
      helpText: '选择本学期第 1 周的周一（默认 9 月 7 日）',
    );
    if (picked != null) {
      await _changeSemesterStart(picked);
      if (!mounted) return;
    } else {
      // 未更改：确认当前默认并提示已应用
      if (!mounted) return;
      final monday = CourseStorage.mondayOf(_effectiveStart);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导入 $count 门课程，第 1 周从 ${monday.month}/${monday.day} 开始'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

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
              IconButton(
                key: _kImportBtn,
                icon:  Icon(Icons.cloud_download_outlined, color: AppTheme.primaryColor),
                tooltip: '从教务系统导入',
onPressed: _loading
                        ? null
                        : () => showImportSheet(
                              context,
                              onOpenJwcImport: _showJwcImportSheet,
                              onConfirmParsed: _confirmParsedImport,
                            ),
              ),
              IconButton(
                icon: Icon(Icons.refresh_rounded, color: isDark ? Colors.grey.shade500 : const Color(0xFF6B7280)),
                tooltip: '刷新课表',
                onPressed: _load,
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


  Widget courseField(String label, Widget child, bool isDark) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? Colors.grey.shade400 : const Color(0xFF374151))),
          ),
          child,
        ],
      );

  /// 折叠展开项（节数 / 周数 / 主题色）。
  void _showJwcImportSheet() async {
    // 配置来自 userConfigProvider（唯一数据源）
    final saved = await ref.read(userConfigProvider.notifier).ensureLoaded();
    if (!mounted) return;
    if (saved.username.trim().isEmpty) {
      // 统一提示：下方弹横条「请登录后才能使用」
      AuthGate.showLoginRequired(context);
      return;
    }
    // 学年下拉动态化（代码审查报告前端第 7 项）：以当前年份为中心生成
    // 上一/本/下一学年，默认当前学年，免去每年改代码发版。
    final nowYear = DateTime.now().year;
    final yearList = [nowYear - 1, nowYear, nowYear + 1];
    String xnm = '$nowYear';
    String xqm = '3';

    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 16),
                Text('从教务系统导入', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.textPrimary)),
                const SizedBox(height: 4),
                Text('将使用已绑定的统一认证账号（${saved.username.trim()}）同步课程；导入的课程会替换上次的教务导入，保留你自主添加的课程。',
                    style: TextStyle(fontSize: 12.5, color: isDark ? Colors.grey.shade500 : const Color(0xFF6B7280))),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: courseField('学年', DropdownButtonFormField<String>(
                        value: xnm,
                        items: [
                          for (final y in yearList)
                            DropdownMenuItem(
                              value: '$y',
                              child: Text('$y-${y + 1}'),
                            ),
                        ],
                        onChanged: (v) => setModal(() => xnm = v ?? xnm),
                        decoration: const InputDecoration(),
                      ), isDark),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: courseField('学期', DropdownButtonFormField<String>(
                        value: xqm,
                        items: const [
                          DropdownMenuItem(value: '3', child: Text('第1学期')),
                          DropdownMenuItem(value: '12', child: Text('第2学期')),
                        ],
                        onChanged: (v) => setModal(() => xqm = v ?? xqm),
                        decoration: const InputDecoration(),
                      ), isDark),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _loading
                        ? null
                        : () async {
                            final messenger = ScaffoldMessenger.of(context);
                            final navigator = Navigator.of(ctx);
                            setModal(() => _loading = true);
                            _seconds = 0;
                            _importTimer?.cancel();
                            _importTimer = Timer.periodic(const Duration(seconds: 1), (_) => setModal(() => _seconds++));
                            try {
                              // 不传账密：用本机已保存的统一认证凭证
                              final resp = await ApiService.fetchSchedule(
                                xnm: xnm,
                                xqm: xqm,
                              );
                              final data = resp['data'] as Map<String, dynamic>? ?? {};
                              final rawList = data['courses'] as List<dynamic>? ?? [];
                              final serverCourses = <Course>[];
                              for (final item in rawList) {
                                if (item is! Map) continue;
                                final m = Map<String, dynamic>.from(item);
                                // ⚠️ 抓取器返回的是**字符串**字段：
                                //    weekday = "1".."7"，slots = "1-2"（区间串）。
                                //    这里必须转换，不能直接当成 int / start_slot。
                                final wd = _parseWeekday(m['weekday']);
                                if (wd == null) continue;
                                final (start, end) = _parseSlots(
                                    m['slots'], m['start_slot'], m['end_slot']);
                                final cname =
                                    (m['name'] ?? '').toString().trim();
                                serverCourses.add(Course(
                                  id: 'srv_${cname}_$wd-$start',
                                  name: cname.isEmpty ? '未命名' : cname,
                                  teacher: (m['teacher'] ?? '').toString().trim(),
                                  classroom:
                                      (m['classroom'] ?? '').toString().trim(),
                                  weekday: wd,
                                  startSlot: start,
                                  endSlot: end,
                                  weeks: (m['weeks'] ?? '').toString().trim(),
                                  colorValue: colorForName(cname),
                                  source: CourseSource.server,
                                ));
                              }
                              // 教务没返回课程 → 明确告知，且**不动**已有课表
                              if (serverCourses.isEmpty) {
                                messenger.showSnackBar(const SnackBar(
                                    content: Text('教务系统没有返回课程，请确认所选学期是否正确')));
                                return;
                              }
                              final merged = await ref.read(courseProvider.notifier).mergeServer(serverCourses);
                              // 自动定位开学日期（按学期估算），用户可在「选择周数」里手动调整
                              final autoStart = CourseStorage.autoSemesterStart(xnm, xqm);
                              await ref.read(courseProvider.notifier).setSemesterStart(autoStart);
                              if (!mounted) return;
                              setState(() {
                                _courses = merged;
                                _semesterStart = autoStart;
                                _selectedWeek = CourseStorage.teachingWeek(DateTime.now(), autoStart);
                              });
                              navigator.pop();
                              messenger.showSnackBar(
                                const SnackBar(
                                  content: Text('导入成功，本数据从教务系统提出，如有bug请使用建议工具发送'),
                                ),
                              );
                              // 导入后自动同步推送快照 + 提示学期开始周（默认 9/7 为第 1 周，可更改）
                              _promptSemesterStartAfterImport(autoStart, merged.length);
                            } catch (e) {
                              if (!mounted) return;
                              final emsg = e.toString().replaceFirst('Exception: ', '');
                              // 失败就一条横条：未登录/会话过期/其它都直接展示原因
                              // （文案已由服务层统一成中文，不必在这里分情况判断）
                              messenger.showSnackBar(
                                SnackBar(content: Text('导入失败：$emsg')),
                              );
                            } finally {
                              if (mounted) setModal(() => _loading = false);
                              _importTimer?.cancel();
                              _importTimer = null;
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: _loading
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, valueColor: AlwaysStoppedAnimation(Colors.white)))
                        : const Text('导入', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  ),
                ),
                if (_loading)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                         SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(AppTheme.primaryColor))),
                        const SizedBox(width: 8),
                        Text('正在从教务系统导入，已等待 $_seconds 秒', style: TextStyle(fontSize: 12.5, color: isDark ? Colors.grey.shade400 : const Color(0xFF6B7280))),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }




  /// 星期：抓取器给的是字符串（"1".."7"，个别版本会是「周一」），统一转成 1..7。
  /// 返回 null 表示无法识别 → 该条跳过。
  static int? _parseWeekday(Object? v) {
    if (v == null) return null;
    if (v is int) return (v >= 1 && v <= 7) ? v : null;
    final s = v.toString().trim();
    final n = int.tryParse(s);
    if (n != null) return (n >= 1 && n <= 7) ? n : null;
    const cn = {
      '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 7, '天': 7,
    };
    for (final e in cn.entries) {
      if (s.contains(e.key)) return e.value;
    }
    return null;
  }

  /// 节次：抓取器给的是区间串（"1-2" / "3~4"），兼容分开的 start_slot/end_slot。
  /// 多段（"1-2,3-4"）只取第一段。
  static (int, int) _parseSlots(
      Object? slots, Object? startRaw, Object? endRaw) {
    final src = (slots ?? '').toString().split(',').first;
    final nums = RegExp(r'\d+')
        .allMatches(src)
        .map((m) => int.parse(m.group(0)!))
        .toList()
      ..sort();
    if (nums.isNotEmpty) return (nums.first, nums.last);
    final st = int.tryParse((startRaw ?? '').toString().trim());
    if (st != null) {
      return (st, int.tryParse((endRaw ?? '').toString().trim()) ?? st);
    }
    return (1, 1);
  }

  /// 文本/表格解析出的课程 → 合并进本地课程表（保留手工课程，追加新导入课程）。
  void _confirmParsedImport(List<Course> parsed, {required String sourceLabel}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 用「课程名+周几+起始节次」做去重：与已有课程重名同周次则跳过
    final existing = _courses;
    // v2.3.7 修复：去重键补上周次——同一门课不同周次段（如 PDF 里「1-7周 陈泽」+「8周 喻小勇」）
    // 原先会因同 课程名-周几-节次 被误去重，导致后一段课程丢失。
    String keyOf(Course c) => '${c.name}-${c.weekday}-${c.startSlot}-${c.weeks}';
    final seen = existing.map(keyOf).toSet();
    final fresh = parsed.where((c) => seen.add(keyOf(c))).toList();
    final dupCount = parsed.length - fresh.length;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('确认导入（$sourceLabel）', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('识别出 ${parsed.length} 门课程${dupCount > 0 ? '，其中 $dupCount 门与现有课程重复已自动跳过' : ''}。'),
              const SizedBox(height: 8),
              Text('解析前 5 门预览：', style: TextStyle(fontSize: 12.5, color: isDark ? Colors.grey.shade500 : const Color(0xFF6B7280))),
              const SizedBox(height: 4),
              ...fresh.take(5).map((c) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('· ${c.name}　周${c.weekday} 第${c.startSlot}节${c.weeks.isNotEmpty ? ' ${c.weeks}' : ''}'
                    '${c.classroom.isNotEmpty ? ' @${c.classroom}' : ''}',
                    style: const TextStyle(fontSize: 12.5)),
              )),
              const SizedBox(height: 4),
              Text('若格式识别不对，可在「添加课程」中单独修改。', style: TextStyle(fontSize: 11, color: isDark ? Colors.grey.shade600 : const Color(0xFF9CA3AF))),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消', style: TextStyle(color: Colors.grey))),
          TextButton(
            onPressed: () async {
              // 合并：保留现有手工/教务课程，仅追加本次解析的课程（去重后）
              final merged = List<Course>.from(_courses);
              for (final c in fresh) {
                merged.add(c);
              }
              // 跨 await 前先固定 Navigator / Messenger：此后不再触碰可能已失效的
              // BuildContext（`ctx` 属于弹窗，State.mounted 管不到它）。
              final navigator = Navigator.of(ctx);
              final messenger = ScaffoldMessenger.of(context);
              await ref.read(courseProvider.notifier).replaceAll(merged);
              if (!mounted) return;
              setState(() {
                _courses = merged;
                _semesterStart ??= CourseStorage.defaultSemesterStart(DateTime.now());
              });
              navigator.pop();
              messenger.showSnackBar(SnackBar(content: Text('已导入 ${fresh.length} 门课程')));
              CourseReminderService.rescheduleAll(); // v2.2.21 导入课表→重排上课提醒
            },
            child: const Text('确认导入',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}


