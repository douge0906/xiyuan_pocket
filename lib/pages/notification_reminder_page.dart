import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../repositories/todo_repository.dart';
import '../services/course_reminder_service.dart';
import '../services/live_update_service.dart';
import '../services/notification_health.dart';
import '../services/notification_service.dart';
import '../services/power_status.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_card.dart';

/// 通知与提醒（合并页，v1.0.9 用户需求 #9）。
///
/// ## 为什么把两页合成一页
///
/// 之前是「通知提醒」和「课程提醒」两个入口：
///   · 前者讲权限（通知 / 精确闹钟 / 电池 / 自启动），
///   · 后者讲课程提醒开关与提前量。
///
/// 用户的实际问题从来不是「权限」或「开关」中的某一个，而是
/// **「我打开了课程提醒，为什么到点不响」** —— 答案横跨两页：
/// 开关在第二页、权限在第一页、排程条数在第二页、诊断结论在第一页。
/// 排查一次要在两个页面之间来回跳，而且两页各自都写着「已完成」。
///
/// 所以按用户给的参考（掌上徐工）合成一页三组：
///
///   ① 提醒       —— 课程与待办开关 / 提前时间 / 倒计时悬挂 / 安卓通知岛
///   ② 后台与权限 —— 通知权限 / 精确闹钟 / 振动与渠道 / 自启动 / 电池优化
///
/// ## 视觉口径（用户原话：「盒子大小高度相同，去除不必要的小字」）
///
///   · 每一行都是 **固定 56 高**（`_rowHeight`），不再出现「两行长副标题
///     把最后一行挤到屏幕外」；
///   · 没有副标题。状态一律是右侧一小段文字（已授权 / 未授权 / 15 分钟…），
///     说明文字只有底部一段总结，且每个分组最多一句；
///   · 颜色全部走语义令牌（`context.successColor` / `dangerColor` /
///     `textTertiary`），不再用裸 `Colors.green` —— 那套在深色下是错的。
class NotificationReminderPage extends StatefulWidget {
  const NotificationReminderPage({super.key});

  @override
  State<NotificationReminderPage> createState() =>
      _NotificationReminderPageState();
}

