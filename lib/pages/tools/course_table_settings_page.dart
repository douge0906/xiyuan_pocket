import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/course_model.dart';
import '../../services/course_storage.dart';
import '../../services/course_transfer_service.dart';
import '../../services/storage_service.dart';
import '../../services/widget_sync_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/course_bg_color_picker.dart';
import 'course_bg_crop_page.dart';
import '../../widgets/course_style_preview.dart';
import '../user/user_cards.dart';

part 'course_table_settings_rows.dart';

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
    this.onTablesChanged,
  });

  /// 添加课程（课表页弹添加表单）。
  final VoidCallback onAddCourse;

  /// 调整上课时间（课表页的时间编辑弹窗）。
  final VoidCallback onEditTime;

  /// 同步今日课程到待办。
  final VoidCallback onSyncTodos;

  /// 清空全部课程（课表页内部会二次确认）。
  final VoidCallback onClearAll;

  /// 导入课表方案后通知课表页重新加载。
  final VoidCallback? onTablesChanged;

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

  /// 课程预览默认收起，点标题或下滑展开。
  bool _previewExpanded = true;
  Map<String, Map<String, dynamic>> _presets = {};

  /// 设置栏目：外观 / 课程 / 方案。
  int _tab = 0;

  bool get _showGridLines => _display['showGridLines'] != false;
  bool get _showOtherWeeks => _display['showOtherWeeks'] == true;
  String get _bgPath => (_display['backgroundImage'] ?? '').toString();

  /// 背景色面板是否展开（默认展开，否则用户找不到色彩盘）。
  bool _colorOpen = true;

  int? get _bgColor => (_display['backgroundColor'] as num?)?.toInt();
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
    CourseStorage.loadAppearancePresets().then((v) {
      if (mounted) setState(() => _presets = v);
    });
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
  Future<void> _set(String key, Object? value) async {
    final next = <String, dynamic>{..._display, key: value};
    // 先同步缓存再 setState：顶部实时预览与返回课表后的网格都读缓存
    CourseStorage.applyDisplayToCache(next);
    // 🔴 调用方在 await 之后（系统文件选择器）可能已销毁页面。
    if (!mounted) return;
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

  /// 换色彩方案（2026-10-16）：**每种方案各自保存自己那套手动调整** ——
  /// 切过去用「该方案名下存过的那套」，没存过才用出厂预设；
  /// 切走时先把当前这套归档到原方案名下。逻辑在 [CourseStorage.switchScheme]。
  Future<void> _applyScheme(CourseColorScheme s) async {
    var next = CourseStorage.switchScheme(_display, s);
    // 「方案二」= 紧凑淡蓝套装：窄时间栏 + 窄日期栏 + 淡蓝底 + 无网格线
    // （2026-10-26 用户指定；其余方案仍只换配色，不碰布局）
    if (s == CourseColorScheme.soft) {
      next = {
        ...next,
        'timeColWidth': 40.0,
        'dateRowHeight': 42.0,
        'backgroundColor': 0xFFE8F1FB,
        'backgroundImage': '',
        'showGridLines': false,
      };
    }
    CourseStorage.applyDisplayToCache(next);
    setState(() {
      _display = next;
      _future = Future<Map<String, dynamic>>.value(next);
    });
    await CourseStorage.saveDisplaySettings(next);
    // 桌面小组件的课程色条也要跟着变色（重新下发一次）
    unawaited(WidgetSyncService.syncTodayCourses());
    if (!mounted) return;
    _toast('已套用${s.label}');
  }

  /// 批量应用外观补丁（自定义方案 / 导入）。
  Future<void> _applyAppearancePatch(Map<String, dynamic> patch) async {
    final next = <String, dynamic>{..._display, ...patch};
    // 外观方案不携带本机背景图路径，避免换机后指向不存在的文件。
    // 但方案里指定了背景色时，必须清掉背景图，否则图片盖住颜色。
    if (patch.containsKey('backgroundColor') &&
        patch['backgroundColor'] != null) {
      next['backgroundImage'] = '';
    } else {
      next.remove('backgroundImage');
    }
    CourseStorage.applyDisplayToCache(next);
    setState(() {
      _display = next;
      _future = Future<Map<String, dynamic>>.value(next);
    });
    await CourseStorage.saveDisplaySettings(next);
    unawaited(WidgetSyncService.syncTodayCourses());
  }

  Future<void> _saveAppearancePreset() async {
    final controller =
        TextEditingController(text: '我的方案 ${_presets.length + 1}');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存外观方案'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(
            labelText: '方案名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, controller.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    final next = <String, Map<String, dynamic>>{
      ..._presets,
      name: CourseStorage.appearanceOfDisplay(_display),
    };
    await CourseStorage.saveAppearancePresets(next);
    if (!mounted) return;
    setState(() => _presets = next);
    _toast('已保存外观方案「$name」');
  }

  Future<void> _deleteAppearancePreset(String name) async {
    final next = <String, Map<String, dynamic>>{..._presets}..remove(name);
    await CourseStorage.saveAppearancePresets(next);
    if (!mounted) return;
    setState(() => _presets = next);
    _toast('已删除「$name」');
  }

  Future<void> _exportAppearance() async {
    try {
      final data = <String, dynamic>{
        'version': 1,
        'appearance': CourseStorage.appearanceOfDisplay(_display),
        'presets': _presets,
      };
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出外观方案',
        fileName: 'xiyuan_appearance.json',
        bytes: Uint8List.fromList(utf8.encode(
            const JsonEncoder.withIndent('  ').convert(data))),
      );
      if (path != null) _toast('外观方案已导出');
    } catch (e) {
      debugPrint('[CourseTableSettings] 导出外观方案失败: $e');
      _toast('导出失败，请稍后重试');
    }
  }

  Future<void> _importAppearance() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) return;
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) throw const FormatException('不是有效的外观方案');
      final appearance = decoded['appearance'];
      if (appearance is Map) {
        await _applyAppearancePatch(Map<String, dynamic>.from(appearance));
      }
      final presets = decoded['presets'];
      if (presets is Map) {
        final merged = <String, Map<String, dynamic>>{..._presets};
        presets.forEach((key, value) {
          if (value is Map) {
            merged[key.toString()] = Map<String, dynamic>.from(value);
          }
        });
        await CourseStorage.saveAppearancePresets(merged);
        if (mounted) setState(() => _presets = merged);
      }
      if (mounted) _toast('外观方案已导入');
    } catch (e) {
      debugPrint('[CourseTableSettings] 导入外观方案失败: $e');
      _toast('导入失败，请确认文件来自掌上锡院');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: AppTheme.fontSmall)),
        duration: const Duration(seconds: 2),
      ));
  }

  Future<void> _exportCourseTables() async {
    try {
      final count = await CourseTransferService.exportTables();
      _toast('已准备 $count 份课表，选择保存位置');
    } catch (e) {
      debugPrint('[CourseTableSettings] 导出课表方案失败: $e');
      _toast('导出失败，请稍后重试');
    }
  }

  Future<void> _importCourseTables() async {
    try {
      final count = await CourseTransferService.importTables();
      if (count <= 0) return;
      _toast('已导入 $count 份课表');
      widget.onTablesChanged?.call();
    } catch (e) {
      debugPrint('[CourseTableSettings] 导入课表方案失败: $e');
      _toast('导入失败，请确认文件来自掌上锡院');
    }
  }

  /// 选一张图作为课表背景。
  ///
  /// image_picker 返回的是**临时缓存路径**，系统随时可能清掉，直接存会导致
  /// 背景图「过几天就丢」→ 这里把图片拷贝到应用文档目录持久化。
  Future<void> _pickBackground() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    // 先框选：拖动/缩放定位，确定后按框裁出来（2026-10-26 用户要求）
    if (!mounted) return;
    final croppedPath = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => CourseBgCropPage(sourcePath: picked.path),
      ),
    );
    if (croppedPath == null) return; // 用户取消
    if (!mounted) return;

    try {
      final docs = await getApplicationDocumentsDirectory();
      final target = File('${docs.path}/course_background.png');
      final temp = File('${docs.path}/course_background.new.png');
      if (await temp.exists()) await temp.delete();
      // 🔴 顺序：先写临时文件 → 校验 → **把旧图改名备份** → 临时文件顶上去
      //    → 成功后才删备份。之前是「先删所有旧图再 rename」，rename 一失败
      //    旧背景就没了，而 catch 里还提示「旧背景已保留」（与事实相反）。
      await File(croppedPath).copy(temp.path);
      if (!await temp.exists() || await temp.length() <= 0) {
        throw FileSystemException('背景图复制为空');
      }
      final backup = File('${docs.path}/course_background.old.png');
      if (await backup.exists()) await backup.delete();
      var moved = false;
      for (final e in ['jpg', 'jpeg', 'png', 'webp']) {
        final old = File('${docs.path}/course_background.$e');
        if (old.path == target.path) continue; // 稍后单独处理
        if (await old.exists()) await old.delete();
      }
      if (await target.exists()) {
        await target.rename(backup.path);
        moved = true;
      }
      try {
        await temp.rename(target.path);
      } catch (_) {
        // 顶不上去就把旧图还回来，用户至少没丢原背景。
        if (moved && await backup.exists()) {
          try {
            await backup.rename(target.path);
          } catch (_) {}
        }
        rethrow;
      }
      if (await backup.exists()) {
        try {
          await backup.delete();
        } catch (_) {}
      }
      try {
        await File(croppedPath).delete();
      } catch (_) {}
      await _set('backgroundImage', target.path);
      // 与背景色互斥
      if (_bgColor != null) await _set('backgroundColor', null);
      _toast('背景图已设置，上方预览可见');
    } catch (_) {
      try {
        final docs = await getApplicationDocumentsDirectory();
        final temp = File('${docs.path}/course_background.new.png');
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
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
            style: TextStyle(fontSize: AppTheme.fontHeading, fontWeight: FontWeight.w600)),
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
              _buildPreviewCollapse(),
              // ---- 设置板块（可滚动 + 可折叠）----
              Expanded(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: _buildSettingsNav(),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                        children: [
                          if (_tab == 0)
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
                          min: 0.5,
                          max: 0.85,
                          divisions: 7,
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
                    // v1.6.4：「课表布局」（仿掌上徐工的「课表网格」组）——
                    // 课节高度 / 时间列宽度 / 日期栏高度。
                    if (_tab == 0)
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
                          max: 120,
                          divisions: 24,
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
                    if (_tab == 2)
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
                          min: 0.35,
                          max: 1,
                          divisions: 13,
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
                      ],
                    ),
                    if (_tab == 2)
                      _collapsible(
                        key: 'card',
                        icon: Icons.view_agenda_outlined,
                        title: '课程卡内容',
                        children: [
                          _switchTile(
                            icon: Icons.title_rounded,
                            title: '显示课程名',
                            value: _display['showNameOnCard'] != false,
                            onChanged: (v) => _set('showNameOnCard', v),
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
                          _sliderTile(
                            icon: Icons.format_size_rounded,
                            title: '课程卡字号',
                            value: CourseStorage.cardFontScaleCache,
                            min: 0.85,
                            max: 1.3,
                            divisions: 9,
                            format: (v) => '${(v * 100).round()}%',
                            onChanged: (v) => _liveSlider('cardFontScale', v),
                            onChangeEnd: _commitSliders,
                          ),
                          _choiceRow<int>(
                            icon: Icons.notes_rounded,
                            title: '课程名最大行数',
                            value: CourseStorage.cardMaxLinesCache,
                            options: const [
                              (1, '1 行'),
                              (2, '2 行'),
                              (3, '3 行'),
                            ],
                            onChanged: (v) => _set('cardMaxLines', v),
                          ),
                          _choiceRow<String>(
                            icon: Icons.short_text_rounded,
                            title: '超出宽度时',
                            value: CourseStorage.cardOverflowCache,
                            options: const [
                              ('ellipsis', '省略号'),
                              ('clip', '直接裁剪'),
                              ('fade', '渐隐'),
                            ],
                            onChanged: (v) => _set('cardOverflow', v),
                          ),
                          _cardOrderTile(),
                        ],
                      ),
                    if (_tab == 2) _appearancePresetCard(),
                    if (_tab == 1)
                      _collapsible(
                        key: 'display',
                      icon: Icons.wallpaper_rounded,
                      title: '界面显示',
                      children: [
                        _colorTile(),
                        _imageTile(),
                        _switchTile(
                          icon: Icons.today_rounded,
                          title: '隐藏日期',
                          value: _hideDateRow,
                          onChanged: (v) => _set('hideDateRow', v),
                        ),
                        _switchTile(
                          icon: Icons.highlight_rounded,
                          title: '高亮今天列',
                          value: _display['highlightToday'] != false,
                          onChanged: (v) => _set('highlightToday', v),
                        ),
                      ],
                    ),
                    if (_tab == 3)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: userCard(
                          context,
                          padding: EdgeInsets.zero,
                          child: _switchTile(
                            icon: Icons.sync_rounded,
                            title: '进入 App 自动更新课表',
                            value: _autoUpdateOnLaunch,
                            onChanged: (v) => _set('autoUpdateOnLaunch', v),
                          ),
                        ),
                      ),
                    if (_tab == 3)
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
                    if (_tab == 3)
                      _collapsible(
                        key: 'transfer',
                      icon: Icons.swap_vert_rounded,
                      title: '课表方案',
                      children: [
                        _actionTile(
                          icon: Icons.upload_file_rounded,
                          title: '导出课表方案',
                          onTap: _exportCourseTables,
                        ),
                        _actionTile(
                          icon: Icons.download_rounded,
                          title: '导入课表方案',
                          onTap: _importCourseTables,
                        ),
                      ],
                    ),
                    if (_tab == 3)
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
            style: TextStyle(fontSize: AppTheme.fontTitle, fontWeight: FontWeight.bold)),
        content: const Text(
            '将把课表的外观与显示设置恢复为默认值'
            '（网格线、颜色、圆角、背景图等）。\n课程内容不受影响。',
            style: TextStyle(fontSize: AppTheme.fontBody, height: 1.5)),
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
  Widget _buildPreviewCollapse() {
    final chevron = _previewExpanded
        ? Icons.keyboard_arrow_up_rounded
        : Icons.keyboard_arrow_down_rounded;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _previewExpanded = !_previewExpanded),
            onVerticalDragEnd: (details) {
              final v = details.primaryVelocity ?? 0;
              if (v > 120 && !_previewExpanded) {
                setState(() => _previewExpanded = true);
              } else if (v < -120 && _previewExpanded) {
                setState(() => _previewExpanded = false);
              }
            },
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: context.surfaceColor,
                borderRadius: AppTheme.radiusMdAll,
                border: Border.all(color: context.borderColor),
              ),
              child: Row(
                children: [
                  Icon(Icons.visibility_outlined,
                      size: 17, color: AppTheme.primaryColor),
                  const SizedBox(width: 8),
                  Text('课程预览',
                      style: TextStyle(
                          fontSize: AppTheme.fontSmall, color: context.textPrimary)),
                  const Spacer(),
                  Icon(chevron, size: 18, color: context.textTertiary),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _previewExpanded
                ? Padding(
                    padding: const EdgeInsets.only(top: 6),
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
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsNav() {
    const tabs = ['布局与网格', '背景与日期', '课程卡', '数据与同步'];
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.borderColor)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            Expanded(
              child: InkWell(
                onTap: () {
                  setState(() {
                    _tab = i;
                    if (i == 0) _expanded.addAll({'grid', 'layout'});
                    if (i == 1) _expanded.add('display');
                    if (i == 2) {
                      _expanded.addAll({'blocks', 'card', 'presets'});
                    }
                    if (i == 3) {
                      _expanded.addAll({'courses', 'transfer'});
                    }
                  });
                },
                child: Container(
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: _tab == i
                            ? AppTheme.primaryColor
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Text(
                    tabs[i],
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: AppTheme.fontSmall,
                      fontWeight:
                          _tab == i ? FontWeight.w700 : FontWeight.w400,
                      color: _tab == i
                          ? AppTheme.primaryColor
                          : context.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

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
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: userCard(
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
            // 头部底色比组内选项稍暗：把「分组标题」与「选项」区分开
            child: Container(
              height: 52,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white.withValues(alpha: 0.035)
                  : Colors.black.withValues(alpha: 0.025),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(icon, size: 20, color: AppTheme.primaryColor),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(title,
                          style: TextStyle(
                            fontSize: AppTheme.fontBody,
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
              style: TextStyle(fontSize: AppTheme.fontTitle, fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: 320,
            child: keys.isEmpty
                ? const Text('没有已忽略的课程',
                    style: TextStyle(fontSize: AppTheme.fontBody))
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final k in keys)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(_droppedLabel(k),
                                style: const TextStyle(fontSize: AppTheme.fontSmall)),
                            trailing: TextButton(
                              onPressed: () async {
                                final next = List<String>.from(keys)
                                  ..remove(k);
                                await StorageService.saveDroppedCourseKeys(
                                    next);
                                // 恢复的课可能又是一处冲突 → 让冲突提醒重新对它生效
                                await StorageService.saveAcknowledgedConflicts(
                                    const <String>[]);
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
                  // 同上：恢复后让冲突提醒重新生效
                  await StorageService
                      .saveAcknowledgedConflicts(const <String>[]);
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



  Widget _schemeChip(CourseColorScheme s, CourseColorScheme cur) {
    final selected = s == cur;
    // 示例色取自调色板里对比明显的四色（蓝 / 粉 / 绿 / 黄）
    const demo = [0xFFD2E5F8, 0xFFF8D2D7, 0xFFD2F0E5, 0xFFF8F3D2];
    return GestureDetector(
      onTap: () => _applyScheme(s),
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
                fontSize: AppTheme.fontCaption,
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

  List<String> get _cardOrder {
    final raw = _display['cardFieldOrder'];
    if (raw is List) {
      final list = raw
          .map((e) => e.toString())
          .where((e) => ['name', 'teacher', 'classroom'].contains(e))
          .toList();
      if (list.length == 3) return list;
    }
    return const ['name', 'classroom', 'teacher'];
  }

  Widget _choiceRow<T>({
    required IconData icon,
    required String title,
    required T value,
    required List<(T, String)> options,
    required ValueChanged<T> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: AppTheme.primaryColor),
              const SizedBox(width: 12),
              Text(title,
                  style: TextStyle(
                      fontSize: AppTheme.fontBody, color: context.textPrimary)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final option in options)
                ChoiceChip(
                  label: Text(option.$2,
                      style: const TextStyle(fontSize: AppTheme.fontSmall)),
                  selected: option.$1 == value,
                  showCheckmark: false,
                  onSelected: (_) => onChanged(option.$1),
                ),
            ],
          ),
        ],
      ),
    );
  }


  Widget _appearancePresetCard() {
    return _collapsible(
      key: 'presets',
      icon: Icons.palette_outlined,
      title: '我的外观方案',
      children: [
        _actionTile(
          icon: Icons.bookmark_add_outlined,
          title: '保存当前外观',
          onTap: _saveAppearancePreset,
        ),
        _actionTile(
          icon: Icons.upload_file_rounded,
          title: '导出外观方案',
          onTap: _exportAppearance,
        ),
        _actionTile(
          icon: Icons.download_rounded,
          title: '导入外观方案',
          onTap: _importAppearance,
        ),
        if (_presets.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Text('还没有保存的方案',
                style: TextStyle(
                    fontSize: AppTheme.fontSmall, color: context.textTertiary)),
          )
        else
          for (final name in _presets.keys)
            ListTile(
              dense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16),
              leading: Icon(Icons.bookmark_outline_rounded,
                  size: 20, color: context.textTertiary),
              title: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: AppTheme.fontBody)),
              trailing: IconButton(
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                onPressed: () => _deleteAppearancePreset(name),
              ),
              onTap: () => _applyAppearancePatch(_presets[name]!),
            ),
      ],
    );
  }



  /// 背景图行：单行（缩略图 + 清除 / 选择按钮）。
  /// 课表背景色（与背景图**二选一**）。
  Widget _colorTile() {
    final argb = _bgColor;
    final imgOn = _bgPath.isNotEmpty;
    return Column(
      children: [
        InkWell(
          onTap: () => setState(() => _colorOpen = !_colorOpen),
          child: SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Row(
                children: [
                  Icon(Icons.palette_rounded,
                      size: 20, color: AppTheme.primaryColor),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('课表背景色',
                            style: TextStyle(
                                fontSize: AppTheme.fontBody, color: context.textPrimary)),
                        if (imgOn)
                          Text('已设背景图，选色会清掉图片',
                              style: TextStyle(
                                  fontSize: AppTheme.fontCaption, color: context.textTertiary)),
                      ],
                    ),
                  ),
                  if (argb != null)
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: Color(argb),
                        shape: BoxShape.circle,
                        border: Border.all(color: context.borderColor),
                      ),
                    ),
                  const SizedBox(width: 6),
                  Icon(_colorOpen ? Icons.expand_less : Icons.expand_more,
                      size: 20, color: context.textTertiary),
                ],
              ),
            ),
          ),
        ),
        if (_bgPath.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('背景图深浅',
                        style: TextStyle(
                            fontSize: AppTheme.fontSmall, color: context.textSecondary)),
                    const Spacer(),
                    Text(
                        '${((1 - CourseStorage.backgroundDimCache) * 100).round()}%',
                        style: TextStyle(
                            fontSize: AppTheme.fontSmall, color: context.textTertiary)),
                  ],
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 7),
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    value: (1 - CourseStorage.backgroundDimCache)
                        .clamp(0.05, 1.0),
                    min: 0.05,
                    max: 1.0,
                    divisions: 19,
                    activeColor: AppTheme.primaryColor,
                    inactiveColor: context.borderColor,
                    // 100% = 图最明显（蒙层最薄）；拖动只改内存，松手写盘。
                    onChanged: (v) =>
                        _liveSlider('backgroundDim', (1 - v).clamp(0.0, 0.95)),
                    onChangeEnd: (_) => _commitSliders(),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_colorOpen)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CourseBgColorPicker(
                  initial: argb,
                  // 与缓存同口径：缺字段也算开（默认渐变）
                  gradient: _display['bgGradient'] != false,
                  onGradientChanged: (v) => _set('bgGradient', v),
                  gradientStrength:
                      (_display['bgGradientStrength'] as num?)?.toDouble() ??
                          0.78,
                  onGradientStrengthChanged: (v) =>
                      _set('bgGradientStrength', v),
                  onChanged: (v) async {
                    await _set('backgroundColor', v);
                    // 与背景图互斥
                    if (_bgPath.isNotEmpty) {
                      await _set('backgroundImage', '');
                    }
                  },
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed:
                        argb == null ? null : () => _set('backgroundColor', null),
                    child: const Text('恢复默认', style: TextStyle(fontSize: AppTheme.fontSmall)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

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
                        TextStyle(fontSize: AppTheme.fontBody, color: context.textPrimary)),
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

}
