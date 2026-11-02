import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'display_settings_page.dart';
import 'legal_doc_page.dart';
import 'notification_settings_page.dart';

import '../services/legal_consent.dart';
import '../theme/app_theme.dart';
import 'feedback_dialog.dart';
import 'user/user_cards.dart';

/// App 设置页（设置齿轮入口）。
///
/// 结构（2026-10-30 重构）：
///   【通用】
///     · 通知提醒（第一位，专管权限 / 系统优化）
///     · 界面与显示（独立页：主题色 / 底部导航 / 首页个性化 / 字体 / 语言 / 动效 / 振动）
///   【帮助与反馈】
///     · 意见反馈 / 隐私政策 / 用户协议 / 联系邮箱 / 清除本机数据
///     · 退出登录（最下方，文字居中）
class SettingsPage extends StatefulWidget {
  final Future<void> Function() onLogout;
  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode) onThemeChanged;

  /// 当前主题色（外部 ValueNotifier，便于本页与全局同步）。
  final ValueNotifier<Color> primaryColor;
  final Future<void> Function(Color) onPrimaryChanged;

  const SettingsPage({
    super.key,
    required this.onLogout,
    required this.themeMode,
    required this.onThemeChanged,
    required this.primaryColor,
    required this.onPrimaryChanged,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录',
            style: TextStyle(fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
        content: const Text('确定要退出登录吗？\n退出后本机的课表、待办、成绩等数据会被清空。',
            style: TextStyle(fontSize: AppTheme.fontBody, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.danger,
              foregroundColor: Colors.white,
            ),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.onLogout();
    if (mounted) Navigator.of(context).pop();
  }

  /// 分区小标题（灰、字小、字距宽），用于「通用」「帮助与反馈」两段。
  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 16, 6, 8),
        child: Text(
          text,
          style: TextStyle(
            fontSize: AppTheme.fontSmall,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.4,
            color: context.textTertiary,
          ),
        ),
      );

  Widget _entry({
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: Icon(icon, size: 20, color: AppTheme.primaryColor),
        title: Text(title,
            style: TextStyle(fontSize: AppTheme.fontBody, color: context.textPrimary)),
        subtitle: subtitle == null
            ? null
            : Text(subtitle,
                style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
        trailing:
            Icon(Icons.chevron_right, size: 20, color: context.textTertiary),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('设置',
            style: TextStyle(fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          _sectionLabel('通用'),
          userCard(
            context,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                // 通知提醒排在第一位：提醒不响是最高频的问题。
                _entry(
                  icon: Icons.notifications_active_outlined,
                  title: '通知提醒',
                  subtitle: '通知权限、精确闹钟、电池优化、自启动',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const NotificationSettingsPage())),
                ),
                Divider(height: 1, color: context.borderColor),
                _entry(
                  icon: Icons.palette_outlined,
                  title: '界面与显示',
                  subtitle: '主题色、底部导航、首页个性化、字体、语言、动效',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const DisplaySettingsPage())),
                ),
              ],
            ),
          ),
          _sectionLabel('帮助与反馈'),
          userCard(
            context,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _entry(
                  icon: Icons.feedback_outlined,
                  title: '意见反馈',
                  subtitle: '问题、建议都可以写在这里',
                  onTap: () => showFeedbackDialog(context),
                ),
                Divider(height: 1, color: context.borderColor),
                _entry(
                  icon: Icons.privacy_tip_outlined,
                  title: '隐私政策',
                  onTap: () =>
                      _openLegal('隐私政策', 'assets/legal/privacy_policy.md'),
                ),
                Divider(height: 1, color: context.borderColor),
                _entry(
                  icon: Icons.description_outlined,
                  title: '用户协议',
                  onTap: () =>
                      _openLegal('用户协议', 'assets/legal/user_agreement.md'),
                ),
                Divider(height: 1, color: context.borderColor),
                _entry(
                  icon: Icons.mail_outline_rounded,
                  title: '联系 / 投诉邮箱',
                  subtitle: kLegalContactEmail,
                  onTap: _contactEmail,
                ),
                Divider(height: 1, color: context.borderColor),
                _entry(
                  icon: Icons.cleaning_services_outlined,
                  title: '清除本机数据',
                  subtitle: '删除账号、课表、成绩、待办等本地数据',
                  onTap: _confirmClearData,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          // 退出登录：最下方，文字居中。
          TextButton(
            onPressed: _confirmLogout,
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.danger,
              minimumSize: const Size(double.infinity, 46),
            ),
            child: const Text('退出登录',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: AppTheme.fontBody, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 14),
          // ICP 备案号：设置页最底部，商店审核与工信部要求可见。
          // 不抢视觉，用最小字号 + 三级文字色，点击跳工信部查询页。
          InkWell(
            onTap: _openIcp,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              child: Text(
                kIcpNumber,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _openIcp() async {
    final uri = Uri.parse(kIcpUrl);
    if (!await launchUrl(uri)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('备案号 $kIcpNumber，可在工信部网站查询')),
      );
    }
  }

  void _openLegal(String title, String assetPath) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LegalDocPage(title: title, assetPath: assetPath),
      ),
    );
  }

  Future<void> _contactEmail() async {
    final uri = Uri.parse(
        'mailto:$kLegalContactEmail?subject=${Uri.encodeComponent('掌上锡院投诉反馈')}');
    if (!await launchUrl(uri)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开邮件应用，请手动发送至 $kLegalContactEmail')),
      );
    }
  }

  Future<void> _confirmClearData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除本机数据'),
        content: const Text(
          '将删除本机保存的账号、课表、成绩、待办、设置等数据。\n\n'
          '此操作无法撤销，确定继续吗？',
          style: TextStyle(fontSize: AppTheme.fontBody, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.danger,
              foregroundColor: Colors.white,
            ),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.onLogout();
    if (mounted) Navigator.of(context).pop();
  }
}
