import 'package:flutter/material.dart';

import '../services/widget_sync_service.dart';
import '../theme/app_theme.dart';
import 'widget_info_page.dart';
import 'widget_settings_page.dart';

/// 桌面小组件总入口：怎么添加 + 当前组件列表。
class WidgetHubPage extends StatefulWidget {
  const WidgetHubPage({super.key});

  @override
  State<WidgetHubPage> createState() => _WidgetHubPageState();
}

class _WidgetHubPageState extends State<WidgetHubPage> {
  Set<WidgetComponent> _installed = {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final kinds = await WidgetSyncService.installedComponents();
    if (mounted) setState(() => _installed = kinds);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('桌面小组件',
            style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
          children: [
            _card(
              title: '如何添加',
              children: [
                _step('1', '长按手机桌面空白处'),
                _step('2', '点「小组件」，找到「掌上锡院」'),
                _step('3', '选择组件和尺寸，拖到桌面'),
              ],
            ),
            const SizedBox(height: 12),
            _card(
              title: '组件',
              children: [
                _item(
                  icon: Icons.schedule_rounded,
                  title: '下一节课 / 今日课表',
                  desc: '下一节课 1×2 · 今日课表 2×2 / 4×2',
                  installed: _installed.contains(WidgetComponent.schedule),
                  onTap: () => _open(const WidgetSettingsPage()),
                ),
                Divider(height: 1, color: context.borderColor),
                _item(
                  icon: Icons.event_note_rounded,
                  title: '考试倒计时',
                  desc: '最近一场考试的剩余天数 · 2×2',
                  installed: _installed.contains(WidgetComponent.exam),
                  onTap: () => _open(
                      const WidgetInfoPage(kind: WidgetInfoKind.exam)),
                ),
                Divider(height: 1, color: context.borderColor),
                _item(
                  icon: Icons.credit_card_rounded,
                  title: '校园卡余额',
                  desc: '最近一次同步余额 · 2×1',
                  installed: _installed.contains(WidgetComponent.card),
                  onTap: () => _open(
                      const WidgetInfoPage(kind: WidgetInfoKind.card)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => page),
    );
    _refresh();
  }

  Widget _card({required String title, required List<Widget> children}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary)),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _step(String n, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              ),
              child: Text(n,
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.primaryColor)),
            ),
            const SizedBox(width: 9),
            Expanded(
                child: Text(text,
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall, color: context.textPrimary))),
          ],
        ),
      );

  Widget _item({
    required IconData icon,
    required String title,
    required String desc,
    required bool installed,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 64,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
          children: [
            Icon(icon, size: 21, color: AppTheme.primaryColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary)),
                  const SizedBox(height: 2),
                  Text(desc,
                      style: TextStyle(
                          fontSize: AppTheme.fontCaption, color: context.textTertiary)),
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: (installed ? const Color(0xFF10B981) : Colors.grey)
                    .withValues(alpha: .10),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                installed ? '已添加' : '未添加',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: installed
                      ? const Color(0xFF059669)
                      : context.textTertiary,
                ),
              ),
            ),
            Icon(Icons.chevron_right, color: context.textTertiary),
          ],
          ),
        ),
      ),
    );
  }
}
