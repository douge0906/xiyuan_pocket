import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/course_model.dart';
import '../models/course_table.dart';
import '../services/course_storage.dart';
import '../services/widget_prefs.dart';
import '../services/widget_sync_service.dart';
import '../theme/app_theme.dart';
import '../widgets/widget_appearance_editor.dart';

/// 桌面小组件 · 今日课表（v1.0.4，2026-11-06 改版）。
///
/// 入口：用户页 → 桌面小组件 → 今日课表。
/// 版式与考试 / 校园卡 / 倒数日三个组件的详情页统一：
/// **顶部当前数据卡 → 立即刷新按钮 → 组件外观 → 该组件独有的设置**。
/// 改动任何一项都立即重新同步，桌面上的小组件随即重绘。
///
/// 与原生侧的约定：这里的设置经 [WidgetPrefs.toJson] 并进同步 JSON，
/// 由 TodayWidgetRenderer.kt 读取应用（字段名改动要两边一起改）。
class WidgetSettingsPage extends StatefulWidget {
  const WidgetSettingsPage({super.key});

  @override
  State<WidgetSettingsPage> createState() => _WidgetSettingsPageState();
}

class _WidgetSettingsPageState extends State<WidgetSettingsPage>
    with WidgetsBindingObserver {
  List<CourseTable> _tables = const [];
  String _tableId = WidgetPrefs.defTableId;
  String _smallMode = 'time';
  String _selectedSize = 'small';

  /// 顶部数据卡：今天这个组件会渲染成什么。
  String _headline = '';
  String _detail = '';

  /// 精确闹钟权限被拒（Android 12+ 且未授予）→ 显示「去开启」入口。
  bool _exactDenied = false;
  static const _alarmCh = MethodChannel('wxxy/widget_alarm');

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置返回：重新查权限状态（用户可能刚开了）
    if (state == AppLifecycleState.resumed) _checkExactAlarm();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 权限入口行：只在 Android 12+ 且未授予时显示。
  Widget _exactAlarmRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
      child: Row(
        children: [
          Icon(Icons.schedule_rounded, size: 17, color: AppTheme.primaryColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text('倒计时每分钟刷新需要「闹钟」权限',
                style: TextStyle(
                    fontSize: AppTheme.fontSmall, color: context.textSecondary)),
          ),
          TextButton(
            onPressed: _requestExactAlarm,
            child:
                const Text('去开启', style: TextStyle(fontSize: AppTheme.fontSmall)),
          ),
        ],
      ),
    );
  }

  Future<void> _checkExactAlarm() async {
    if (!Platform.isAndroid) return;
    try {
      final ok = await _alarmCh.invokeMethod<bool>('canScheduleExact');
      if (!mounted) return;
      setState(() => _exactDenied = !(ok ?? true));
    } catch (_) {
      // 通道不存在 / 非 Android 12+：不显示入口
    }
  }

  Future<void> _requestExactAlarm() async {
    try {
      await _alarmCh.invokeMethod<bool>('requestExact');
    } catch (_) {}
  }

  // v1.6.7：中号 / 大号**各自独立**的显示开关（此前共用同一组：中号关掉老师，
  // 大号跟着变 —— 用户反馈的 bug）。小号继续用上面那组全局值。
  bool _showTeacherMedium = true;
  bool _showClassroomMedium = true;
  bool _showTimeMedium = true;
  bool _showTeacherLarge = true;
  bool _showClassroomLarge = true;
  bool _showTimeLarge = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _checkExactAlarm();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    final tables = await CourseStorage.loadTables();
    final active = await CourseStorage.activeTable();
    final tableId = await WidgetPrefs.tableId();
    if (!mounted) return;
    setState(() {
      _tables = tables;
      // 存的表已被删 → 回落到跟随当前课表
      _tableId = tables.any((t) => t.id == tableId) ? tableId : '';
      _activeName = active.name;
    });
    final sm = await WidgetPrefs.smallMode();
    // v1.6.7：中号 / 大号各自一套显示开关
    final tmT = await WidgetPrefs.showTeacherMedium();
    final cm = await WidgetPrefs.showClassroomMedium();
    final tim = await WidgetPrefs.showTimeMedium();
    final tl = await WidgetPrefs.showTeacherLarge();
    final cl = await WidgetPrefs.showClassroomLarge();
    final til = await WidgetPrefs.showTimeLarge();
    final today = await _todaySummary(_tableId);
    if (!mounted) return;
    setState(() {
      _smallMode = sm;
      _showTeacherMedium = tmT;
      _showClassroomMedium = cm;
      _showTimeMedium = tim;
      _showTeacherLarge = tl;
      _showClassroomLarge = cl;
      _showTimeLarge = til;
      _headline = today.$1;
      _detail = today.$2;
      _loading = false;
    });
  }

  /// 「组件现在会显示什么」：与 [WidgetSyncService.syncTodayCourses] 取同一份数据。
  Future<(String, String)> _todaySummary(String tableId) async {
    final tables = await CourseStorage.loadTables();
    CourseTable? table;
    for (final t in tables) {
      if (t.id == tableId) {
        table = t;
        break;
      }
    }
    table ??= await CourseStorage.activeTable();
    final rawStart = table.semesterStart ??
        await CourseStorage.loadSemesterStart() ??
        CourseStorage.defaultSemesterStart(DateTime.now());
    final start = CourseStorage.mondayOf(
        DateTime(rawStart.year, rawStart.month, rawStart.day));
    final now = DateTime.now();
    final week = CourseStorage.teachingWeek(now, start);

    final list = <Course>[
      for (final c in table.courses)
        if (c.occursOn(now.weekday, week)) c,
    ]..sort((a, b) => a.startSlot.compareTo(b.startSlot));

    if (list.isEmpty) return ('今天没有课', '第 $week 教学周 · 组件显示「今天没课」');
    final first = list.first;
    final head = list.length == 1 ? first.name : '今天 ${list.length} 节课';
    final detail = '第 $week 教学周 · 第 ${first.startSlot} 节起'
        '${first.classroom.isEmpty ? '' : ' · ${first.classroom}'}';
    return (head, detail);
  }

  String _activeName = '';

  /// 改一项设置：**先改本地字段并刷界面**，再落盘、再同步桌面。
  ///
  /// 🔴 这里必须同时改本地字段（[mutate]）—— 早先只写了存储、没动本地字段，
  ///    结果开关/分段按钮点完界面纹丝不动，要**退出重进**才显示新状态
  ///    （用户测出来的 bug）。本地字段与存储必须一起改，界面才不会滞后。
  Future<void> _apply(void Function() mutate, Future<void> Function() write) async {
    if (mounted) setState(mutate);
    await write();
    await WidgetSyncService.syncTodayCourses();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('今日课表组件',
            style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
              children: [
                // ============ 顶部数据卡（与另外三种组件一致） ============
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: context.surfaceColor,
                    borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                    border: Border.all(color: context.borderColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.schedule_rounded,
                              size: 20, color: AppTheme.primaryColor),
                          const SizedBox(width: 8),
                          Text('今日课表组件',
                              style: TextStyle(
                                  fontSize: AppTheme.fontSmall,
                                  fontWeight: FontWeight.w600,
                                  color: context.textSecondary)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(_headline,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: context.textPrimary)),
                      const SizedBox(height: 4),
                      Text(_detail,
                          style: TextStyle(
                              fontSize: AppTheme.fontSmall,
                              color: context.textTertiary)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _refreshNow,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
                    side: BorderSide(color: context.borderColor),
                  ),
                  child: Text('立即刷新小组件数据',
                      style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          color: context.textPrimary)),
                ),
                const SizedBox(height: 12),
                // 外观设置：与其他三种组件同一块编辑器（per-kind 生效）。
                WidgetAppearanceEditor(
                  kind: 'schedule',
                  title: '组件外观',
                  onSync: WidgetSyncService.syncTodayCourses,
                ),
                const SizedBox(height: 20),
                // ============ 该组件独有的设置 ============
                _card(
                  isDark,
                  children: [
                    _rowTitle(context, '显示哪份课表'),
                    const SizedBox(height: 10),
                    _tablePicker(context),
                  ],
                ),
                const SizedBox(height: 12),
                _card(
                  isDark,
                  children: [
                    _rowTitle(context, '型号选项'),
                    const SizedBox(height: 10),
                    _segmented(
                      context,
                      options: const [
                        ('small', '小号 1×2'),
                        ('medium', '中号 2×2'),
                        ('large', '大号 4×2'),
                      ],
                      value: _selectedSize,
                      onChanged: (v) => setState(() => _selectedSize = v),
                    ),
                    const SizedBox(height: 14),
                    if (_selectedSize == 'small') ...[
                      _rowTitle(context, '小号第二行'),
                      const SizedBox(height: 8),
                      _segmented(
                        context,
                        options: const [
                          ('time', '上课时间'),
                          ('countdown', '还有多久'),
                        ],
                        value: _smallMode,
                        onChanged: (v) => _apply(
                          () => _smallMode = v,
                          () => WidgetPrefs.setSmallMode(v),
                        ),
                      ),
                      if (_exactDenied && _smallMode == 'countdown')
                        _exactAlarmRow(context),
                    ] else if (_selectedSize == 'medium') ...[
                      _switchRow(context, '任课老师', _showTeacherMedium,
                          (v) => _apply(() => _showTeacherMedium = v,
                              () => WidgetPrefs.setShowTeacherMedium(v))),
                      _switchRow(context, '上课时间', _showTimeMedium,
                          (v) => _apply(() => _showTimeMedium = v,
                              () => WidgetPrefs.setShowTimeMedium(v))),
                      _switchRow(context, '教室', _showClassroomMedium,
                          (v) => _apply(() => _showClassroomMedium = v,
                              () => WidgetPrefs.setShowClassroomMedium(v))),
                    ] else ...[
                      _switchRow(context, '任课老师', _showTeacherLarge,
                          (v) => _apply(() => _showTeacherLarge = v,
                              () => WidgetPrefs.setShowTeacherLarge(v))),
                      _switchRow(context, '上课时间', _showTimeLarge,
                          (v) => _apply(() => _showTimeLarge = v,
                              () => WidgetPrefs.setShowTimeLarge(v))),
                      _switchRow(context, '教室', _showClassroomLarge,
                          (v) => _apply(() => _showClassroomLarge = v,
                              () => WidgetPrefs.setShowClassroomLarge(v))),
                    ],
                  ],
                ),
              ],
            ),
    );
  }

  // ---------------- 组件 ----------------

  /// 手动把最新课表推给小组件（平时靠系统定期自动刷新）。
  Future<void> _refreshNow() async {
    await WidgetSyncService.syncTodayCourses();
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('小组件数据已刷新')),
    );
  }

  Widget _card(bool isDark, {required List<Widget> children}) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: context.cardColor,
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          border: Border.all(color: context.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      );

  Widget _rowTitle(BuildContext context, String text) => Text(text,
      style: TextStyle(
          fontSize: AppTheme.fontBody,
          fontWeight: FontWeight.w600,
          color: context.textPrimary));

  Widget _tablePicker(BuildContext context) {
    return DropdownButtonFormField<String>(
      value: _tableId,
      isExpanded: true,
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          borderSide: BorderSide(color: context.borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          borderSide: BorderSide(color: context.borderColor),
        ),
      ),
      style: TextStyle(fontSize: AppTheme.fontBody, color: context.textPrimary),
      items: [
        DropdownMenuItem(
            value: '',
            child: Text(
                '跟随当前课表${_activeName.isEmpty ? '' : '（$_activeName）'}')),
        for (final t in _tables)
          DropdownMenuItem(value: t.id, child: Text(t.name)),
      ],
      onChanged: (v) => _apply(() => _tableId = v ?? '',
          () => WidgetPrefs.setTableId(v ?? '')),
      dropdownColor: context.cardColor,
    );
  }

  Widget _segmented(
    BuildContext context, {
    required List<(String, String)> options,
    required String value,
    required ValueChanged<String> onChanged,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final active = isDark ? Colors.white : AppTheme.primaryColor;
    return Row(
      children: [
        for (final o in options) ...[
          Expanded(
            child: InkWell(
              onTap: () => onChanged(o.$1),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              child: Container(
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: value == o.$1
                      ? (isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF3F4F6))
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  border: Border.all(
                    color: value == o.$1 ? active : context.borderColor,
                    width: 1,
                  ),
                ),
                child: Text(
                  o.$2,
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight:
                        value == o.$1 ? FontWeight.w600 : FontWeight.w400,
                    color: context.textPrimary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ],
    );
  }

  Widget _switchRow(BuildContext context, String title, bool value,
          ValueChanged<bool> onChanged) =>
      SizedBox(
        height: 48,
        child: Row(
          children: [
            Expanded(
              child: Text(title,
                  style: TextStyle(
                      fontSize: AppTheme.fontBody, color: context.textPrimary)),
            ),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      );
}
