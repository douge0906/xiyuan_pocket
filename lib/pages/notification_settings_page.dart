import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../repositories/todo_repository.dart';
import '../services/app_locale.dart';
import '../services/notification_health.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';

/// 通知提醒设置（首页设置页的第一个入口）。
///
/// 目标：把「通知不响」这件事的所有原因都摆到明面上，并给出**一键跳转**：
///   1. 通知权限（Android 13+ POST_NOTIFICATIONS）
///   2. 精确闹钟（闹钟和提醒）
///   3. 电池优化（系统会杀掉后台闹钟）
///   4. 后台运行 / 自启动（厂商 ROM）
///   5. 通知渠道重要性（上课提醒 / 待办提醒）
///   6. 诊断：还有多少条提醒已排进系统队列
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  bool _loading = true;
  bool _notificationsOn = false;
  bool _exactAlarmOn = false;
  int _pending = -1;

  /// 「到底卡在哪一步」的一句话结论（见 [NotificationService.diagnose]）。
  String _diagnosis = '';
  bool _rescheduling = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final notif = await NotificationService.notificationsEnabled();
    final exact = await NotificationService.exactAlarmsEnabled();
    final pending = await NotificationService.pendingCount();
    final diagnosis = await NotificationService.diagnose();
    if (!mounted) return;
    setState(() {
      _notificationsOn = notif;
      _exactAlarmOn = exact;
      _pending = pending;
      _diagnosis = diagnosis;
      _loading = false;
    });
  }

  /// 手动把全部待办提醒重排一遍，并把**真实结果**报出来。
  ///
  /// 🔴 为什么需要这个按钮（2026-11-02）：
  ///    `rescheduleAll()` 原来返回 void，三级降级全失败时无人知晓 ——
  ///    用户能做的只有「杀掉 App 重开，看看还响不响」这种盲试。
  ///    现在一次点击就能拿到「排上 N 条 / 失败 M 条」的确切数字。
  Future<void> _rescheduleTodos() async {
    if (_rescheduling) return;
    setState(() => _rescheduling = true);
    try {
      final r = await TodoRepository.instance.rescheduleAll();
      NotificationHealth.instance.report(scheduled: r.scheduled, failed: r.failed);
      if (!mounted) return;
      _toast(NotificationHealth.instance.summary);
      await _refresh();
    } finally {
      if (mounted) setState(() => _rescheduling = false);
    }
  }

  Future<void> _requestNotifications() async {
    final ok = await NotificationService.requestPermission();
    if (!mounted) return;
    if (ok) {
      _toast('通知权限已开启');
    } else {
      _toast('未获得通知权限，请在系统设置中手动开启');
    }
    await _refresh();
  }

  Future<void> _requestExactAlarm() async {
    await NotificationService.ensureExactAlarmPermission();
    await _refresh();
  }

  /// 打开本应用的系统详情页（权限 / 电池优化 / 自启动都在这里）。
  Future<void> _openAppSettings() async {
    var ok = false;
    try {
      ok = await openAppSettings();
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      _toast('无法自动跳转，请手动进入「设置 → 应用 → 掌上锡院」');
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final border = isDark ? const Color(0xFF2C2C2C) : const Color(0xFFE5E7EB);

    Widget row({
      required IconData icon,
      required String title,
      required String subtitle,
      required bool granted,
      required String grantedText,
      required String deniedText,
      VoidCallback? onTap,
      String? actionLabel,
    }) {
      return InkWell(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            border: Border.all(color: border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 22, color: AppTheme.primaryColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(title,
                              style: TextStyle(
                                  fontSize: AppTheme.fontTitle,
                                  fontWeight: FontWeight.w600,
                                  color: context.textPrimary)),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: granted
                                ? const Color(0xFF10B981).withValues(alpha: .12)
                                : const Color(0xFFEF4444).withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            granted ? grantedText : deniedText,
                            style: TextStyle(
                              fontSize: AppTheme.fontCaption,
                              fontWeight: FontWeight.w600,
                              color: granted
                                  ? const Color(0xFF10B981)
                                  : const Color(0xFFEF4444),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: AppTheme.fontSmall, color: context.textSecondary)),
                    if (actionLabel != null) ...[
                      const SizedBox(height: 8),
                      Text(actionLabel,
                          style: TextStyle(
                              fontSize: AppTheme.fontSmall,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primaryColor)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(S.t('notif_title')),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
        children: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            row(
              icon: Icons.notifications_active_outlined,
              title: S.t('notif_perm'),
              subtitle: S.t('notif_perm_desc'),
              granted: _notificationsOn,
              grantedText: '已开启',
              deniedText: '未开启',
              actionLabel: _notificationsOn ? null : '点击申请 / 去系统设置开启',
              onTap: _requestNotifications,
            ),
            row(
              icon: Icons.alarm_on_outlined,
              title: S.t('notif_exact'),
              subtitle: S.t('notif_exact_desc'),
              granted: _exactAlarmOn,
              grantedText: '已授权',
              deniedText: '未授权',
              actionLabel: _exactAlarmOn ? null : '点击跳转系统「闹钟和提醒」',
              onTap: _requestExactAlarm,
            ),
            row(
              icon: Icons.battery_saver_outlined,
              title: S.t('notif_battery'),
              subtitle: S.t('notif_battery_desc'),
              granted: false,
              grantedText: '',
              deniedText: '需手动确认',
              actionLabel: '点击打开系统电池优化列表',
              onTap: _openAppSettings,
            ),
            row(
              icon: Icons.settings_suggest_outlined,
              title: S.t('notif_bg'),
              subtitle: S.t('notif_bg_desc'),
              granted: false,
              grantedText: '',
              deniedText: '需手动确认',
              actionLabel: '点击打开应用信息页',
              onTap: _openAppSettings,
            ),
            row(
              icon: Icons.tune_outlined,
              title: S.t('notif_channel'),
              subtitle: S.t('notif_channel_desc'),
              granted: false,
              grantedText: '',
              deniedText: '去系统调整',
              actionLabel: '点击打开应用信息页 → 通知',
              onTap: _openAppSettings,
            ),
            row(
              icon: Icons.monitor_heart_outlined,
              title: S.t('notif_check'),
              // 🔴 2026-11-02：原来这里只显示「已排入 N 条」，
              //    排 0 条时用户完全不知道是哪一环断了
              //    （权限？精确闹钟？还是重排根本没跑）。
              //    现在直接用 NotificationService.diagnose() 的一句话结论，
              //    并把最近一次全量重排的真实结果附在后面。
              subtitle: _diagnosis.isEmpty
                  ? (_pending < 0
                      ? '暂时读不到系统队列'
                      : '系统队列里已排入 $_pending 条定时提醒')
                  : '$_diagnosis\n${NotificationHealth.instance.summary}',
              granted: _pending > 0,
              grantedText: '正常',
              deniedText: '未排入',
              actionLabel: '点击重新检测',
              onTap: _refresh,
            ),
          ],
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: () async {
                final ok = await NotificationService.showTestNotification();
                if (!mounted) return;
                _toast(ok ? '已发送测试提醒' : '测试提醒发送失败，请检查权限');
              },
              icon: const Icon(Icons.notifications_none_rounded, size: 18),
              label: Text(S.t('notif_test')),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primaryColor,
                side: BorderSide(color: border),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(AppTheme.radiusLg)),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: _rescheduling ? null : _rescheduleTodos,
              icon: _rescheduling
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重新排程全部待办提醒'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primaryColor,
                side: BorderSide(color: border),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(AppTheme.radiusLg)),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Text(
              '「重新排程」会把所有待办提醒重新写进系统闹钟队列，'
              '并告诉你真实排上了几条。如果显示「排程失败」，'
              '多半是上面第 2 项「闹钟和提醒」权限被关掉了。',
              style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  height: 1.6,
                  color: context.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}
