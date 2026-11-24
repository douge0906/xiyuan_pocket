import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/chaoxing/chaoxing_sync_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';

/// 学习通同步。
///
/// 布局取舍（2026-11-24 用户反馈「重构布局减少用户登录占比、极力去除小字
/// 提示、只保留关键信息、加入作业/考试两个列表」）：
///
/// * **没绑定时整页只有一张卡**：两行输入 + 一个按钮。原来的「可能遇到」
///   三条 bullet 收进右下角一个「登录不上？」入口，用户不点就看不见。
/// * **绑定后页面主体是两个列表**（作业 / 考试），状态与操作收成一条顶栏，
///   「自动同步」「解除绑定」进右上角菜单 —— 设置项不该占首屏。
/// * 列表数据来自本地缓存（`works()`/`exams()`），进页面立刻有内容；
///   同步成功后再刷新一次。**不为了「有数据」去等网络**。
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
  bool _obscure = true;
  bool _showHints = false;
  String _account = '';
  String _summary = '';
  String? _error;
  DateTime? _lastSync;

  List<CxTaskRow> _works = const [];
  List<CxTaskRow> _exams = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _accountCtl.dispose();
    _pwdCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final bound = await ChaoxingSyncService.isBound();
    final account = await ChaoxingSyncService.account();
    final enabled = await ChaoxingSyncService.enabled();
    final last = await ChaoxingSyncService.lastSyncAt();
    final summary = await ChaoxingSyncService.lastSummary();
    final works = await ChaoxingSyncService.works();
    final exams = await ChaoxingSyncService.exams();
    if (!mounted) return;
    setState(() {
      _bound = bound;
      _account = account;
      _enabled = enabled;
      _lastSync = last;
      _summary = summary;
      _works = works;
      _exams = exams;
      _loading = false;
    });
  }

  Future<void> _bind() async {
    final account = _accountCtl.text.trim();
    final password = _pwdCtl.text;
    if (account.isEmpty || password.isEmpty) {
      setState(() => _error = '账号和密码都要填');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ChaoxingSyncService.bind(account, password);
      if (!mounted) return;
      if (!r.ok) {
        setState(() => _error = r.message);
        return;
      }
      _pwdCtl.clear();
      await _load();
      if (!mounted) return;
      _toast(r.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ChaoxingSyncService.syncNow();
      if (!mounted) return;
      if (r.error != null) {
        setState(() => _error = r.error);
        _toast('同步失败：${r.error}');
        return;
      }
      await _load();
      if (!mounted) return;
      _toast(r.summary);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unbind() async {
    final ok = await _confirm(
      title: '解除绑定',
      body: '只清除本机的学习通登录凭证。已经同步到待办和考试里的内容会保留。',
      confirmText: '解除',
      danger: true,
    );
    if (ok != true) return;
    await ChaoxingSyncService.unbind();
    if (!mounted) return;
    _accountCtl.clear();
    _pwdCtl.clear();
    await _load();
    if (!mounted) return;
    _toast('已解除绑定');
  }

  Future<void> _toggleEnabled(bool v) async {
    setState(() => _enabled = v);
    await ChaoxingSyncService.setEnabled(v);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ));
  }

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
              backgroundColor: danger ? ctx.dangerColor : AppTheme.primaryColor,
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
        actions: [
          if (_bound)
            IconButton(
              tooltip: '立即同步',
              onPressed: _busy ? null : _syncNow,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 20),
            ),
          if (_bound)
            PopupMenuButton<int>(
              tooltip: '更多',
              icon: const Icon(Icons.more_vert_rounded, size: 20),
              onSelected: (v) {
                if (v == 0) _toggleEnabled(!_enabled);
                if (v == 1) unawaited(_unbind());
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 0,
                  child: Row(
                    children: [
                      Icon(
                        _enabled
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded,
                        size: 18,
                        color: context.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      const Text('自动同步', style: TextStyle(fontSize: 14)),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 1,
                  child: Row(
                    children: [
                      Icon(Icons.link_off_rounded,
                          size: 18, color: context.dangerColor),
                      const SizedBox(width: 8),
                      Text('解除绑定',
                          style: TextStyle(
                              fontSize: 14, color: context.dangerColor)),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_bound ? _buildBound() : _buildBind()),
    );
  }

  // ───────────────── 未绑定：一行说明 + 两行输入 ─────────────────

  Widget _buildBind() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [
        AppCard(
          radius: AppTheme.radiusLg,
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.sync_rounded,
                      size: 18, color: AppTheme.primaryColor),
                  const SizedBox(width: 8),
                  Text(
                    '绑定学习通账号',
                    style: TextStyle(
                      fontSize: AppTheme.fontTitle,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() => _showHints = !_showHints),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      _showHints ? '收起' : '登录不上？',
                      style: TextStyle(
                        fontSize: AppTheme.fontSmall,
                        color: context.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
              if (_showHints) ...[
                const SizedBox(height: 8),
                _hint('要人机验证或短信验证时，先用手机 App 登录一次学习通再回来。'),
                _hint('连着输错密码会被临时锁定，等一会儿再试。'),
                _hint('依赖学习通私有接口，它改版后可能同步不到。'),
              ],
              const SizedBox(height: 14),
              TextField(
                controller: _accountCtl,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  hintText: '学习通账号（手机号）',
                  isDense: true,
                  prefixIcon:
                      const Icon(Icons.person_outline_rounded, size: 18),
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
            ],
          ),
        ),
      ],
    );
  }

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: AppTheme.fontSmall,
            height: 1.4,
            color: context.textTertiary,
          ),
        ),
      );

  // ───────────────── 已绑定：顶栏 + 两个列表 ─────────────────

  Widget _buildBound() {
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Icon(Icons.account_circle_outlined,
              size: 18, color: context.textSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _account.isEmpty ? '已绑定学习通' : _account,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w500,
                color: context.textPrimary,
              ),
            ),
          ),
          if (_lastSync != null)
            Text(
              _fmtDateTime(_lastSync!),
              style: TextStyle(
                fontSize: AppTheme.fontCaption,
                color: context.textTertiary,
              ),
            ),
        ],
      ),
    );

    final errLine = _error == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _errorBox(_error!),
          );

    final summaryLine = _summary.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _summary,
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                color: context.textSecondary,
              ),
            ),
          );

    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          errLine,
          summaryLine,
          TabBar(
            labelColor: AppTheme.primaryColor,
            unselectedLabelColor: context.textTertiary,
            indicatorColor: AppTheme.primaryColor,
            indicatorSize: TabBarIndicatorSize.label,
            labelStyle: const TextStyle(
                fontSize: AppTheme.fontBody, fontWeight: FontWeight.w600),
            unselectedLabelStyle:
                const TextStyle(fontSize: AppTheme.fontBody),
            tabs: [
              Tab(text: '作业 ${_works.length}'),
              Tab(text: '考试 ${_exams.length}'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _taskList(_works, empty: '没有待处理的作业'),
                _taskList(_exams, empty: '没有考试'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _taskList(List<CxTaskRow> rows, {required String empty}) {
    if (rows.isEmpty) {
      return Center(
        child: Text(
          empty,
          style: TextStyle(
            fontSize: AppTheme.fontBody,
            color: context.textTertiary,
          ),
        ),
      );
    }
    final sorted = [...rows]..sort((a, b) {
      final r = a.sortRank.compareTo(b.sortRank);
      if (r != 0) return r;
      final ad = a.deadline, bd = b.deadline;
      if (ad == null && bd == null) return 0;
      if (ad == null) return 1;
      if (bd == null) return -1;
      return ad.compareTo(bd);
    });
    return RefreshIndicator(
      onRefresh: _syncNow,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: sorted.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _taskRow(sorted[i]),
      ),
    );
  }

  Widget _taskRow(CxTaskRow row) {
    final overdue = row.isOverdue || row.status == ChaoxingSyncService.cxOverdue;
    final done = row.isGraded || row.isSubmitted;
    final statusColor = overdue
        ? context.dangerColor
        : (done ? context.textTertiary : AppTheme.primaryColor);

    final meta = <String>[
      if (row.courseName.trim().isNotEmpty) row.courseName.trim(),
      if (row.deadline != null) _fmtDate(row.deadline!),
    ];

    return AppCard(
      radius: AppTheme.radiusMd,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    height: 1.3,
                    fontWeight: FontWeight.w500,
                    color: done || overdue
                        ? context.textSecondary
                        : context.textPrimary,
                  ),
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    meta.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: context.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            row.statusLabel,
            style: TextStyle(
              fontSize: AppTheme.fontCaption,
              fontWeight: FontWeight.w500,
              color: statusColor,
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

  String _fmtDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(d.year, d.month, d.day);
    final diff = that.difference(today).inDays;
    if (diff == 0) return '今天截止';
    if (diff == 1) return '明天截止';
    if (diff < 0) return '${d.month}-${two(d.day)} 已截止';
    return '${d.month}-${two(d.day)} 截止';
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
