import 'package:flutter/material.dart';

import '../services/home_prefs.dart';
import '../theme/app_theme.dart';
import 'user/user_cards.dart';

/// 首页个性化设置（2026-10-16 新功能）。
///
/// 用户要求：把首页拆成 **信息栏 / 周次选择栏 / 今日待办小卡片 / 待办事项** 四块，
/// 每块都能单独隐藏；入口放在首页**右上角**，页面 UI 仿其余设置页。
///
/// 改动**即时生效** —— 直接写进 [HomePrefs]，首页监听它的 notifier 重建，
/// 返回首页就已经是新样子，不需要重启（与「底部导航」设置页同一套路）。
class HomeLayoutSettingsPage extends StatelessWidget {
  const HomeLayoutSettingsPage({super.key});

  /// (板块 id, 图标, 名称) —— 顺序与首页从上到下的顺序一致。
  static const List<(String, IconData, String)> _blocks = <(String, IconData, String)>[
    (HomePrefs.idHeader, Icons.dashboard_rounded, '信息栏'),
    (HomePrefs.idWeekStrip, Icons.calendar_view_week_rounded, '周次选择栏'),
    (HomePrefs.idOverview, Icons.insights_rounded, '今日待办小卡片'),
    (HomePrefs.idTodos, Icons.checklist_rounded, '待办事项'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('首页个性化',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: HomePrefs.notifier,
        builder: (context, _, __) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            userCard(
              context,
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (int i = 0; i < _blocks.length; i++) ...[
                    if (i > 0)
                      Divider(height: 1, color: context.borderColor),
                    _row(context, _blocks[i]),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 一行：图标 + 名称 + 显示开关（仿「底部导航」设置页的行样式）。
  Widget _row(BuildContext context, (String, IconData, String) b) {
    final id = b.$1;
    final on = HomePrefs.isShown(id);
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Row(
          children: [
            Icon(b.$2,
                size: 20,
                color: on ? AppTheme.primaryColor : context.textTertiary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                b.$3,
                style: TextStyle(
                  fontSize: 14.5,
                  color: on ? context.textPrimary : context.textTertiary,
                ),
              ),
            ),
            Transform.scale(
              scale: 0.8,
              child: Switch(
                value: on,
                onChanged: (v) => HomePrefs.setShown(id, v),
                activeColor: Colors.white,
                activeTrackColor: AppTheme.primaryColor,
              ),
            ),
            const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }
}