class _NotificationReminderPageState extends State<NotificationReminderPage>
    with WidgetsBindingObserver {
  /// 所有行统一高度（用户要求「盒子大小高度相同」）。
  static const double _rowHeight = 56;

  bool _loading = true;

  // ① 提醒
  bool _enabled = true;
  int _lead = 10;
  bool _liveUpdate = true;
  bool _todoReminder = true;
  Map<String, dynamic> _stats = {};

  // ② 后台与权限
  bool _notifOk = false;
  bool _exactOk = false;
  /// 「上课提醒」渠道是否开着振动（null = 渠道还没建 / 读不到）。
  bool? _vibrate;
  bool? _batteryIgnoring;
  int? _standbyBucket;
  bool? _backgroundRestricted;
  int _pending = -1;
  String _diagnosis = '';
  Map<String, dynamic> _capsule = {};

  /// 用户自己勾过的「系统不给读」的项（自启动）。
  Set<String> _checked = {};

  static const String _kIdAutoStart = 'autostart';
  static const String _legacyBatteryId = 'battery';

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 从系统设置页（通知权限 / 闹钟和提醒 / 通知渠道 / 电池）返回时必须重读，
    // 否则用户看到的是进页面那一刻的旧状态，会以为没生效而反复操作。
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    // 这里要读 10 个不同的系统/插件状态，任何一项抛异常（缺通道、权限被拒、
    // 系统私有 API 变动）都会让整个 async 中断 —— 而 _loading 只有在函数末尾
    // 才被置 false。结果就是页面永远停在转圈，用户以为 App 卡死。
    // 所以整段包 try/catch：探测失败就用默认值渲染，能改的项依然可点。
    try {
      await _refreshInner();
    } catch (e, st) {
      debugPrint('[NotificationReminder] 读取状态失败: $e\n$st');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _refreshInner() async {
    final enabled = await CourseReminderService.isEnabled();
    final lead = await CourseReminderService.leadMinutes();
    final liveUpdate = await CourseReminderService.liveUpdateEnabled();
    final todoReminder = await TodoRepository.todoReminderEnabled();

    final notifOk = await NotificationService.notificationsEnabled();
    final exactOk = await NotificationService.exactAlarmsEnabled();
    final pending = await NotificationService.pendingCount();
    final diagnosis = await NotificationService.diagnose();
    final vibrate = await PowerStatus.channelVibration();
    final power = await PowerStatus.read(force: true);
    final checked = await StorageService.loadNotifChecked();
    final capsule = await LiveUpdateService.status();

    var stats = await CourseReminderService.stats();
    // 自愈：开关显示已开启却查不到排程记录（换机 / 清数据 / 历史默认开启），
    // 进页面时自动重排一次，避免"开了但没排上"的空窗。
    if (enabled && stats['count'] == null) {
      await CourseReminderService.rescheduleAll();
      stats = await CourseReminderService.stats();
    }

    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _lead = lead;
      _liveUpdate = liveUpdate;
      _todoReminder = todoReminder;
      _notifOk = notifOk;
      _exactOk = exactOk;
      _vibrate = vibrate;
      _pending = pending;
      _diagnosis = diagnosis;
      _batteryIgnoring = power?['ignoringBatteryOptimizations'] as bool?;
      _standbyBucket = power?['standbyBucket'] as int?;
      _backgroundRestricted = power?['backgroundRestricted'] as bool?;
      _checked = checked;
      _capsule = capsule;
      _stats = stats;
      _loading = false;
    });
  }

  // ==================== ① 提醒 ====================

  Future<void> _toggleEnabled(bool value) async {
    if (!value) {
      await CourseReminderService.setEnabled(false);
      await _refresh();
      if (!mounted) return;
      _toast('课程提醒已关闭，已清除全部已排提醒');
      return;
    }
    // 权限没拿到就不落盘：否则开关显示开着、提醒排进一个永远发不出的
    // 通道，用户以为开了，实际一条都不响。
    var notifOk = await NotificationService.requestPermission();
    if (!notifOk) notifOk = await NotificationService.notificationsEnabled();
    if (!notifOk) {
      await openAppSettings();
      notifOk = await NotificationService.notificationsEnabled();
      if (!notifOk) {
        await _refresh();
        if (!mounted) return;
        _toast('未获得通知权限，课程提醒没有开启。请在系统「通知管理」里允许本应用通知后重试');
        return;
      }
    }
    await NotificationService.ensureExactAlarmPermission();
    await CourseReminderService.setEnabled(true);
    await _refresh();
    if (!mounted) return;
    _toast('课程提醒已开启：提前 $_lead 分钟');
  }

  Future<void> _toggleTodoReminder(bool value) async {
    await TodoRepository.setTodoReminderEnabled(value);
    // 立即重排：关闭时撤下全部待办通知，开启时把已有待办补排回来。
    await TodoRepository.instance.rescheduleAll();
    await _refresh();
    if (!mounted) return;
    _toast(value ? '待办提醒已开启' : '待办提醒已关闭，已清除待办提醒');
  }

  Future<void> _pickLead() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => _LeadDialog(current: _lead),
    );
    if (picked == null || !mounted) return;
    await CourseReminderService.setLeadMinutes(picked);
    if (_enabled) await CourseReminderService.rescheduleAll();
    await _refresh();
  }

  Future<void> _toggleLiveUpdate(bool value) async {
    await CourseReminderService.setLiveUpdate(value);
    if (_enabled) await CourseReminderService.rescheduleAll();
    await _refresh();
  }

  // ==================== ② 后台与权限 ====================

  Future<void> _requestNotifications() async {
    final ok = await NotificationService.requestPermission();
    if (!ok) {
      await openAppSettings();
    }
    await _refresh();
    if (!mounted) return;
    final now = await NotificationService.notificationsEnabled();
    _toast(now ? '通知权限已开启' : '未获得通知权限，请在系统「通知管理」里手动开启');
  }

  Future<void> _requestExact() async {
    final ok = await NotificationService.ensureExactAlarmPermission();
    if (!ok && mounted) {
      _toast('请在打开的页面里允许「闹钟和提醒」；部分手机在 应用信息 → 权限 里');
    }
    await _refresh();
  }

  /// 「通知振动」：Android 8.0+ 的振动开关只在**通知渠道**里，App 内改不了，
  /// 只能跳到系统通知设置页让用户自己开。
  Future<void> _openNotificationSettings() async {
    final opened = await PowerStatus.openNotificationSettings();
    if (!mounted) return;
    if (!opened) {
      await openAppSettings();
      return;
    }
    _toast('在「上课提醒」分类里打开「振动」；不同系统位置略有差异');
  }

  Future<void> _openAutoStart() async {
    await openAppSettings();
    if (!mounted) return;
    _toast('在应用信息里允许「自启动」并允许后台运行；再把省电策略设为「无限制」');
    await _refresh();
  }

  Future<void> _openBattery() async {
    final opened = await PowerStatus.openSettings();
    if (!mounted) return;
    if (!opened) {
      await openAppSettings();
      return;
    }
    _toast('在系统页面里选择「不受限制」后返回，状态会自动刷新');
  }

  Future<void> _toggleChecked(String id, bool on) async {
    final next = Set<String>.of(_checked);
    if (on) {
      next.add(id);
    } else {
      next.remove(id);
    }
    setState(() => _checked = next);
    await StorageService.saveNotifChecked(next);
  }

  /// 电池优化这一项到底算不算搞定。
  ///
  /// 读得到人和话（`describe() != null`）就以真实状态为准；读不到才退回
  /// 用户手勾。两边判据必须同源，否则进度条算完成、行里却写「待确认」。
  bool get _batteryOk {
    final desc = PowerStatus.describe(
      _batteryIgnoring,
      bucket: _standbyBucket,
      restricted: _backgroundRestricted,
    );
    if (desc == null) return _checked.contains(_legacyBatteryId);
    return PowerStatus.problem(
          ignoring: _batteryIgnoring,
          bucket: _standbyBucket,
          restricted: _backgroundRestricted,
        ) !=
        true;
  }

  // ==================== 底部操作 ====================

  Future<void> _sendTest() async {
    final ok = await CourseReminderService.fireTest();
    if (!mounted) return;
    _toast(CourseReminderService.describeTestResult(ok: ok));
    Future.delayed(const Duration(seconds: 6), () {
      if (mounted) _refresh();
    });
  }

  Future<void> _rescheduleAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final course = await CourseReminderService.rescheduleAll();
      final todo = await TodoRepository.instance.rescheduleAll();
      NotificationHealth.instance
          .report(scheduled: course + todo.scheduled, failed: todo.failed);
      if (!mounted) return;
      _toast('已重排：课程 $course 条 · 待办 ${todo.scheduled} 条'
          '${todo.failed > 0 ? '，失败 ${todo.failed} 条' : ''}');
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('通知与提醒',
            style: TextStyle(
                fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: EdgeInsets.fromLTRB(
                  16, 12, 16, MediaQuery.of(context).padding.bottom + 24),
              children: [
                _group('提醒', _courseRows()),
                const SizedBox(height: 14),
                _group('后台与权限', _permissionRows()),
                const SizedBox(height: 16),
                _primaryButton(
                  icon: Icons.alarm_rounded,
                  label: '发送测试提醒',
                  onTap: _sendTest,
                ),
                const SizedBox(height: 10),
                _secondaryButton(
                  icon: Icons.refresh_rounded,
                  label: '重新排程全部提醒',
                  busy: _busy,
                  onTap: _rescheduleAll,
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    _summaryLine(),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: AppTheme.fontCaption,
                        height: 1.5,
                        color: context.textTertiary),
                  ),
                ),
              ],
            ),
    );
  }

  String _summaryLine() {
    if (!_todoReminder) {
      return '待办提醒已关闭，新建待办不会响铃；重新开启后会自动补排。';
    }
    final count = (_stats['count'] as num?)?.toInt() ?? 0;
    if (!_enabled) return '课程提醒已关闭，打开后按课表自动预排未来 7 天。';
    final next = _nextText();
    if (count == 0) return '未来 7 天没有待提醒的课（都已过提醒时间）。';
    return '未来 7 天已排 $count 条 · 下一条 $next';
  }

  String _nextText() {
    final iso = (_stats['nextAt'] ?? '').toString();
    final at = iso.isEmpty ? null : DateTime.tryParse(iso);
    if (at == null) return '—';
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay = at.year == now.year && at.month == now.month && at.day == now.day;
    final day = sameDay ? '今天' : '${at.month}月${at.day}日';
    return '$day $hh:$mm';
  }

  // ---------- 分组外壳 ----------

  Widget _group(String title, List<Widget> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: TextStyle(
                fontSize: AppTheme.fontSmall,
                fontWeight: FontWeight.w600,
                color: context.textTertiary),
          ),
        ),
        AppCard(
          radius: AppTheme.radiusLg,
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: 48,
                    color: context.borderColor,
                  ),
                rows[i],
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ---------- ① 提醒 ----------

  List<Widget> _courseRows() {
    final liveOn = _capsule['supported'] == true;
    return [
      _switchRow(
        icon: Icons.notifications_active_rounded,
        title: '开启课程提醒',
        value: _enabled,
        onChanged: _toggleEnabled,
      ),
      _switchRow(
        icon: Icons.check_circle_outline_rounded,
        title: '开启待办提醒',
        value: _todoReminder,
        onChanged: _toggleTodoReminder,
      ),
      _row(
        icon: Icons.schedule_rounded,
        title: '提前提醒时间',
        value: '$_lead 分钟',
        onTap: _enabled ? _pickLead : null,
      ),
      _switchRow(
        icon: Icons.bolt_rounded,
        title: '安卓通知岛',
        value: _liveUpdate && liveOn,
        enabled: _enabled && Platform.isAndroid,
        onChanged: _enabled && liveOn ? _toggleLiveUpdate : null,
        trailingText: !Platform.isAndroid
            ? '仅安卓'
            : (liveOn ? null : '需 Android 16'),
      ),
    ];
  }

  // ---------- ② 后台与权限 ----------

  List<Widget> _permissionRows() {
    final batteryDesc = PowerStatus.describe(
      _batteryIgnoring,
      bucket: _standbyBucket,
      restricted: _backgroundRestricted,
    );
    final autoStartOn = _checked.contains(_kIdAutoStart);
    return [
      _row(
        icon: Icons.notifications_outlined,
        title: '通知权限',
        value: _notifOk ? '已授权' : '未授权',
        ok: _notifOk,
        onTap: _requestNotifications,
      ),
      _row(
        icon: Icons.alarm_on_outlined,
        title: '精确闹钟',
        value: _exactOk ? '已授权' : '未授权',
        ok: _exactOk,
        onTap: _requestExact,
      ),
      _row(
        icon: Icons.vibration_rounded,
        title: '通知振动',
        value: _vibrate == null
            ? '去开启'
            : (_vibrate! ? '已开启' : '已关闭'),
        ok: _vibrate,
        onTap: _openNotificationSettings,
      ),
      _row(
        icon: Icons.settings_suggest_outlined,
        title: '后台运行与自启动',
        value: autoStartOn ? '已设置' : '去设置',
        ok: autoStartOn ? true : null,
        onTap: _openAutoStart,
        trailing: _manualTick(
          on: autoStartOn,
          onTap: () => _toggleChecked(_kIdAutoStart, !autoStartOn),
        ),
      ),
      _row(
        icon: Icons.battery_saver_outlined,
        title: '忽略电池优化',
        value: batteryDesc != null
            ? (_batteryOk ? '已忽略' : '受限')
            : (_batteryOk ? '已确认' : '待确认'),
        ok: batteryDesc != null ? _batteryOk : null,
        onTap: _openBattery,
      ),
      _row(
        icon: Icons.monitor_heart_outlined,
        title: '提醒自检',
        value: _pending > 0 ? '队列 $_pending 条' : (_pending < 0 ? '读不到' : '未排入'),
        ok: _pending > 0 ? true : null,
        onTap: () async {
          if (!mounted) return;
          _toast(_diagnosis.isEmpty
              ? (_pending > 0
                  ? '系统队列里已排入 $_pending 条定时提醒'
                  : '队列里没有定时提醒，点下方「重新排程全部提醒」')
              : '$_diagnosis\n${NotificationHealth.instance.summary}');
          await _refresh();
        },
      ),
    ];
  }

  // ---------- 行组件（统一 56 高）----------

  Widget _row({
    required IconData icon,
    required String title,
    String? value,
    bool? ok,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    final valueColor = ok == null
        ? context.textTertiary
        : (ok ? context.successColor : context.dangerColor);
    return SizedBox(
      height: _rowHeight,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(icon, size: 20, color: context.textSecondary),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w500,
                      color: context.textPrimary),
                ),
              ),
              if (value != null)
                Text(
                  value,
                  maxLines: 1,
                  style: TextStyle(
                      fontSize: AppTheme.fontSmall,
                      fontWeight: FontWeight.w600,
                      color: valueColor),
                ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing,
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _switchRow({
    required IconData icon,
    required String title,
    required bool value,
    ValueChanged<bool>? onChanged,
    bool enabled = true,
    String? trailingText,
  }) {
    return SizedBox(
      height: _rowHeight,
      child: Padding(
        padding: const EdgeInsets.only(left: 14, right: 6),
        child: Row(
          children: [
            Icon(icon, size: 20, color: context.textSecondary),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w500,
                    color: enabled ? context.textPrimary : context.textTertiary),
              ),
            ),
            if (trailingText != null)
              Text(
                trailingText,
                style: TextStyle(
                    fontSize: AppTheme.fontSmall, color: context.textTertiary),
              ),
            Transform.scale(
              scale: 0.82,
              child: Switch(
                value: value,
                onChanged: onChanged,
                thumbColor: const WidgetStatePropertyAll<Color>(Colors.white),
                trackColor: WidgetStateProperty.resolveWith<Color>((states) {
                  if (states.contains(WidgetState.selected)) {
                    return AppTheme.primaryColor;
                  }
                  return context.borderColor;
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 手勾小方框：系统不给读的项，让用户自己确认一次。
  Widget _manualTick({required bool on, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          on ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
          size: 20,
          color: on ? context.successColor : context.textTertiary,
        ),
      ),
    );
  }

  Widget _primaryButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 48,
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label,
            style: const TextStyle(
                fontSize: AppTheme.fontBody, fontWeight: FontWeight.w600)),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.primaryColor,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd)),
        ),
      ),
    );
  }

  Widget _secondaryButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool busy = false,
  }) {
    return SizedBox(
      height: 48,
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: busy ? null : onTap,
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(icon, size: 18),
        label: Text(label,
            style: const TextStyle(
                fontSize: AppTheme.fontBody, fontWeight: FontWeight.w500)),
        style: OutlinedButton.styleFrom(
          foregroundColor: context.textPrimary,
          side: BorderSide(color: context.borderColor),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd)),
        ),
      ),
    );
  }
}

