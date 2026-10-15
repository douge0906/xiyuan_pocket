import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/course_model.dart';
import '../../services/course_storage.dart';
import '../../services/storage_service.dart';
import '../../services/widget_sync_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/course_style_preview.dart';
import '../user/user_cards.dart';

/// 课表设置页（v1.3.0，2026-10-13 全滑杆版）。
///
/// 结构：**顶部实时预览**（固定）+ 下方可折叠板块 ——
///   ① 课程表网格调节：网格线开关 / **粗细** / **深浅** / 非本周课程 / 隐藏节次时间
///   ② 课程块：**色彩方案（方案一 / 方案二 / 方案三）** / **圆角 / 内边距 / 块间距 /
///      不透明度 / 边框粗细 / 虚线 / 虚线密度** / 显示老师 / 显示教室
///      —— 除色彩方案外全部连续滑杆（用户要求：不再给几档预设）
///   ③ 界面显示：背景图 / 隐藏日期
///   ④ 同步：进入 App 自动更新课表
///   ⑤ 课程管理：添加 / 调时间 / 同步待办 / 清空
///
/// 交互约定（v1.3.0）：
///   · 拖滑杆的过程中**实时更新内存缓存并重绘预览**（不落盘，避免高频 IO）；
///   · 松手（onChangeEnd）才写入存储；
///   · 开关同样即时生效（缓存 + 存储）。
class CourseTableSettingsPage extends StatefulWidget {
  const CourseTableSettingsPage({
    super.key,
    required this.onAddCourse,
    required this.onEditTime,
    required this.onSyncTodos,
    required this.onClearAll,
  });

  /// 添加课程（课表页弹添加表单）。
  final VoidCallback onAddCourse;

  /// 调整上课时间（课表页的时间编辑弹窗）。
  final VoidCallback onEditTime;

  /// 同步今日课程到待办。
  final VoidCallback onSyncTodos;

  /// 清空全部课程（课表页内部会二次确认）。
  final VoidCallback onClearAll;

  @override
  State<CourseTableSettingsPage> createState() =>
      _CourseTableSettingsPageState();
}

class _CourseTableSettingsPageState extends State<CourseTableSettingsPage> {
  Map<String, dynamic> _display = CourseStorage.defaultDisplaySettings();

  /// 已忽略的冲突课程签名（v1.6.0：冲突弹窗里删掉的教务课，防同步复活）。
  List<String> _dropped = const <String>[];

  /// 读取显示设置的 Future 缓存：v1.1.1 修复「开关先显示默认(true)、
  /// 读完存储再跳成实际值」的闪烁（用户反馈像抖动）。
  Future<Map<String, dynamic>>? _future;

  // ---- 预览数据（v1.4.0）：真实课程 + 真实周次/日期 ----
  List<Course> _previewCourses = const [];
  int _previewWeek = 1;
  DateTime _previewMonday = CourseStorage.mondayOf(DateTime.now());
  int _previewToday = DateTime.now().weekday;

  /// 哪些板块是展开的（2026-10-13 v1.3.0：外观两组默认展开 —— 常调的就是它们；
  /// 其余默认收起，点标题可以随时展开/折叠）。
  final Set<String> _expanded = {'grid', 'layout', 'blocks'};

  bool get _showGridLines => _display['showGridLines'] != false;
  bool get _showOtherWeeks => _display['showOtherWeeks'] == true;
  String get _bgPath => (_display['backgroundImage'] ?? '').toString();
  bool get _hasBg => _bgPath.isNotEmpty && File(_bgPath).existsSync();

  /// 「进入 App 自动更新课表」。2026-10-13 起**默认关闭**（用户要求）。
  bool get _autoUpdateOnLaunch => _display['autoUpdateOnLaunch'] == true;

  // ---- 外观（v1.3.0：全部连续值，滑杆直调）----
  double get _gridLineWidth => _asDouble('gridLineWidth', 1.0);
  double get _gridLineDepth => _asDouble('gridLineDepth', 0.5);
  double get _blockRadius => _asDouble('blockRadius', 6);
  double get _blockPad => _asDouble('blockPad', 3.0);
  double get _blockMargin => _asDouble('blockMargin', 1.8);
  double get _blockOpacity => _asDouble('blockOpacity', 1.0);
  double get _blockBorderWidth => _asDouble('blockBorderWidth', 0.8);
  bool get _blockBorderDashed => _display['blockBorderDashed'] == true;
  double get _blockDashDensity => _asDouble('blockDashDensity', 1.0);

