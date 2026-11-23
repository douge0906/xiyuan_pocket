import 'package:flutter/material.dart';

import '../../services/chaoxing/chaoxing_sync_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';

/// 学习通同步 —— 一个独立的服务项页面。
///
/// ## 边界（用户 2026-11-23 划定）
/// 「最多其具备同步功能影响外界，其余为其独立服务项功能。」
/// 本页只做三件事：绑定账密、看同步状态、手动同步一次。
/// 写出去的东西只有两处：**待办**（作业）和**考试安排**（考试）。
/// 不碰课表、成绩、一卡通、消息中心，也不注册后台任务。
///
/// ## 为什么把密码放在这里而不是复用统一认证
/// 学习通是另一套账号（手机号 + 独立密码），跟学校统一认证不是一回事；
/// 拿统一认证的账号密码去撞学习通既不对也登不上。
class ChaoxingSyncPage extends StatefulWidget {
  const ChaoxingSyncPage({super.key});

  @override
  State<ChaoxingSyncPage> createState() => _ChaoxingSyncPageState();
}

class _ChaoxingSyncPageState extends State<ChaoxingSyncPage> {
  final TextEditingController _accountCtl = TextEditingController();
  final TextEditingController _pwdCtl = TextEditingController();

  bool _loading = true;
  bool _busy = false;
  bool _bound = false;
  bool _enabled = true;
  String _account = '';
  DateTime? _lastSync;
  String _summary = '';
  String? _error;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _accountCtl.dispose();
    _pwdCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final bound = await ChaoxingSyncService.isBound();
    final acc = await ChaoxingSyncService.account();
    final enabled = await ChaoxingSyncService.enabled();
    final last = await ChaoxingSyncService.lastSyncAt();
    final summary = await ChaoxingSyncService.lastSummary();
    if (!mounted) return;
    setState(() {
      _bound = bound;
      // account() 存的是账号明文，未绑定时是空串；已绑定时用它回显。
      _account = acc;
      _accountCtl.text = acc;
      _enabled = enabled;
      _lastSync = last;
      _summary = summary;
      _loading = false;
    });
  }

  // ───────────────── 绑定 / 解绑 ─────────────────

  Future<void> _bind() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await ChaoxingSyncService.bind(_accountCtl.text, _pwdCtl.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!r.ok) {
      setState(() => _error = r.message);
      return;
    }
    _pwdCtl.clear();
    await _load();
    if (!mounted) return;
    _toast(r.message);
  }

  Future<void> _unbind() async {
    final ok = await _confirm(
      title: '解除绑定',
      body: '会清掉本机保存的学习通账号与会话。'
          '已经同步到待办和考试里的内容不会删除 —— 那是你自己的数据。',
      confirmText: '解除绑定',
      danger: true,
    );
    if (ok != true) return;
    await ChaoxingSyncService.unbind();
    if (!mounted) return;
    _pwdCtl.clear();
    await _load();
    if (!mounted) return;
    _toast('已解除绑定');
  }

  Future<void> _syncNow() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await ChaoxingSyncService.syncNow();
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.error != null) {
      setState(() => _error = r.error);
      _toast('同步失败：${r.error}');
      return;
    }
    await _load();
    if (!mounted) return;
    _toast(r.summary);
  }

  Future<void> _toggleEnabled(bool value) async {
    setState(() => _enabled = value);
    await ChaoxingSyncService.setEnabled(value);
  }

  // ───────────────── 反馈 ─────────────────

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 3),
      ));
  }

  /// 居中二次确认弹窗（R8：右上角必须有 ×、纯白底 + 1px 细边框 + 20 圆角）。
  Future<bool?> _confirm({
    required String title,
    required String body,
    required String confirmText,
    bool danger = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          side: BorderSide(color: ctx.borderColor),
        ),
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 8, 0),
        title: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: AppTheme.fontHeading,
                  fontWeight: FontWeight.w600,
                  color: ctx.textPrimary,
                ),
              ),
            ),
            IconButton(
              tooltip: '关闭',
              icon: Icon(Icons.close_rounded, size: 20, color: ctx.textTertiary),
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
          ],
        ),
        contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
        content: Text(
          body,
          style: TextStyle(
            fontSize: AppTheme.fontBody,
            height: 1.5,
            color: ctx.textSecondary,
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(12, 4, 16, 10),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消',
                style: TextStyle(
                    fontSize: AppTheme.fontBody, color: ctx.textSecondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor:
                  danger ? ctx.dangerColor : AppTheme.primaryColor,
              minimumSize: const Size(0, 40),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              ),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmText,
                style: const TextStyle(
                    fontSize: AppTheme.fontBody, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ───────────────── 构建 ─────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text(
          '学习通同步',
          style: TextStyle(
            fontSize: AppTheme.fontHeading,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _introCard(),
                const SizedBox(height: 12),
                if (_bound) ..._boundSection() else ..._bindSection(),
              ],
            ),
    );
  }

  /// 顶部说明：一次说清「它到底会动哪些东西」。
  Widget _introCard() {
    return AppCard(
      radius: AppTheme.radiusLg,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.sync_rounded, size: 18, color: context.textTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '把学习通里「还没交的作业」同步成待办，把「考试」同步到考试安排。'
              '只写入这两处，不动课表、成绩和一卡通。',
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                height: 1.5,
                color: context.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────── 未绑定：账号密码表单 ─────────────────

  List<Widget> _bindSection() {
    return [
      AppCard(
        radius: AppTheme.radiusLg,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '绑定学习通账号',
              style: TextStyle(
                fontSize: AppTheme.fontTitle,
                fontWeight: FontWeight.w600,
                color: context.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '用手机号 + 学习通密码登录。密码只在本机加密保存，不上传任何服务器。',
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                height: 1.45,
                color: context.textTertiary,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _accountCtl,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                hintText: '学习通账号（手机号）',
                isDense: true,
                prefixIcon: const Icon(Icons.person_outline_rounded, size: 18),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd)),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _pwdCtl,
              obscureText: _obscure,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _bind(),
              decoration: InputDecoration(
                hintText: '学习通密码',
                isDense: true,
                prefixIcon: const Icon(Icons.lock_outline_rounded, size: 18),
                suffixIcon: IconButton(
                  tooltip: _obscure ? '显示密码' : '隐藏密码',
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd)),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              _errorBox(_error!),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  minimumSize: const Size(0, 44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                ),
                onPressed: _busy ? null : _bind,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(Colors.white),
                        ),
                      )
                    : const Text(
                        '登录并同步',
                        style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _noticeCard(),
    ];
  }

  /// 「可能登不上」的三种情况先说清楚，省得用户以为是 App 坏了。
  Widget _noticeCard() {
    return AppCard(
      radius: AppTheme.radiusLg,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline_rounded,
                  size: 16, color: context.warningColor),
              const SizedBox(width: 6),
              Text(
                '可能遇到',
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  fontWeight: FontWeight.w600,
                  color: context.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _bullet('学习通要求人机验证 / 短信二次验证时，先用手机 App 登录一次学习通，再回来绑定。'),
          _bullet('连着输错密码会被临时锁定，等一会儿再试，别反复点。'),
          _bullet('这功能依赖学习通的私有接口，哪天它改版了可能同步不到，届时请反馈。'),
        ],
      ),
    );
  }

  Widget _bullet(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5, right: 6),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: context.textTertiary,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                height: 1.45,
                color: context.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBox(String msg) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.dangerColor.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: context.dangerColor.withValues(alpha: .35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded,
              size: 16, color: context.dangerColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              msg,
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                height: 1.4,
                color: context.dangerColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────── 已绑定：状态 + 操作 ─────────────────

  List<Widget> _boundSection() {
    return [
      AppCard(
        radius: AppTheme.radiusLg,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: context.iconTintBg,
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  ),
                  child: Icon(Icons.account_circle_outlined,
                      size: 20, color: context.textSecondary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _account.isEmpty ? '已绑定学习通' : _account,
                        style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _lastSync == null
                            ? '还没有同步过'
                            : '上次同步 ${_fmtDateTime(_lastSync!)}',
                        style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          color: context.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_summary.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                _summary,
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  height: 1.45,
                  color: context.textSecondary,
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              _errorBox(_error!),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  minimumSize: const Size(0, 44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                ),
                onPressed: _busy ? null : _syncNow,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(Colors.white),
                        ),
                      )
                    : const Icon(Icons.refresh_rounded, size: 18),
                label: Text(
                  _busy ? '正在同步…' : '立即同步',
                  style: const TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      AppCard(
        radius: AppTheme.radiusLg,
        padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
        child: Column(
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              onChanged: _toggleEnabled,
              title: Text(
                '自动同步',
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  fontWeight: FontWeight.w500,
                  color: context.textPrimary,
                ),
              ),
              subtitle: Text(
                '打开 App 时顺手检查一次（相隔 6 小时以上才会真的联网）',
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  color: context.textTertiary,
                ),
              ),
            ),
            Divider(height: 1, color: context.borderColor),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '解除绑定',
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  fontWeight: FontWeight.w500,
                  color: context.dangerColor,
                ),
              ),
              subtitle: Text(
                '只清本机凭证，已同步的待办与考试保留',
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  color: context.textTertiary,
                ),
              ),
              trailing: Icon(Icons.chevron_right_rounded,
                  size: 20, color: context.textTertiary),
              onTap: _unbind,
            ),
          ],
        ),
      ),
    ];
  }

  String _fmtDateTime(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay =
        d.year == now.year && d.month == now.month && d.day == now.day;
    if (sameDay) return '今天 ${two(d.hour)}:${two(d.minute)}';
    return '${d.month}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
