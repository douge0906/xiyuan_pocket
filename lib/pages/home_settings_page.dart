import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'notification_settings_page.dart';

/// 首页独立设置页（右上角齿轮入口）。
///
/// 只放一条：**通知提醒** —— 提醒不响是用户最高频的问题，
/// 权限 / 精确闹钟 / 电池优化 / 自启动全在这一页里。
/// 下面保留一个「账号与隐私」入口，避免退出登录与隐私政策失联。
class HomeSettingsPage extends StatefulWidget {
  const HomeSettingsPage({super.key});

  @override
  State<HomeSettingsPage> createState() => _HomeSettingsPageState();
}

class _HomeSettingsPageState extends State<HomeSettingsPage> {

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final border = isDark ? const Color(0xFF2C2C2C) : const Color(0xFFE5E7EB);

    Widget card(Widget child) => Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            border: Border.all(color: border),
          ),
          child: child,
        );

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('设置'),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SizedBox(height: 6),
          InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const NotificationSettingsPage())),
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            child: card(Row(
              children: [
                Icon(Icons.notifications_active_outlined,
                    size: 22, color: AppTheme.primaryColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('通知提醒',
                          style: TextStyle(
                              fontSize: AppTheme.fontTitle,
                              fontWeight: FontWeight.w600,
                              color: context.textPrimary)),
                      const SizedBox(height: 3),
                      Text('通知权限、精确闹钟、电池优化、自启动一站搞定',
                          style: TextStyle(
                              fontSize: AppTheme.fontSmall, color: context.textSecondary)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    color: context.textTertiary, size: 20),
              ],
            )),
          ),
        ],
      ),
    );
  }
}