  /// 非本周课程颜色清淡度（v1.5.0：0.45~0.85，越大越淡）。
  double get _otherWeeksDim => _asDouble('otherWeeksDim', 0.75);

  // ---- 课表布局（v1.6.4，仿掌上徐工的「课表网格」组）----

  /// 课节高度：0 = 自动（按可用高度均分）。
  double get _rowHeight => _asDouble('rowHeight', 0);
  double get _timeColWidth => _asDouble('timeColWidth', 48);
  double get _dateRowHeight => _asDouble('dateRowHeight', 56);
  bool get _showTeacherOnCard => _display['showTeacherOnCard'] != false;
  bool get _showClassroomOnCard => _display['showClassroomOnCard'] != false;
  bool get _hideSectionTime => _display['hideSectionTime'] == true;
  bool get _hideDateRow => _display['hideDateRow'] == true;

  double _asDouble(String k, double fallback) =>
      double.tryParse('${_display[k] ?? fallback}') ?? fallback;

  @override
  void initState() {
    super.initState();
    _future = CourseStorage.loadDisplaySettings();
    _loadPreviewData();
    // v1.6.0：已忽略的冲突课程（用于设置页的恢复入口）
    StorageService.loadDroppedCourseKeys().then((v) {
      if (mounted) setState(() => _dropped = v);
    });
  }

  /// 加载预览数据（v1.4.0）：当前课表的课程 + 当前教学周/周一/今天。
  ///
  /// 对齐掌上徐工的做法：预览**优先显示真实课表**（组件内部按本周过滤，
  /// 本周没课才回退到内置示例），日期栏也显示真实的周次与日期。
  Future<void> _loadPreviewData() async {
    final courses = await CourseStorage.loadCourses();
    final start = await CourseStorage.loadSemesterStart() ??
        CourseStorage.defaultSemesterStart(DateTime.now());
    final now = DateTime.now();
    final week = CourseStorage.teachingWeek(now, start).clamp(1, 25);
    if (!mounted) return;
    setState(() {
      _previewCourses = courses;
      _previewWeek = week;
      _previewMonday = start.add(Duration(days: (week - 1) * 7));
      _previewToday = now.weekday;
    });
  }

  /// 开关键等「一次性」变更：立即生效 + 存盘。
  Future<void> _set(String key, Object value) async {
    final next = <String, dynamic>{..._display, key: value};
    // 先同步缓存再 setState：顶部实时预览与返回课表后的网格都读缓存
    CourseStorage.applyDisplayToCache(next);
    setState(() {
      _display = next;
      // 立即把 Future 指向内存值：避免 FutureBuilder 重建时回读存储造成抖动
      _future = Future<Map<String, dynamic>>.value(next);
    });
    await CourseStorage.saveDisplaySettings(next);
    // v1.6.9：换色彩方案时桌面小组件的课程色条也要跟着变色（重新下发一次）
    if (key == 'scheme') unawaited(WidgetSyncService.syncTodayCourses());
  }

  /// 滑杆拖动中：只更新内存（缓存 + 本地 state），预览立即重绘；**不写盘**。
  void _liveSlider(String key, double value) {
    final next = <String, dynamic>{..._display, key: value};
    CourseStorage.applyDisplayToCache(next);
    setState(() {
      _display = next;
      _future = Future<Map<String, dynamic>>.value(next);
    });
  }

