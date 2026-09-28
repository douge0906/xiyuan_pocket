import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/course_reminder_service.dart';
import '../services/live_update_service.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';

/// 上课提醒设置页（v2.3.0）。
///
/// 结构：
/// - 三步引导卡（微提醒）：通知权限 → 闹钟和提醒 → 自启动/省电，带实时状态点；
/// - 设置卡：课程提醒开关、提前时间（5/10/15/20 分钟）、测试提醒；
/// - 权限卡：三项权限的当前状态与一键跳转。
/// 权限状态在从系统设置返回时自动刷新（lifecycle resumed）。
class ReminderSettingsPage extends StatefulWidget {
  const ReminderSettingsPage({super.key});

  @override
  State<ReminderSettingsPage> createState() => _ReminderSettingsPageState();
}

class _ReminderSettingsPageState extends State<ReminderSettingsPage>
    with WidgetsBindingObserver {
  bool _loaded = false;
  bool _enabled = true;
  int _lead = 10;
  bool _notifOk = false;
  bool _exactOk = false;
  bool _hang = false; // 是否倒计时（默认关：通知 5 秒后消失）
  Map<String, dynamic> _stats = {}; // 排程统计（条数 + 下一条提醒）
  /// Android 16 实时胶囊（Live Updates / 流体云）诊断状态
  Map<String, dynamic> _capsule = {};

  @override
  void initState() {
    super.initState();
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
    // 从系统设置页（通知/闹钟权限/应用信息）返回时刷新状态
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final enabled = await CourseReminderService.isEnabled();
    final lead = await CourseReminderService.leadMinutes();
    final hang = await CourseReminderService.hangCountdown();
    final notifOk = await NotificationService.notificationsEnabled();
    final exactOk = await NotificationService.exactAlarmsEnabled();
    final capsule = await LiveUpdateService.status();
    var stats = await CourseReminderService.stats();
    // v2.3.8 自愈：开关显示已开启却查不到排程记录（如换机/清数据/历史默认开启），
    // 进页面时自动重排一次，避免"开了但没排上"的空窗。
    if (enabled && stats['count'] == null) {
      await CourseReminderService.rescheduleAll();
      stats = await CourseReminderService.stats();
    }
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _lead = lead;
      _hang = hang;
      _notifOk = notifOk;
      _exactOk = exactOk;
      _capsule = capsule;
      _stats = stats;
      _loaded = true;
    });
  }

  /// 开关：开启前先弹「提醒设置」窗（提前时间 + 是否悬挂倒计时），取消则不开启。
  Future<void> _toggle(bool value) async {
    if (!value) {
      await CourseReminderService.setEnabled(false);
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        duration: Duration(seconds: 3),
        content: Text('课程提醒已关闭，已清除全部已排提醒'),
      ));
      return;
    }
    final ok = await _showSetupDialog(firstTime: true);
    if (ok != true) {
      await _refresh(); // 取消 → 开关回到关闭态
      return;
    }
    await NotificationService.requestPermission();
    final notifOk = await NotificationService.notificationsEnabled();
    if (!notifOk) await openAppSettings();
    await NotificationService.ensureExactAlarmPermission();
    await CourseReminderService.setEnabled(true);
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 3),
      content: Text('课程提醒已开启：提前 $_lead 分钟'
          '${_hang ? '，通知会悬挂倒计时' : '，通知 5 秒后自动消失'}'),
    ));
  }

  /// 提醒设置弹窗：提前时间（5/10/15/20）+ 是否长时间悬挂倒计时。
  /// 返回 true 表示用户确认；firstTime=true 时按钮文案为「开始提醒」。
  /// 提醒设置弹窗：提前时间（预设 + 自定义）+ 是否「倒计时」。
  /// 返回 true 表示用户确认；firstTime=true 时按钮文案为「开始提醒」。
  Future<bool?> _showSetupDialog({bool firstTime = false}) async {
    var lead = _lead;
    var hang = _hang;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(firstTime ? '开启上课提醒' : '提醒设置',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          content: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('提前提醒时间',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ...[5, 10, 15, 20].map((m) {
                    final selected = lead == m;
                    return ChoiceChip(
                      label: Text('$m 分钟'),
                      selected: selected,
                      onSelected: (_) => setLocal(() => lead = m),
                      selectedColor: AppTheme.primaryColor,
                      labelStyle: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: selected ? Colors.white : const Color(0xFF374151),
                      ),
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                    );
                  }),
                  // v2.3.8：自定义任意分钟数（1~180）
                  ActionChip(
                    avatar: const Icon(Icons.edit_rounded, size: 14),
                    label: Text(
                      (lead != 5 && lead != 10 && lead != 15 && lead != 20)
                          ? '自定义 $lead 分钟'
                          : '自定义',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    onPressed: () async {
                      final v = await _askCustomLead(lead);
                      if (v != null) setLocal(() => lead = v);
                    },
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: hang,
                onChanged: (v) => setLocal(() => hang = v),
                title: const Text('倒计时',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                subtitle: Text(
                  hang ? '通知常驻，实时倒数到上课时刻' : '提醒只显示 5 秒后自动消失（默认）',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ),
            ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                await CourseReminderService.setLeadMinutes(lead);
                await CourseReminderService.setHangCountdown(hang);
                if (ctx.mounted) Navigator.of(ctx).pop(true);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
              ),
              child: Text(firstTime ? '开始提醒' : '保存'),
            ),
          ],
        ),
      ),
    );
  }

  /// 自定义提前分钟数输入（1~180），取消返回 null。
  Future<int?> _askCustomLead(int current) async {
    final ctl = TextEditingController(text: '$current');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义提前时间',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            suffixText: '分钟',
            hintText: '1 ~ 180',
            helperText: '上课前多少分钟提醒你',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              final n = int.tryParse(ctl.text.trim());
              if (n == null || n < 1 || n > 180) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请输入 1 ~ 180 之间的分钟数')));
                return;
              }
              Navigator.of(ctx).pop(n);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
              foregroundColor: Colors.white,
            ),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    ctl.dispose();
    return v;
  }

  Future<void> _openExactAlarm() async {
    final ok = await NotificationService.ensureExactAlarmPermission();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        duration: Duration(seconds: 4),
        content: Text('请在打开的页面中允许「闹钟和提醒」；部分手机在 应用信息→权限 里'),
      ));
    }
    await _refresh();
  }

  Future<void> _openAutoStart() async {
    // Android 无统一「自启动」API，跳应用信息页由用户开启（各厂商入口不同）
    await openAppSettings();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      duration: Duration(seconds: 5),
      content: Text('在应用信息里找到「自启动」并允许；再把省电策略设为「无限制」，提醒更可靠'),
    ));
    await _refresh();
  }

  Future<void> _sendTest() async {
    await CourseReminderService.fireTest();
    final queued = await NotificationService.pendingCount();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 6),
      content: Text(queued > 0
          ? '测试已排定：3 秒后到达（120 秒倒计时），可退出 App 验证。\n'
              '到达后看下方「实时胶囊」状态：已提升 = 系统已把它变成胶囊卡片'
          : '测试排定失败：请先完成上方三步引导'),
    ));
    // 3 秒后再刷一次诊断：此时通知已在通知栏，能读到是否被系统提升
    Future.delayed(const Duration(seconds: 6), () {
      if (mounted) _refresh();
    });
  }

  // ---------- UI ----------

  /// 引导步骤的状态点：完成=绿√，未完成=琥珀数字
  Widget _stepDot(bool done, int n) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done ? const Color(0xFF22C55E) : const Color(0xFFF59E0B).withOpacity(0.15),
      ),
      child: done
          ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
          : Center(
              child: Text('$n',
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFB45309))),
            ),
    );
  }

  Widget _guideTile({
    required int n,
    required bool done,
    required String title,
    required String hint,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            _stepDot(done, n),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(hint,
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                ],
              ),
            ),
            Text(done ? '已完成' : '去开启',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: done ? const Color(0xFF16A34A) : AppTheme.primaryColor)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded,
                size: 18, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppTheme.cardShadow,
      ),
      child: child,
    );
  }

  /// 「实时胶囊」诊断卡：把系统侧判定结果直接显示出来，避免"看不到变化"无从排查。
  Widget _capsuleCard() {
    final supported = _capsule['supported'] == true;
    final sdk = _capsule['sdkInt']?.toString() ?? '?';
    final perm = _capsule['promoPermission'];
    final canPost = _capsule['canPost'];
    final active = _capsule['activeCount']?.toString() ?? '-';
    final promoted = _capsule['promotedCount']?.toString() ?? '-';
    final lastTitle = _capsule['lastTitle']?.toString() ?? '（暂无活跃通知）';

    final bool? promotedOk =
        supported ? ((int.tryParse(promoted) ?? 0) > 0) : null;

    return _card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bolt_rounded, size: 18, color: Color(0xFF6C5CE7)),
                const SizedBox(width: 6),
                Text('实时胶囊（Android 16）',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade800)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: promotedOk == true
                        ? const Color(0xFF22C55E).withOpacity(0.15)
                        : const Color(0xFFF59E0B).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    !supported
                        ? '系统不支持'
                        : (promotedOk == true ? '已提升 ✓' : '未提升'),
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: !supported
                            ? Colors.grey.shade600
                            : (promotedOk == true
                                ? const Color(0xFF16A34A)
                                : const Color(0xFFB45309))),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _capsuleRow('系统版本', supported ? 'Android $sdk（支持）' : 'Android $sdk（需 16+）',
                ok: supported),
            _capsuleRow('权限声明', perm == true ? '已声明并授予' : '未授予，请重装应用',
                ok: perm == true),
            _capsuleRow(
                '系统允许',
                canPost == true
                    ? '允许发布提升通知'
                    : (canPost == false ? '已在系统设置中关闭' : '无法查询（系统 < 16）'),
                ok: canPost == null ? null : canPost == true),
            _capsuleRow(
                '通知与胶囊', '通知栏 $active 条 · 已变胶囊 $promoted 条',
                ok: promotedOk),
            const SizedBox(height: 2),
            Text(
              '说明：通知栏条数=本应用当前在通知栏的通知；已变胶囊=被系统显示为胶囊/流体云卡片的条数。'
              '测试提醒到达后会立即刷新。',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500, height: 1.4),
            ),
            const SizedBox(height: 4),
            Text('最近通知：$lastTitle',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () async {
                  await LiveUpdateService.openSettings();
                  Future.delayed(const Duration(milliseconds: 600), () {
                    if (mounted) _refresh();
                  });
                },
                child: const Text('打开系统实时更新设置', style: TextStyle(fontSize: 12.5)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 开启后的排程状态展示（v2.3.8）：让用户直观看到“到底排上了没有、下一条什么时候”。
  /// 整块可点击 → 再次打开设置弹窗（设置项本身已隐藏）。
  Widget _reminderStatusBlock() {
    final count = (_stats['count'] as num?)?.toInt() ?? 0;
    final nextAtIso = (_stats['nextAt'] ?? '').toString();
    final nextCourse = (_stats['nextCourse'] ?? '').toString();
    final savedAtIso = (_stats['savedAt'] ?? '').toString();
    DateTime? nextAt;
    DateTime? savedAt;
    if (nextAtIso.isNotEmpty) nextAt = DateTime.tryParse(nextAtIso);
    if (savedAtIso.isNotEmpty) savedAt = DateTime.tryParse(savedAtIso);

    String nextText;
    if (nextAt == null) {
      nextText = count == 0 ? '暂无排程（今天之后的课程都已过提醒时间）' : '—';
    } else {
      final now = DateTime.now();
      final sameDay = nextAt.year == now.year &&
          nextAt.month == now.month &&
          nextAt.day == now.day;
      final tomorrow = now.add(const Duration(days: 1));
      final isTomorrow = nextAt.year == tomorrow.year &&
          nextAt.month == tomorrow.month &&
          nextAt.day == tomorrow.day;
      final dayText = sameDay
          ? '今天'
          : (isTomorrow
              ? '明天'
              : '${nextAt.month}月${nextAt.day}日');
      final hh = nextAt.hour.toString().padLeft(2, '0');
      final mm = nextAt.minute.toString().padLeft(2, '0');
      nextText = '$dayText $hh:$mm · $nextCourse';
    }

    return InkWell(
      onTap: () async {
        final ok = await _showSetupDialog();
        if (ok == true && mounted) _refresh();
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12), // v1.7.1 统一页面边距：原 16
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Divider(height: 1),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  count > 0 ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                  size: 14,
                  color: count > 0 ? const Color(0xFF22C55E) : const Color(0xFFF59E0B),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '未来 7 天已排 $count 条提醒',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 20),
              child: Text('下一条：$nextText',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700)),
            ),
            if (savedAt != null) ...[
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.only(left: 20),
                child: Text(
                  '上次排程：${savedAt.month}/${savedAt.day} '
                  '${savedAt.hour.toString().padLeft(2, '0')}:${savedAt.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
              ),
            ],
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 20),
              child: Text('点此处可修改提前时间与倒计时',
                  style: TextStyle(fontSize: 11, color: AppTheme.primaryColor)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _capsuleRow(String label, String value, {bool? ok}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            ok == null
                ? Icons.remove_circle_outline
                : (ok ? Icons.check_circle_rounded : Icons.error_outline_rounded),
            size: 14,
            color: ok == null
                ? Colors.grey.shade400
                : (ok ? const Color(0xFF22C55E) : const Color(0xFFF59E0B)),
          ),
          const SizedBox(width: 6),
          Text('$label：', style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
          Expanded(
            child: Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12.5,
                    color: Colors.grey.shade800,
                    fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allOk = _notifOk && _exactOk;
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('上课提醒',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ---- 卡片1：课程提醒（v2.3.8：开启后隐藏设置项，改为展示排程状态）----
                _card(
                  child: Column(
                    children: [
                      SwitchListTile(
                        value: _enabled,
                        onChanged: _toggle,
                        secondary: const Icon(Icons.notifications_active_rounded,
                            color: Color(0xFF6C5CE7)),
                        title: const Text('课程提醒',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          _enabled
                              ? '提前 $_lead 分钟 · ${_hang ? '倒计时' : '提醒 5 秒后消失'}'
                              : '开启后按课表自动提醒',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                      if (_enabled) _reminderStatusBlock(),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // ---- 卡片2：权限与引导（v2.3.7 下移）----
                _card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.tips_and_updates_outlined,
                                size: 18, color: Color(0xFFF59E0B)),
                            const SizedBox(width: 6),
                            Text('让提醒 100% 到达，只需三步',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey.shade800)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        _guideTile(
                          n: 1,
                          done: _notifOk,
                          title: '允许通知权限',
                          hint: _notifOk ? '已允许，提醒可以弹出' : '系统拦截了全部通知，必须先开启',
                          onTap: () async {
                            await NotificationService.requestPermission();
                            final ok =
                                await NotificationService.notificationsEnabled();
                            if (!ok) await openAppSettings();
                            await _refresh();
                          },
                        ),
                        _guideTile(
                          n: 2,
                          done: _exactOk,
                          title: '开启「闹钟和提醒」精确闹钟',
                          hint: _exactOk ? '已开启，提醒准点不迟到' : '不开启提醒可能晚几分钟',
                          onTap: _openExactAlarm,
                        ),
                        _guideTile(
                          n: 3,
                          done: allOk,
                          title: '允许自启动 + 省电无限制',
                          hint: '小米/华为等手机会拦截提醒，开启后最可靠',
                          onTap: _openAutoStart,
                        ),
                        const SizedBox(height: 4),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // ---- 卡片3：实时胶囊诊断 ----
                _capsuleCard(),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '提醒按你的课表自动预排未来 7 天，课前到点自动弹出，无需保持 App 在后台；'
                    '修改课表或开学日期后会自动重新排程。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade500, height: 1.5),
                  ),
                ),
                const SizedBox(height: 16),
                // ---- 底部：测试按钮（v2.3.7 移至最下）----
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _enabled ? _sendTest : null,
                    icon: const Icon(Icons.alarm_rounded, size: 18),
                    label: const Text('发送测试提醒',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade300,
                      disabledForegroundColor: Colors.grey.shade600,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    _enabled
                        ? '测试提醒 3 秒后到达（120 秒倒计时），可退出 App 验证'
                        : '先开启课程提醒',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ),
              ],
            ),
    );
  }
}
