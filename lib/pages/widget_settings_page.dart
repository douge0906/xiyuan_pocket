import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import '../models/course_table.dart';
import '../services/course_storage.dart';
import '../services/widget_prefs.dart';
import '../services/widget_sync_service.dart';
import '../theme/app_theme.dart';

/// 桌面小组件 · 个性化设置（v1.0.4）。
///
/// 入口：用户页 → 桌面小组件 → 今日课表。
/// 改任何一项都**立即重新同步**，桌面上的小组件随即重绘，不用重进 App。
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
  String _theme = WidgetPrefs.defTheme;
  String _accent = WidgetPrefs.defAccent;
  double _fontScale = WidgetPrefs.defFontScale;
  String _smallMode = 'time';
  String _selectedSize = 'small';

  /// 精确闹钟权限被拒（Android 12+ 且未授予）→ 显示「去开启」入口。
  bool _exactDenied = false;
  static const _alarmCh =
      MethodChannel('wxxy/widget_alarm');

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
          Icon(Icons.schedule_rounded,
              size: 17, color: AppTheme.primaryColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text('倒计时每分钟刷新需要「闹钟」权限',
                style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textSecondary)),
          ),
          TextButton(
            onPressed: _requestExactAlarm,
            child: const Text('去开启', style: TextStyle(fontSize: AppTheme.fontSmall)),
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

  /// 「显示内容」的分组展开状态（v1.6.4）：默认只展开小号（1×2）。

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
      _loading = false;
      _activeName = active.name;
    });
    final theme = await WidgetPrefs.theme();
    final accent = await WidgetPrefs.accent();
    final scale = await WidgetPrefs.fontScale();
    final sm = await WidgetPrefs.smallMode();
    // v1.6.7：中号 / 大号各自一套显示开关
    final tmT = await WidgetPrefs.showTeacherMedium();
    final cm = await WidgetPrefs.showClassroomMedium();
    final tim = await WidgetPrefs.showTimeMedium();
    final tl = await WidgetPrefs.showTeacherLarge();
    final cl = await WidgetPrefs.showClassroomLarge();
    final til = await WidgetPrefs.showTimeLarge();
    if (!mounted) return;
    setState(() {
      _theme = theme;
      _accent = accent;
      _fontScale = scale;
      _smallMode = sm;
      _showTeacherMedium = tmT;
      _showClassroomMedium = cm;
      _showTimeMedium = tim;
      _showTeacherLarge = tl;
      _showClassroomLarge = cl;
      _showTimeLarge = til;
    });
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
        title: const Text('桌面小组件',
            style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              children: [
                _card(
                  isDark,
                  children: [
                    Row(
                      children: [
                        _rowTitle(context, '同步数据'),
                        const Spacer(),
                        OutlinedButton(
                          onPressed: _refreshNow,
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 9),
                            shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(AppTheme.radiusSm)),
                            side: BorderSide(color: context.borderColor),
                          ),
                          child: Text('立即刷新',
                              style: TextStyle(
                                  fontSize: AppTheme.fontSmall, color: context.textPrimary)),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
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
                    _rowTitle(context, '主题'),
                    const SizedBox(height: 10),
                    _segmented(
                      context,
                      options: const [
                        ('system', '跟随系统'),
                        ('light', '浅色'),
                        ('dark', '深色'),
                      ],
                      value: _theme,
                      onChanged: (v) => _apply(
                          () => _theme = v,
                          () => WidgetPrefs.setTheme(v)),
                    ),
                    const SizedBox(height: 18),
                    _rowTitle(context, '主题色'),
                    const SizedBox(height: 10),
                    _accentPicker(context),
                  ],
                ),
                const SizedBox(height: 12),
                _card(
                  isDark,
                  children: [
                    Row(
                      children: [
                        _rowTitle(context, '字号'),
                        const Spacer(),
                        Text('${(_fontScale * 100).round()}%',
                            style: TextStyle(
                                fontSize: AppTheme.fontSmall, color: context.textTertiary)),
                      ],
                    ),
                    Slider(
                      value: _fontScale.clamp(0.8, 1.2),
                      min: 0.8,
                      max: 1.2,
                      divisions: 8,
                      activeColor: AppTheme.primaryColor,
                      inactiveColor: context.borderColor,
                      onChanged: (v) => setState(() => _fontScale = v),
                      onChangeEnd: (v) => _apply(
                          () => _fontScale = v,
                          () => WidgetPrefs.setFontScale(v)),
                    ),
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
        DropdownMenuItem(value: '', child: Text('跟随当前课表${_activeName.isEmpty ? '' : '（$_activeName）'}')),
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

  Widget _accentPicker(BuildContext context) {
    return Row(
      children: [
        for (final hex in WidgetPrefs.accentChoices) ...[
          InkWell(
            onTap: () => _apply(() => _accent = hex,
                () => WidgetPrefs.setAccent(hex)),
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Color(int.parse('FF$hex', radix: 16)),
                shape: BoxShape.circle,
                border: Border.all(
                  color: _accent == hex
                      ? (Theme.of(context).brightness == Brightness.dark
                          ? Colors.white
                          : AppTheme.primaryColor)
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: _accent == hex
                  ? const Icon(Icons.check_rounded,
                      size: 16, color: Colors.white)
                  : null,
            ),
          ),
          const SizedBox(width: 10),
        ],
      ],
    );
  }

  Widget _switchRow(BuildContext context, String title, bool value,          ValueChanged<bool> onChanged) =>
      SizedBox(
        height: 48,
        child: Row(
          children: [
            Expanded(
              child: Text(title,
                  style: TextStyle(fontSize: AppTheme.fontBody, color: context.textPrimary)),
            ),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      );
}