  /// 滑杆松手：把当前值写入存储（这时候 _display 已经是最新值）。
  Future<void> _commitSliders() async {
    await CourseStorage.saveDisplaySettings(_display);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13)),
        duration: const Duration(seconds: 2),
      ));
  }

  /// 选一张图作为课表背景（与在线版同一套逻辑）。
  ///
  /// image_picker 返回的是**临时缓存路径**，系统随时可能清掉，直接存会导致
  /// 背景图「过几天就丢」→ 这里把图片拷贝到应用文档目录持久化。
  Future<void> _pickBackground() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final ext = picked.path.contains('.')
          ? picked.path.split('.').last.toLowerCase()
          : 'jpg';
      final safe = ['jpg', 'jpeg', 'png', 'webp'].contains(ext) ? ext : 'jpg';
      final target = File('${docs.path}/course_background.$safe');
      // 换图时清掉旧后缀残留（旧图 png 新图 jpg 之类）
      for (final e in ['jpg', 'jpeg', 'png', 'webp']) {
        final old = File('${docs.path}/course_background.$e');
        if (await old.exists()) await old.delete();
      }
      if (!mounted) return;
      await picked.saveTo(target.path);
      await _set('backgroundImage', target.path);
      _toast('背景图已设置，上方预览可见');
    } catch (_) {
      _toast('设置失败，请重试');
    }
  }

  /// 清除背景图：同时删掉文档目录里的图片文件。
  Future<void> _clearBackground() async {
    final p = _bgPath;
    await _set('backgroundImage', '');
    if (p.isNotEmpty) {
      try {
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    _toast('已清除背景图');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('课表设置',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(
                child: CircularProgressIndicator(strokeWidth: 2.5));
          }
          // 用已加载的值渲染，避免开关先显示默认值再跳变（用户反馈的抖动）
          _display = snap.data!;
          return Column(
            children: [
              // ---- 顶部实时预览（固定不滚：调下面的滑杆时始终可见）----
              // ⚠️ CourseStylePreview 不能加 const：const 实例在父级重建时会被
              // identical 短路跳过、不重绘（2026-10-13 用户反馈"修改后不变"的根因）。
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: userCard(
                  context,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: CourseStylePreview(
                    courses: _previewCourses,
                    week: _previewWeek,
                    monday: _previewMonday,
                    todayWeekday: _previewToday,
                  ),
                ),
              ),
              // ---- 设置板块（可滚动 + 可折叠）----
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    _collapsible(
                      key: 'grid',
                      icon: Icons.grid_on_rounded,
                      title: '课程表网格调节',
                      children: [
                        _switchTile(
                          icon: Icons.grid_on_rounded,
                          title: '显示网格线',
                          value: _showGridLines,
                          onChanged: (v) => _set('showGridLines', v),
                        ),
                        _sliderTile(
                          icon: Icons.line_weight_rounded,
                          title: '网格线粗细',
                          value: _gridLineWidth,
                          min: 0.5,
                          max: 2.5,
                          divisions: 20,
                          format: (v) => '${v.toStringAsFixed(1)}px',
                          enabled: _showGridLines,
                          onChanged: (v) => _liveSlider('gridLineWidth', v),
                          onChangeEnd: _commitSliders,
                        ),
                        _sliderTile(
                          icon: Icons.opacity_rounded,
                          title: '网格线深浅',
                          value: _gridLineDepth,
                          min: 0,
                          max: 1,
                          divisions: 20,
                          format: (v) => '${(v * 100).round()}%',
                          enabled: _showGridLines,
                          onChanged: (v) => _liveSlider('gridLineDepth', v),
                          onChangeEnd: _commitSliders,
                        ),
                        _switchTile(
                          icon: Icons.calendar_view_week_rounded,
                          title: '显示非本周课程',
                          value: _showOtherWeeks,
                          onChanged: (v) => _set('showOtherWeeks', v),
                        ),
                        _sliderTile(
                          icon: Icons.opacity_rounded,
                          // v1.6.9：非本周课程统一转成**淡灰**（保留各课原色明暗差异），
                          // 这根滑杆控制整体灰的深浅 —— 越大越淡。
                          title: '非本周课程淡化',
                          value: _otherWeeksDim,
                          min: 0.45,
                          max: 0.85,
                          divisions: 8,
                          format: (v) => '${(v * 100).round()}%',
                          // 开关关着时置灰（与「显示网格线」↔粗细/深浅同一模式）
                          enabled: _showOtherWeeks,
                          onChanged: (v) => _liveSlider('otherWeeksDim', v),
                          onChangeEnd: _commitSliders,
                        ),
                        // v1.6.0：冲突弹窗里删掉的教务课在这里恢复
                        if (_dropped.isNotEmpty) ...[
                          Divider(height: 1, color: context.borderColor),
                          _entryTile(
                            icon: Icons.delete_sweep_rounded,
                            title: '已忽略的冲突课程',
                            value: '${_dropped.length} 门',
                            onTap: _showRestoreDialog,
                          ),
                        ],
                        _switchTile(
                          icon: Icons.schedule_rounded,
                          title: '隐藏节次时间',
                          value: _hideSectionTime,
                          onChanged: (v) => _set('hideSectionTime', v),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // v1.6.4：「课表布局」（仿掌上徐工的「课表网格」组）——
                    // 课节高度 / 时间列宽度 / 日期栏高度。
                    _collapsible(
                      key: 'layout',
                      icon: Icons.dashboard_customize_rounded,
                      title: '课表布局',
                      children: [
                        _sliderTile(
                          icon: Icons.height_rounded,
                          title: '课节高度',
                          value: _rowHeight,
                          min: 0,
                          max: 90,
                          divisions: 18,
                          // 0 = 自动：按屏幕可用高度均分（默认，与改造前一致）
                          format: (v) =>
                              v <= 0 ? '自动' : '${v.round()}',
                          onChanged: (v) => _liveSlider('rowHeight', v),
                          onChangeEnd: _commitSliders,
                        ),
                        _sliderTile(
                          icon: Icons.view_sidebar_rounded,
                          title: '时间列宽度',
                          value: _timeColWidth,
                          min: 28,
                          max: 72,
                          divisions: 22,
                          format: (v) => '${v.round()}',
                          // 「隐藏节次时间」开着时时间列不存在 → 置灰
                          enabled: !_hideSectionTime,
                          onChanged: (v) => _liveSlider('timeColWidth', v),
                          onChangeEnd: _commitSliders,
                        ),
                        _sliderTile(
                          icon: Icons.calendar_today_rounded,
                          title: '日期栏高度',
                          value: _dateRowHeight,
                          min: 36,
                          max: 88,
                          divisions: 26,
                          format: (v) => '${v.round()}',
                          // 「隐藏日期行」开着时日期栏不存在 → 置灰
                          enabled: !_hideDateRow,
                          onChanged: (v) => _liveSlider('dateRowHeight', v),
                          onChangeEnd: _commitSliders,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _collapsible(
                      key: 'blocks',
                      icon: Icons.crop_square_rounded,
                      title: '课程块',
                      children: [
                        // v1.6.9：色彩方案（方案一 / 方案二 / 方案三）——
                        // 只在渲染期换色，课程本身的「主题色」不被改写。
                        _schemeTile(),
                        Divider(height: 1, color: context.borderColor),
                        _sliderTile(
                          icon: Icons.rounded_corner_rounded,
                          title: '圆角',
                          value: _blockRadius,
                          min: 0,
                          max: 24,
                          divisions: 24,
                          format: (v) => '${v.round()}px',
                          onChanged: (v) => _liveSlider('blockRadius', v),
                          onChangeEnd: _commitSliders,
                        ),
                        _sliderTile(
                          icon: Icons.padding_rounded,
                          title: '内边距',
                          value: _blockPad,
                          min: 0,
                          max: 8,
                          divisions: 16,
                          format: (v) => '${_fmtNum(v)}px',
                          onChanged: (v) => _liveSlider('blockPad', v),
                          onChangeEnd: _commitSliders,
                        ),
                        _sliderTile(
                          icon: Icons.space_bar_rounded,
                          title: '块间距',
                          value: _blockMargin,
                          min: 0,
                          max: 6,
                          divisions: 12,
                          format: (v) => '${_fmtNum(v)}px',
                          onChanged: (v) => _liveSlider('blockMargin', v),
                          onChangeEnd: _commitSliders,
                        ),
                        _sliderTile(
                          icon: Icons.gradient_rounded,
                          title: '不透明度',
                          value: _blockOpacity,
                          min: 0.1,
                          max: 1,
                          divisions: 90,
                          format: (v) => '${(v * 100).round()}%',
                          onChanged: (v) => _liveSlider('blockOpacity', v),
                          onChangeEnd: _commitSliders,
                        ),
                        _sliderTile(
                          icon: Icons.border_style_rounded,
                          title: '边框粗细',
                          value: _blockBorderWidth,
                          min: 0,
                          max: 2,
                          divisions: 20,
                          format: (v) => v < 0.05 ? '无' : '${v.toStringAsFixed(1)}px',
                          onChanged: (v) => _liveSlider('blockBorderWidth', v),
                          onChangeEnd: _commitSliders,
                        ),
                        _switchTile(
                          icon: Icons.more_horiz_rounded,
                          title: '虚线边框',
                          value: _blockBorderDashed,
                          enabled: _blockBorderWidth > 0.05,
                          onChanged: (v) => _set('blockBorderDashed', v),
                        ),
                        _sliderTile(
                          icon: Icons.density_small_rounded,
                          title: '虚线密度',
                          value: _blockDashDensity,
                          min: 0.5,
                          max: 2,
                          divisions: 15,
                          format: (v) => '${v.toStringAsFixed(1)}×',
                          enabled: _blockBorderWidth > 0.05 && _blockBorderDashed,
                          onChanged: (v) => _liveSlider('blockDashDensity', v),
                          onChangeEnd: _commitSliders,
                        ),
                        _switchTile(
                          icon: Icons.person_outline_rounded,
                          title: '显示任课老师',
                          value: _showTeacherOnCard,
                          onChanged: (v) => _set('showTeacherOnCard', v),
                        ),
                        _switchTile(
                          icon: Icons.meeting_room_outlined,
                          title: '显示教室',
                          value: _showClassroomOnCard,
                          onChanged: (v) => _set('showClassroomOnCard', v),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _collapsible(
                      key: 'display',
                      icon: Icons.wallpaper_rounded,
                      title: '界面显示',
                      children: [
                        _imageTile(),
                        _switchTile(
                          icon: Icons.today_rounded,
                          title: '隐藏日期',
                          value: _hideDateRow,
                          onChanged: (v) => _set('hideDateRow', v),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // 「同步」不再折叠（用户要求：直接放外面常显）。
                    userCard(
                      context,
                      padding: EdgeInsets.zero,
                      child: _switchTile(
                        icon: Icons.sync_rounded,
                        title: '进入 App 自动更新课表',
                        value: _autoUpdateOnLaunch,
                        onChanged: (v) => _set('autoUpdateOnLaunch', v),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _collapsible(
                      key: 'courses',
                      icon: Icons.playlist_add_check_rounded,
                      title: '课程管理',
                      children: [
                        _actionTile(
                          icon: Icons.add_circle_outline_rounded,
                          title: '添加课程',
                          // v1.1.1：不再自动返回课表（用户反馈「点设置就跳回主页」很突兀）
                          onTap: widget.onAddCourse,
                        ),
                        _actionTile(
                          icon: Icons.schedule_rounded,
                          title: '调整上课时间',
                          onTap: widget.onEditTime,
                        ),
                        _actionTile(
                          icon: Icons.playlist_add_check_rounded,
                          title: '同步今日课程到待办',
                          onTap: widget.onSyncTodos,
                        ),
                        _actionTile(
                          icon: Icons.delete_sweep_rounded,
                          title: '清空全部课程',
                          danger: true,
                          onTap: widget.onClearAll,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // v1.6.2：恢复默认设置（外观/显示类设置回到出厂默认）
                    userCard(
                      context,
                      padding: EdgeInsets.zero,
                      child: _actionTile(
                        icon: Icons.settings_backup_restore_rounded,
                        title: '恢复默认设置',
                        onTap: _resetDisplaySettings,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 恢复默认设置（v1.6.2）：外观/显示类设置全部回到出厂默认
  /// （网格线、线宽深浅、非本周课程颜色、背景图、圆角、内边距、边框…）。
  /// 课程内容与「已忽略的冲突课程」不受影响。
  Future<void> _resetDisplaySettings() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLg)),
        title: const Text('恢复默认设置',
            style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold)),
        content: const Text(
            '将把课表的外观与显示设置恢复为默认值'
            '（网格线、颜色、圆角、背景图等）。\n课程内容不受影响。',
            style: TextStyle(fontSize: 13.5, height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(color: Colors.grey))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primaryColor),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final def = CourseStorage.defaultDisplaySettings();
    await CourseStorage.saveDisplaySettings(def);
    CourseStorage.applyDisplayToCache(def);
    if (!mounted) return;
    setState(() => _display = def);
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已恢复默认设置')));
  }

  String _fmtNum(double v) =>
      (v - v.roundToDouble()).abs() < 0.001
          ? v.round().toString()
          : v.toStringAsFixed(1);

  /// 可折叠板块（2026-10-13）：标题行点一下展开/收起，收起时只占一行。
  Widget _collapsible({
    required String key,
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    final open = _expanded.contains(key);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(Divider(height: 1, color: context.borderColor));
      rows.add(children[i]);
    }
    return userCard(
      context,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() {
              if (open) {
                _expanded.remove(key);
              } else {
                _expanded.add(key);
              }
            }),
            child: SizedBox(
              height: 52,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(icon, size: 20, color: AppTheme.primaryColor),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(title,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: context.textPrimary,
                          )),
                    ),
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Icon(Icons.keyboard_arrow_down_rounded,
                          size: 20, color: context.textTertiary),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (open) ...[
            Divider(height: 1, color: context.borderColor),
            ...rows,
          ],
        ],
      ),
    );
  }

  /// 开关行：**单行**（左图标 + 标题 + 右侧开关）。
  /// [enabled] 为 false 时置灰不可点（例如「显示网格线」关着时的粗细滑杆）。
  /// 入口行（v1.6.0，恢复已忽略的冲突课程）：图标 + 标题 + 右侧值。
  Widget _entryTile({
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
  }) {
    return ListTile(
      onTap: onTap,
      dense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(icon, size: 20, color: context.textTertiary),
      title: Text(title,
          style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: context.textPrimary)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style:
                  TextStyle(fontSize: 13, color: context.textTertiary)),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right_rounded,
              size: 18, color: context.textTertiary),
        ],
      ),
    );
  }

  /// 恢复已忽略的冲突课程（v1.6.0）：单个恢复或全部恢复 ——
  /// 移出忽略名单后，下次同步这些课会重新出现。
  Future<void> _showRestoreDialog() async {
    var keys = List<String>.from(_dropped);
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setModal) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusLg)),
          title: const Text('已忽略的冲突课程',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: 320,
            child: keys.isEmpty
                ? const Text('没有已忽略的课程',
                    style: TextStyle(fontSize: 13.5))
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final k in keys)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(_droppedLabel(k),
                                style: const TextStyle(fontSize: 13)),
                            trailing: TextButton(
                              onPressed: () async {
                                final next = List<String>.from(keys)
                                  ..remove(k);
                                await StorageService.saveDroppedCourseKeys(
                                    next);
                                setModal(() => keys = next);
                                if (mounted) setState(() => _dropped = next);
                              },
                              child: const Text('恢复'),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          actions: [
            if (keys.isNotEmpty)
              TextButton(
                onPressed: () async {
                  await StorageService.saveDroppedCourseKeys(const <String>[]);
                  setModal(() => keys = <String>[]);
                  if (mounted) setState(() => _dropped = const <String>[]);
                },
                child: const Text('全部恢复',
                    style: TextStyle(color: Colors.grey)),
              ),
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('完成')),
          ],
        );
      }),
    );
  }

  /// 把忽略名单的签名还原成可读文案：课名（教师）· 周X 第a-b节。
  String _droppedLabel(String key) {
    final p = key.split('|');
    if (p.length < 6) return key;
    final wd = switch (int.tryParse(p[2]) ?? 1) {
      0 => '每天',
      -1 => '工作日',
      final w => '周$w',
    };
    final teacher = p[1].isEmpty ? '' : '（${p[1]}）';
    return '${p[0]}$teacher · $wd 第${p[3]}-${p[4]}节';
  }

  /// 色彩方案行（v1.6.9）：一排三个色卡，点了立即生效（缓存 + 存储 + 实时预览）。
  ///
  /// 色卡里的小圆点用**同一批示例色**在该方案下的实际颜色 ——
  /// 三套方案并排一眼能比出区别（用户要求：不要只给文字档位名字）。
  Widget _schemeTile() {
    final cur = CourseColorScheme.parse(_display['scheme']);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.palette_outlined,
                  size: 20, color: AppTheme.primaryColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text('色彩方案',
                    style:
                        TextStyle(fontSize: 14.5, color: context.textPrimary)),
              ),
              Text(cur.label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primaryColor,
                  )),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final s in CourseColorScheme.values) ...[
                Expanded(child: _schemeChip(s, cur)),
                if (s != CourseColorScheme.values.last) const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _schemeChip(CourseColorScheme s, CourseColorScheme cur) {
    final selected = s == cur;
    // 示例色取自调色板里对比明显的四色（蓝 / 粉 / 绿 / 黄）
    const demo = [0xFFD2E5F8, 0xFFF8D2D7, 0xFFD2F0E5, 0xFFF8F3D2];
    return GestureDetector(
      onTap: () => _set('scheme', s.name),
      child: Container(
        height: 54,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          border: Border.all(
            color: selected ? AppTheme.primaryColor : context.borderColor,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final c in demo)
                  Container(
                    width: 13,
                    height: 13,
                    margin: const EdgeInsets.symmetric(horizontal: 1.5),
                    decoration: BoxDecoration(
                      color: courseColorFor(c, s),
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              s.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? AppTheme.primaryColor
                    : context.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _switchTile({
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) =>
      SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
            children: [
              Icon(icon,
                  size: 20,
                  color: enabled
                      ? AppTheme.primaryColor
                      : context.textTertiary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontSize: 14.5,
                        color: enabled
                            ? context.textPrimary
                            : context.textTertiary)),
              ),
              Transform.scale(
                scale: 0.8,
                child: Switch(
                  value: value,
                  onChanged: enabled ? onChanged : null,
                  activeColor: Colors.white,
                  activeTrackColor: AppTheme.primaryColor,
                ),
              ),
            ],
          ),
        ),
      );

  /// 滑杆行（v1.3.0）：标题 + 当前值一行，滑杆一行。
  ///
  /// [onChanged] 拖动中回调（实时预览），[onChangeEnd] 松手回调（存盘）。
  /// [enabled] 为 false 时置灰不可拖（例如「显示网格线」关着时的粗细 / 深浅）。
  Widget _sliderTile({
    required IconData icon,
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
    required Future<void> Function() onChangeEnd,
    bool enabled = true,
  }) {
    final v = value.clamp(min, max).toDouble();
    // v1.4.0 紧凑化（用户要求）：行内边距收紧 + 滑杆区压到 32 高（原 48），
    // 单条约 80px → 58px，一屏能多看到两三条。
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
      child: Column(
        children: [
          Row(
            children: [
              Icon(icon,
                  size: 20,
                  color: enabled
                      ? AppTheme.primaryColor
                      : context.textTertiary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontSize: 14.5,
                        color: enabled
                            ? context.textPrimary
                            : context.textTertiary)),
              ),
              Text(
                format(v),
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: enabled
                      ? AppTheme.primaryColor
                      : context.textTertiary,
                ),
              ),
            ],
          ),
          SizedBox(
            height: 32,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                activeTrackColor: AppTheme.primaryColor,
                inactiveTrackColor: context.borderColor,
                disabledActiveTrackColor:
                    AppTheme.primaryColor.withOpacity(0.3),
                disabledInactiveTrackColor:
                    context.borderColor.withOpacity(0.7),
                thumbColor: AppTheme.primaryColor,
                disabledThumbColor: AppTheme.primaryColor.withOpacity(0.3),
                overlayColor: AppTheme.primaryColor.withOpacity(0.12),
                thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7, disabledThumbRadius: 7, elevation: 0),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
              ),
              child: Slider(
                value: v,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: enabled ? onChanged : null,
                onChangeEnd: enabled ? (_) => onChangeEnd() : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 背景图行：单行（缩略图 + 清除 / 选择按钮）。
  Widget _imageTile() => SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
            children: [
              Icon(Icons.wallpaper_rounded,
                  size: 20, color: AppTheme.primaryColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text('课表背景图',
                    style:
                        TextStyle(fontSize: 14.5, color: context.textPrimary)),
              ),
              if (_hasBg)
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  child: Image.file(
                    File(_bgPath),
                    width: 32,
                    height: 32,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              if (_hasBg)
                IconButton(
                  tooltip: '清除背景图',
                  icon: const Icon(Icons.close_rounded,
                      size: 18, color: Color(0xFF9CA3AF)),
                  onPressed: _clearBackground,
                ),
              IconButton(
                tooltip: '选择图片',
                icon: const Icon(Icons.add_photo_alternate_outlined,
                    size: 20, color: Color(0xFF9CA3AF)),
                onPressed: _pickBackground,
              ),
            ],
          ),
        ),
      );

  /// 操作行：单行（左图标 + 标题 + 右箭头）。
  Widget _actionTile({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    bool danger = false,
  }) =>
      SizedBox(
        height: 48,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(icon,
                    size: 20,
                    color: danger ? AppTheme.danger : AppTheme.primaryColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(title,
                      style: TextStyle(
                        fontSize: 14.5,
                        color: danger ? AppTheme.danger : context.textPrimary,
                      )),
                ),
                Icon(Icons.chevron_right, color: context.textTertiary),
              ],
            ),
          ),
        ),
      );
}
