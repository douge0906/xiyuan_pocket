import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../services/campus/cprint_client.dart';
import '../../services/campus/cprint_models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';
import '../../widgets/state_views.dart';
import 'cprint_shared.dart';

/// 云打印 · 「打印文档」页签（已上传、还没在打印机上打的文件）。
///
/// 对应网页版 `printDoc.html`。网页版那一页有多选、全选、批量删除，
/// 手机上一次只会处理一两个文件，这些批量交互全部去掉，改成每行一个菜单。
class CprintJobsTab extends StatefulWidget {
  const CprintJobsTab({
    super.key,
    required this.authed,
    required this.onNeedAuth,
    this.refreshTick = 0,
  });

  /// 外层是否已经登录成功。false 时本页只显示登录引导，不发请求。
  final bool authed;

  /// 会话过期时通知外层重新走授权。
  final VoidCallback onNeedAuth;

  /// 父层每加一次就要求重拉一次列表。
  ///
  /// 这一页是 `AutomaticKeepAlive` 的：切走再切回来不会重建，`initState` 里的
  /// `_load()` 也不会再跑。而「刚上传完一个文件就跳过来」恰恰是必须重拉的场景，
  /// 否则用户看到的还是上传之前的旧列表（新文件像没传上去一样）。
  final int refreshTick;

  @override
  State<CprintJobsTab> createState() => _CprintJobsTabState();
}

class _CprintJobsTabState extends State<CprintJobsTab>
    with AutomaticKeepAliveClientMixin {
  List<CprintPrintJob> _jobs = const [];
  bool _loading = true;
  String? _error;
  bool _busy = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (widget.authed) {
      _load();
    } else {
      _loading = false;
    }
  }

  @override
  void didUpdateWidget(covariant CprintJobsTab old) {
    super.didUpdateWidget(old);
    if (widget.authed && !old.authed) {
      _load();
      return;
    }
    if (widget.authed && widget.refreshTick != old.refreshTick) {
      _load();
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = _jobs.isEmpty;
      _error = null;
    });
    final r = await CprintClient.printJobs();
    if (!mounted) return;
    if (r.needReauth) {
      setState(() {
        _loading = false;
        _error = null;
      });
      widget.onNeedAuth();
      return;
    }
    setState(() {
      _loading = false;
      if (r.ok) {
        _jobs = r.jobs;
        _error = null;
      } else {
        _error = r.message.isEmpty ? '读不到打印任务，请稍后重试。' : r.message;
      }
    });
  }

  Future<void> _delete(CprintPrintJob job) async {
    if (_busy) return;
    final ok = await showDialog<bool>(
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
                '从云打印删除',
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
        content: Text(
          '「${job.displayName}」会从这个账号里删掉，删了要重新上传。',
          style: TextStyle(
            fontSize: AppTheme.fontBody,
            height: 1.55,
            color: ctx.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消',
                style: TextStyle(color: ctx.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: ctx.dangerColor),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final r = await CprintClient.deletePrintJob(job.jobId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.ok) {
        _jobs = _jobs.where((e) => e.jobId != job.jobId).toList(growable: false);
      }
    });
    if (!r.ok) {
      _toast(r.message.isEmpty ? '删除失败，请稍后重试。' : r.message);
    } else {
      _toast('已删除');
    }
  }

  Future<void> _preview(CprintPrintJob job) async {
    if (_busy) return;
    setState(() => _busy = true);
    late final Uint8List? bytes;
    try {
      bytes = await CprintClient.previewPage(
        jobId: job.jobId,
        createTime: job.rawCreateTime,
      );
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      _toast('打不开预览，请稍后再试。');
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (bytes == null || bytes.isEmpty) {
      _toast('这份文件没有预览图，请直接去打印机上看。');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 4,
                child: Image.memory(bytes!, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                tooltip: '关闭',
                icon: const Icon(Icons.close_rounded,
                    size: 22, color: Colors.white),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
          ],
        ),
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!widget.authed) {
      return CprintNeedAuthView(
        message: '登录后才能看到自己的打印任务。',
        onLogin: () async => widget.onNeedAuth(),
      );
    }
    if (_loading) return cprintLoading();
    return RefreshIndicator(
      onRefresh: _load,
      child: _error != null
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(
                  height: 380,
                  child: ErrorState(message: _error!, onRetry: _load),
                ),
              ],
            )
          : _jobs.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    SizedBox(
                      height: 380,
                      child: EmptyState(
                        message: '没有待打印的文件',
                        hint: '在「云打印」里上传的文件会出现在这里，打完就自动消失。',
                        icon: Icons.print_outlined,
                      ),
                    ),
                  ],
                )
              : ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: _jobs.length + 1,
                  separatorBuilder: (_, i) =>
                      SizedBox(height: i == 0 ? 10 : 8),
                  itemBuilder: (_, i) {
                    if (i == 0) {
                      return cprintHint(
                        context,
                        '这些文件已经传到云打印，到打印机旁的终端刷卡就能打。'
                        '打完会自动从这里消失。',
                      );
                    }
                    return _jobCard(_jobs[i - 1]);
                  },
                ),
    );
  }

  Widget _jobCard(CprintPrintJob job) {
    return AppCard(
      radius: AppTheme.radiusMd,
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          cprintTypeIcon(job.docType, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  job.displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w500,
                    color: context.textPrimary,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${job.submittedAtLabel} · ${job.sizeLabel}',
                  style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    color: context.textTertiary,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (job.paperLabel.isNotEmpty)
                      cprintPill(job.paperLabel, context.textSecondary),
                    cprintPill(job.colorLabel, context.textSecondary),
                    cprintPill(job.duplexLabel, context.textSecondary),
                    if (job.fee > 0)
                      cprintPill(
                        '${(job.fee / 100).toStringAsFixed(2)} 元',
                        context.textSecondary,
                      ),
                  ],
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: Icon(Icons.more_horiz_rounded, color: context.textTertiary),
            onSelected: (v) {
              if (v == 'preview') _preview(job);
              if (v == 'delete') _delete(job);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'preview', child: Text('预览第一页')),
              PopupMenuItem(value: 'delete', child: Text('从云打印删除')),
            ],
          ),
        ],
      ),
    );
  }
}
