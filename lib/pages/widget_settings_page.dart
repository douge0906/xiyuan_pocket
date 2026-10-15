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

class _WidgetSettingsPageState extends State<WidgetSettingsPage> {
  List<CourseTable> _tables = const [];
  String _tableId = WidgetPrefs.defTableId;
  String _theme = WidgetPrefs.defTheme;
  String _accent = WidgetPrefs.defAccent;
  double _fontScale = WidgetPrefs.defFontScale;
  bool _showTeacher = true;
  bool _showClassroom = true;
  bool _showTime = true;
  bool _showWeek = true;
  bool _countdown = true;
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
  final Set<String> _expandedSizes = {'small'};

  @override
  void initState() {
    super.initState();
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
    final t = await WidgetPrefs.showTeacher();
    final c = await WidgetPrefs.showClassroom();
    final tm = await WidgetPrefs.showTime();
    final w = await WidgetPrefs.showWeek();
    final cd = await WidgetPrefs.countdown();
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
      _showTeacher = t;
      _showClassroom = c;
      _showTime = tm;
      _showWeek = w;
      _countdown = cd;
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
    final sub = isDark ? Colors.grey.shade400 : const Color(0xFF6B7280);
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
                // 顶部：怎么添加 + 手动刷新（原来是上滑弹窗里的内容，
                // 2026-10-12 改成独立页面后一并搬进来，不再用弹窗）
                _card(
                  isDark,
                  children: [
                    _rowTitle(context, '怎么添加'),
                    const SizedBox(height: 10),
                    _step(context, '1', '长按手机桌面空白处'),
                    _step(context, '2', '点「小组件」，找到「掌上锡院」'),
                    _step(context, '3', '选一个尺寸，拖到桌面上'),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: _refreshNow,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
                          side: BorderSide(color: context.borderColor),
                        ),
                        child: Text('立即刷新数据',
                            style: TextStyle(
                                fontSize: 14, color: context.textPrimary)),
                      ),
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
                                fontSize: 13, color: context.textTertiary)),
                      ],
                    ),
                    // v1.6.4：三档按钮 → 连续滑杆（80%~120%）
                    Slider(
                      value: _fontScale.clamp(0.8, 1.2),
                      min: 0.8,
                      max: 1.2,
                      divisions: 8,
                      activeColor: AppTheme.primaryColor,
                      inactiveColor: context.borderColor,
                      // 拖动中只改内存（实时预览），松手才落盘
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
                    _rowTitle(context, '显示内容'),
                    const SizedBox(height: 6),
                    // v1.6.4：按三种小组件尺寸分组（折叠式），组内列该尺寸实际
                    // 会显示的项；小号默认展开。原独立的「还有多久」开关并入小号组。
                    _sizeGroup(
                      id: 'small',
                      label: '小号（1×2）',
                      children: [
                        _switchRow(context, '任课老师', _showTeacher,
                            (v) => _apply(() => _showTeacher = v,
                                () => WidgetPrefs.setShowTeacher(v))),
                        // v1.6.8：「上课时间」与「还有多久（倒计时）」**互斥** ——
                        // 小号第二行只放得下一个，点开一个就自动关掉另一个。
                        _switchRow(context, '上课时间', _showTime,
                            (v) => _apply(() {
                                  _showTime = v;
                                  if (v) _countdown = false;
                                }, () async {
                                  await WidgetPrefs.setShowTime(v);
                                  if (v) await WidgetPrefs.setCountdown(false);
                                })),
                        _switchRow(context, '教室', _showClassroom,
                            (v) => _apply(() => _showClassroom = v,
                                () => WidgetPrefs.setShowClassroom(v))),
                        _switchRow(context, '还有多久（倒计时）', _countdown,
                            (v) => _apply(() {
                                  _countdown = v;
                                  if (v) _showTime = false;
                                }, () async {
                                  await WidgetPrefs.setCountdown(v);
                                  if (v) await WidgetPrefs.setShowTime(false);
                                })),
                        // 周次只在小号第二行（兜底）用得上 —— 中号/大号已按需求去掉
                        _switchRow(context, '教学周次', _showWeek,
                            (v) => _apply(() => _showWeek = v,
                                () => WidgetPrefs.setShowWeek(v))),
                      ],
                    ),
                    _sizeGroup(
                      id: 'medium',
                      label: '中号（2×2）',
                      children: [
                        _switchRow(context, '任课老师', _showTeacherMedium,
                            (v) => _apply(() => _showTeacherMedium = v,
                                () => WidgetPrefs.setShowTeacherMedium(v))),
                        _switchRow(context, '上课时间', _showTimeMedium,
                            (v) => _apply(() => _showTimeMedium = v,
                                () => WidgetPrefs.setShowTimeMedium(v))),
                        _switchRow(context, '教室', _showClassroomMedium,
                            (v) => _apply(() => _showClassroomMedium = v,
                                () => WidgetPrefs.setShowClassroomMedium(v))),
                      ],
                    ),
                    _sizeGroup(
                      id: 'large',
                      label: '大号（4×4）',
                      children: [
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
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  '提示：改完立刻生效，桌面上的小组件会自动刷新，不用重进 App。',
                  style: TextStyle(fontSize: 12, color: sub, height: 1.6),
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

  /// 序号圆点（添加步骤）。
  Widget _step(BuildContext context, String n, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              ),
              child: Text(n,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primaryColor)),
            ),
            const SizedBox(width: 10),
            Expanded(
                child: Text(text,
                    style: TextStyle(
                        fontSize: 13.5, color: context.textPrimary))),
          ],
        ),
      );

  Widget _card(bool isDark, {required List<Widget> children}) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
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
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: context.textPrimary));

  Widget _tablePicker(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
      style: TextStyle(fontSize: 14, color: context.textPrimary),
      items: [
        DropdownMenuItem(value: '', child: Text('跟随当前课表${_activeName.isEmpty ? '' : '（$_activeName）'}')),
        for (final t in _tables)
          DropdownMenuItem(value: t.id, child: Text(t.name)),
      ],
      onChanged: (v) => _apply(() => _tableId = v ?? '',
          () => WidgetPrefs.setTableId(v ?? '')),
      dropdownColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
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
                    fontSize: 13.5,
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

  /// 「显示内容」的尺寸分组（v1.6.4，折叠式）：点标题行展开/收起，
  /// 小号组默认展开（[_expandedSizes] 初值就是 {'small'}）。
  Widget _sizeGroup({
    required String id,
    required String label,
    required List<Widget> children,
  }) {
    final open = _expandedSizes.contains(id);
    return Column(
      children: [
        InkWell(
          onTap: () => setState(() {
            if (open) {
              _expandedSizes.remove(id);
            } else {
              _expandedSizes.add(id);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(label,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary)),
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
        if (open) ...children,
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
                  style: TextStyle(fontSize: 14, color: context.textPrimary)),
            ),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      );
}
