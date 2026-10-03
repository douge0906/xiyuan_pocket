import 'package:flutter/material.dart';

import '../../services/course_storage.dart';
import '../../theme/app_theme.dart';
import '../user/user_cards.dart';

/// 课表设置页（v1.1.0）：显示开关 + 课程管理。
///
/// UI **完全复刻在线版**（用户要求）：顶部提示条 + 每行带副标题 + 章节名一致。
/// 差异仅在于「只列出开源版实际支持的项」——在线版的「显示非本周课程」「背景图」
/// 在开源版没有对应实现（无功能就不给开关，避免出现点了没反应的假入口）。
///
/// 入口：课表页右上角**齿轮**（取代原来的「三个点」菜单）。
/// 具体动作由课表页通过回调转发，避免两处各写一套「清空/同步」逻辑。
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
          // 顶部提示条（复刻在线版）
          userCard(
            context,
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 18, color: AppTheme.primaryColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '所有修改即时保存，返回课表自动刷新生效',
                    style:
                        TextStyle(fontSize: 12, color: AppTheme.primaryColor),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _sectionTitle('显示'),
          userCard(
            context,
            padding: EdgeInsets.zero,
            child: _switchTile(
              icon: Icons.grid_on_rounded,
              title: '显示网格线',
              subtitle: '在课表格子与每天之间画出贯穿的分隔线',
              value: _showGridLines,
              onChanged: _setGridLines,
            ),
          ),
          const SizedBox(height: 16),
          _sectionTitle('课程'),
          userCard(
            context,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _actionTile(
                  icon: Icons.add_circle_outline_rounded,
                  title: '添加课程',
                  subtitle: '手动添加没导入到的课，可设单双周与节数',
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onAddCourse();
                  },
                ),
                Divider(height: 1, color: context.borderColor),
                _actionTile(
                  icon: Icons.schedule_rounded,
                  title: '调整上课时间',
                  subtitle: '修改每节课的开始 / 结束时间，作用于整张课表',
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onEditTime();
                  },
                ),
                Divider(height: 1, color: context.borderColor),
                _actionTile(
                  icon: Icons.playlist_add_check_rounded,
                  title: '同步今日课程到待办',
                  subtitle: '把今天的课一次性写进待办清单',
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onSyncTodos();
                  },
                ),
                Divider(height: 1, color: context.borderColor),
                _actionTile(
                  icon: Icons.delete_sweep_rounded,
                  title: '清空全部课程',
                  subtitle: '删除课表里的所有课程（不可恢复）',
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

  /// 开关行（复刻在线版：左图标 + 标题 + 副标题 + 右侧开关）。
  Widget _switchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppTheme.primaryColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style:
                          TextStyle(fontSize: 14, color: context.textPrimary)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12, color: context.textTertiary)),
                ],
              ),
            ),
            Transform.scale(
              scale: 0.85,
              child: Switch(
                value: value,
                onChanged: onChanged,
                activeColor: Colors.white,
                activeTrackColor: AppTheme.primaryColor,
              ),
            ),
          ],
        ),
      );

  /// 操作行（复刻在线版：左图标 + 标题 + 副标题 + 右箭头）。
  Widget _actionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool danger = false,
  }) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(icon,
                  size: 20,
                  color: danger ? AppTheme.danger : AppTheme.primaryColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        style: TextStyle(
                          fontSize: 14,
                          color: danger
                              ? AppTheme.danger
                              : context.textPrimary,
                        )),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12, color: context.textTertiary)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: context.textTertiary),
            ],
          ),
        ),
      );
}
