import 'package:flutter/material.dart';

import '../services/nav_prefs.dart';
import '../theme/app_theme.dart';
import 'user/user_cards.dart';

/// 底部导航自定义（v1.7.0）。
///
/// 用户要求：**除用户页以外，底部导航的页面都可以隐藏，也可以随意调节顺序**。
///  · 拖动左侧图标…… 准确说右侧的拖动手柄可以上下排序；
///  · 右侧开关控制「是否显示」；
///  · 用户页**固定显示**：没有拖动手柄、开关锁死（用锁图标占位，不堆说明文字）。
///
/// 改动**即时生效**（写进 [NavPrefs.notifier]，MainApp 监听它重建导航条），
/// 返回时底部导航已经是新样子，不需要重启。
class NavBarSettingsPage extends StatelessWidget {
  const NavBarSettingsPage({super.key});

  void _onReorder(int oldIndex, int newIndex) {
    final order = List<NavPage>.from(NavPrefs.layout.order);
    if (oldIndex < 0 || oldIndex >= order.length) return;
    // ReorderableListView 的 newIndex 是「插入前的下标」，下移时要减一
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex < 0 || newIndex >= order.length) return;
    final moved = order.removeAt(oldIndex);
    order.insert(newIndex, moved);
    NavPrefs.setOrder(order);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('底部导航',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: ValueListenableBuilder<NavLayout>(
        valueListenable: NavPrefs.notifier,
        builder: (context, layout, __) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            userCard(
              context,
              padding: EdgeInsets.zero,
              child: ReorderableListView(
                // 外层已经是 ListView → 内层不再自己滚
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                // 整行拖动会和开关抢手势 → 只认右侧那个手柄
                buildDefaultDragHandles: false,
                onReorder: _onReorder,
                children: [
                  for (int i = 0; i < layout.order.length; i++)
                    _row(context, layout.order[i], i, layout: layout),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 固定页单独一张卡：一眼看出它不在上面那张"可调"的卡里
            userCard(
              context,
              padding: EdgeInsets.zero,
              child: _pinnedRow(context),
            ),
          ],
        ),
      ),
    );
  }

  /// 可调项：图标 + 名称 + 显示开关 + 拖动手柄。
  Widget _row(BuildContext context, NavPage page, int index,
      {required NavLayout layout}) {
    final on = !layout.hidden.contains(page);
    return SizedBox(
      // ⚠️ ReorderableListView 的每个 child 必须有稳定 key
      key: ValueKey<String>(page.id),
      height: 56,
      child: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Row(
          children: [
            Icon(page.icon,
                size: 20,
                color: on ? AppTheme.primaryColor : context.textTertiary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                page.label,
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
                onChanged: (v) => NavPrefs.setHidden(page, !v),
                activeColor: Colors.white,
                activeTrackColor: AppTheme.primaryColor,
              ),
            ),
            SizedBox(
              width: 40,
              child: Center(
                child: ReorderableDragStartListener(
                  index: index,
                  child: Icon(Icons.drag_handle_rounded,
                      size: 20, color: context.textTertiary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 固定项（用户页）：没有拖动手柄、开关锁死 —— 只用图标表达，不写说明文字。
  Widget _pinnedRow(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Row(
          children: [
            Icon(kPinnedNavPage.icon, size: 20, color: AppTheme.primaryColor),
            const SizedBox(width: 12),
            Expanded(
              child: Text(kPinnedNavPage.label,
                  style: TextStyle(fontSize: 14.5, color: context.textPrimary)),
            ),
            Transform.scale(
              scale: 0.8,
              child: Switch(
                value: true,
                // 不可关：用户页是账号设置的唯一入口，藏掉就没地方找回来
                onChanged: null,
                activeColor: Colors.white,
                activeTrackColor: AppTheme.primaryColor,
              ),
            ),
            SizedBox(
              width: 40,
              child: Center(
                child: Icon(Icons.lock_outline_rounded,
                    size: 18, color: context.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
