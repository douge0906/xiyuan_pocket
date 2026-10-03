import 'package:flutter/material.dart';

import '../../services/course_storage.dart';
import '../../theme/app_theme.dart';
import '../user/user_cards.dart';

/// 课表设置页（v1.1.0）：显示开关 + 课程管理。
///
/// 入口：课表页右上角**齿轮**（取代原来的「三个点」菜单）。
/// 原先三个点里的四项（添加课程 / 调整上课时间 / 同步今日课程到待办 / 清空全部课程）
/// 全部搬到这里，入口更直观、也不再和「添加课程」的主按钮重复。
///
/// 具体动作由课表页通过回调转发（本页不直接操作 CourseStorage 的课程数据，
/// 避免两处各写一套「清空/同步」逻辑）。
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
  static const double _rowHeight = 52;

  bool _showGridLines = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await CourseStorage.loadDisplaySettings();
    if (!mounted) return;
    setState(() => _showGridLines = s['showGridLines'] != false);
  }

  Future<void> _setGridLines(bool v) async {
    setState(() => _showGridLines = v);
    await CourseStorage.saveDisplaySettings({'showGridLines': v});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('课表设置',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _sectionTitle('显示'),
          userCard(
            context,
            padding: EdgeInsets.zero,
            child: SizedBox(
              height: _rowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(Icons.grid_on_rounded,
                        size: 20, color: AppTheme.primaryColor),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('显示网格线',
                          style: TextStyle(
                              fontSize: 14, color: context.textPrimary)),
                    ),
                    Transform.scale(
                      scale: 0.85,
                      child: Switch(
                        value: _showGridLines,
                        onChanged: _setGridLines,
                        activeColor: Colors.white,
                        activeTrackColor: AppTheme.primaryColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text('关闭后课表格子之间不再画线，纯靠课程块区分。',
                style: TextStyle(fontSize: 12, color: context.textTertiary)),
          ),
          const SizedBox(height: 20),
          _sectionTitle('课程管理'),
          userCard(
            context,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _actionRow(
                  icon: Icons.add_rounded,
                  title: '添加课程',
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onAddCourse();
                  },
                ),
                Divider(height: 1, color: context.borderColor),
                _actionRow(
                  icon: Icons.schedule_rounded,
                  title: '调整上课时间',
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onEditTime();
                  },
                ),
                Divider(height: 1, color: context.borderColor),
                _actionRow(
                  icon: Icons.playlist_add_check_rounded,
                  title: '同步今日课程到待办',
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onSyncTodos();
                  },
                ),
                Divider(height: 1, color: context.borderColor),
                _actionRow(
                  icon: Icons.delete_sweep_rounded,
                  title: '清空全部课程',
                  danger: true,
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onClearAll();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '上课提醒在课表页右上角的铃铛 · 教务导入在课表页右上角的下载按钮',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: context.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(text,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.textSecondary)),
      );

  Widget _actionRow({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    bool danger = false,
  }) =>
      InkWell(
        onTap: onTap,
        child: SizedBox(
          height: _rowHeight,
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
                        fontSize: 14,
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