/// 提前提醒时间选择（5 / 10 / 15 / 20 / 30 + 自定义）。
///
/// 独立成 widget 是为了让输入框 controller 的 dispose 有落点 ——
/// 原来写在 State 里、每次弹窗都新建一个 controller 且从不 dispose。
class _LeadDialog extends StatefulWidget {
  const _LeadDialog({required this.current});

  final int current;

  @override
  State<_LeadDialog> createState() => _LeadDialogState();
}

class _LeadDialogState extends State<_LeadDialog> {
  static const List<int> _presets = [5, 10, 15, 20, 30];
  final TextEditingController _ctl = TextEditingController();
  late int _value = widget.current;

  @override
  void initState() {
    super.initState();
    if (!_presets.contains(_value)) _ctl.text = '$_value';
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _submit() {
    final typed = int.tryParse(_ctl.text.trim());
    final v = typed ?? _value;
    if (v < 1 || v > 180) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入 1 ~ 180 之间的分钟数')));
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(color: AppTheme.cardStrokeColor(context.isDark)),
      ),
      title: const Text('提前多久提醒',
          style: TextStyle(
              fontSize: AppTheme.fontTitle, fontWeight: FontWeight.bold)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in _presets)
                _chip('$m 分钟', _value == m && _ctl.text.isEmpty, () {
                  setState(() {
                    _value = m;
                    _ctl.clear();
                  });
                }),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _ctl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (v) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              suffixText: '分钟',
              hintText: '自定义（1 ~ 180）',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd)),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消',
              style: TextStyle(
                  fontSize: AppTheme.fontBody, color: context.textTertiary)),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(minimumSize: const Size(72, 40)),
          child: const Text('确定'),
        ),
      ],
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primaryColor.withValues(alpha: 0.12)
              : context.subtleFill,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          border: Border.all(
            color: selected ? AppTheme.primaryColor : context.borderColor,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppTheme.fontSmall,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? AppTheme.primaryColor : context.textPrimary,
          ),
        ),
      ),
    );
  }
}
