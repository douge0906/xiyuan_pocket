import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/campus/cprint_client.dart';
import '../../services/campus/cprint_models.dart';
import '../../services/campus/cprint_scan_downloader.dart';
import '../../services/campus/cprint_scan_storage.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';
import '../../widgets/empty_state_art.dart';
import '../../widgets/state_views.dart';
import 'cprint_scan_actions.dart';
import 'cprint_shared.dart';
import 'cprint_scan_detail_page.dart';
import 'resource_viewer_page.dart';

/// 云打印 · 「扫描文档」页签（打印店代扫的文件）。
///
/// 业务逻辑与原来的独立页面一致，只把外壳换成页签：
/// 去掉 Scaffold / AppBar，登录状态由外层 [CprintPage] 统一管理。
///
/// 设计稿（`docs/design/cprint_scan_design.md` §6/§7）给了完整的 chips、
/// 多选、批量下载、排序按钮。落地时按真实使用场景砍掉了三样：
///
/// * **类型 chips（全部/PDF/图片/文档/已过期）** —— 一个人一个月也就几张
///   扫描件，分类的成本高于收益，还占掉一整行。
/// * **多选 + 批量下载** —— App 里没有「批量保存到相册」的出路，选 5 个
///   就是弹 5 次系统分享面板，体验比一个个点更差。
/// * **排序按钮** —— 站点默认就是按提交时间倒序，没有第二个合理排序。
///
/// 保留的是真正需要的：**列表、类型图标、下载、分享、删除、过期态**。
class CprintScanTab extends StatefulWidget {
  const CprintScanTab({
    super.key,
    required this.authed,
    required this.onNeedAuth,
  });

  /// 外层是否已登录成功。false 时本页只显示登录引导，不发请求。
  final bool authed;

  /// 会话过期时通知外层重新走授权。
  final VoidCallback onNeedAuth;

  @override
  State<CprintScanTab> createState() => _CprintScanTabState();
}

enum _LoadState { loading, ready, needsAuth, error }

class _CprintScanTabState extends State<CprintScanTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  _LoadState _state = _LoadState.loading;
  String _error = '';
  List<CprintScanItem> _items = const [];
  Map<String, CprintLocalFile> _local = const {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.authed) {
      unawaited(_loadList());
    } else {
      _state = _LoadState.needsAuth;
    }
  }

  @override
  void didUpdateWidget(covariant CprintScanTab old) {
    super.didUpdateWidget(old);
    // 外层刚登录成功：立刻拉一次，不用等用户手动下拉。
    if (widget.authed && !old.authed) {
      unawaited(_loadList());
    }
  }

  Future<void> _loadList() async {
    final r = await CprintClient.list();
    if (!mounted) return;
    if (!r.ok) {
      setState(() {
        _state = r.needReauth ? _LoadState.needsAuth : _LoadState.error;
        _error = r.message.isEmpty ? '读取扫描件列表失败' : r.message;
      });
      return;
    }
    final local = await CprintScanStorage.byJobId();
    if (!mounted) return;
    setState(() {
      _items = r.items;
      _local = local;
      _state = _LoadState.ready;
      _error = '';
    });
  }

  Future<void> _retry() async {
    if (_state == _LoadState.needsAuth) {
      widget.onNeedAuth();
      return;
    }
    await _loadList();
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

  // ───────────────────────────── 下载 / 分享 / 删除

  Future<void> _download(CprintScanItem item, {bool openAfter = false}) async {
    if (_busy) return;
    if (item.isExpired) {
      _toast('该文件已过期，不可下载');
      return;
    }
    setState(() => _busy = true);
    try {
      final path = await downloadCprintWithProgress(context, item);
      if (!mounted) return;
      if (path == null) return;
      final local = await CprintScanStorage.byJobId();
      if (!mounted) return;
      setState(() => _local = local);
      if (openAfter) {
        await _open(item, path);
      } else {
        _toast('已保存到本机');
      }
    } on CprintDownloadFailure catch (e) {
      if (!mounted) return;
      _toast(e.message);
      if (e.needReauth) {
        setState(() => _state = _LoadState.needsAuth);
      }
    } catch (e) {
      if (!mounted) return;
      _toast('下载失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 「打开」：PDF 走 App 内的阅读器，图片走图片预览，其它走系统分享。
  Future<void> _open(CprintScanItem item, String path) async {
    final type = item.docType.classType;
    if (type == 'pdf') {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ResourceViewerPage(title: item.displayName, filePath: path),
      ));
      return;
    }
    if (type == 'img') {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _CprintImagePage(title: item.displayName, filePath: path),
      ));
      return;
    }
    await _share(item, path);
  }

  Future<void> _share(CprintScanItem item, [String? path]) async {
    final p = path ?? _local[item.jobId]?.path;
    if (p == null) {
      // 还没下载就先下，下完再弹分享面板 —— 用户点的是「分享」，
      // 不该被要求先点一次「下载」。
      await _download(item);
      if (!mounted) return;
      final again = _local[item.jobId]?.path;
      if (again == null) return;
      await Share.shareXFiles([XFile(again)], text: item.displayName);
      return;
    }
    final f = File(p);
    if (!await f.exists()) {
      if (!mounted) return;
      _toast('本机文件不在了，请重新下载');
      return;
    }
    await Share.shareXFiles([XFile(p)], text: item.displayName);
  }

  Future<void> _deleteRemote(CprintScanItem item) async {
    final ok = await _confirm(
      title: '删除这份扫描件？',
      body: '会从图书馆云打印的账号里删掉，删了就找不回来。本机已下载的文件不受影响。',
      confirmText: '删除',
      danger: true,
    );
    if (ok != true) return;
    final r = await CprintClient.delete(item.jobId);
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.message.isEmpty ? '删除失败，请稍后重试' : r.message);
      return;
    }
    await CprintScanStorage.remove(item.jobId);
    _toast('已删除');
    await _loadList();
  }

  Future<void> _deleteLocal(CprintScanItem item) async {
    await CprintScanStorage.remove(item.jobId);
    final local = await CprintScanStorage.byJobId();
    if (!mounted) return;
    setState(() => _local = local);
    _toast('已删除本机文件');
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
              icon: Icon(Icons.close_rounded,
                  size: 20, color: ctx.textTertiary),
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
          ],
        ),
        content: Text(
          body,
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
            style: danger
                ? FilledButton.styleFrom(backgroundColor: ctx.dangerColor)
                : null,
            child: Text(confirmText),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────── 渲染

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!widget.authed) {
      return CprintNeedAuthView(
        message: _error.isEmpty ? '登录后才能看到自己的扫描件。' : _error,
        onLogin: () async => widget.onNeedAuth(),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadList,
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case _LoadState.loading:
        return const Center(child: CircularProgressIndicator());
      case _LoadState.needsAuth:
        return CprintNeedAuthView(
          message: _error.isEmpty ? '登录后才能看到自己的扫描件。' : _error,
          onLogin: () async => widget.onNeedAuth(),
        );
      case _LoadState.error:
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: 420,
              child: ErrorState(
                message: _error.isEmpty ? '读取扫描件列表失败' : _error,
                onRetry: _retry,
              ),
            ),
          ],
        );
      case _LoadState.ready:
        if (_items.isEmpty) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: const [
              SizedBox(
                height: 440,
                child: EmptyState(
                  message: '暂无扫描件',
                  hint: '打印店代扫上传的文件会出现在这里',
                  icon: Icons.document_scanner_outlined,
                  artVariant: EmptyArtVariant.box,
                ),
              ),
            ],
          );
        }
        return ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          itemCount: _items.length + 1,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, i) {
            if (i == 0) return _header();
            return _card(_items[i - 1]);
          },
        );
    }
  }

  Widget _header() {
    final expireCount = _items.where((e) => e.isExpired).length;
    final sub = [
      '共 ${_items.length} 份',
      if (expireCount > 0) '$expireCount 份已过期',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        sub,
        style: TextStyle(
          fontSize: AppTheme.fontSmall,
          color: context.textTertiary,
        ),
      ),
    );
  }

  Widget _card(CprintScanItem item) {
    final local = _local[item.jobId];
    final expired = item.isExpired;
    final dim = expired ? context.textTertiary : context.textPrimary;
    return AppCard(
      radius: AppTheme.radiusMd,
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => CprintScanDetailPage(
              item: item,
              localPath: local?.path,
              onDownload: () => _download(item),
              onShare: () => _share(item, local?.path),
              onDeleteLocal: () => _deleteLocal(item),
              onDeleteRemote: () => _deleteRemote(item),
            ),
          )).then((_) => _loadList());
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
          child: Row(
            children: [
              cprintTypeIcon(item.docType, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.displayName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              fontWeight: FontWeight.w500,
                              color: dim,
                            ),
                          ),
                        ),
                        if (expired) ...[
                          const SizedBox(width: 6),
                          cprintPill('已过期', context.warningColor),
                        ],
                        if (local != null) ...[
                          const SizedBox(width: 6),
                          cprintPill('已下载', context.successColor),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${_fmtDate(item)} · ${item.sizeLabel}',
                      style: TextStyle(
                        fontSize: AppTheme.fontSmall,
                        color: context.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              if (expired)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(Icons.block_rounded,
                      size: 18, color: context.textTertiary),
                )
              else
                PopupMenuButton<int>(
                  tooltip: '更多',
                  icon: Icon(Icons.more_horiz_rounded,
                      size: 20, color: context.textTertiary),
                  onSelected: (v) {
                    if (v == 0) unawaited(_download(item, openAfter: true));
                    if (v == 1) unawaited(_share(item, local?.path));
                    if (v == 2) unawaited(_deleteRemote(item));
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 0,
                      child: Row(children: [
                        Icon(Icons.file_download_outlined, size: 18),
                        SizedBox(width: 8),
                        Text('下载并打开', style: TextStyle(fontSize: 14)),
                      ]),
                    ),
                    const PopupMenuItem(
                      value: 1,
                      child: Row(children: [
                        Icon(Icons.ios_share_rounded, size: 18),
                        SizedBox(width: 8),
                        Text('分享', style: TextStyle(fontSize: 14)),
                      ]),
                    ),
                    PopupMenuItem(
                      value: 2,
                      child: Row(children: [
                        Icon(Icons.delete_outline_rounded,
                            size: 18, color: context.dangerColor),
                        const SizedBox(width: 8),
                        Text('从账号删除',
                            style: TextStyle(
                                fontSize: 14, color: context.dangerColor)),
                      ]),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmtDate(CprintScanItem item) {
    final at = item.submittedAt;
    if (at == null) return '时间未知';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
  }


}

/// 扫描件图片预览（PDF 走 ResourceViewerPage）。
class _CprintImagePage extends StatelessWidget {
  const _CprintImagePage({required this.title, required this.filePath});

  final String title;
  final String filePath;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 5,
          child: Center(child: Image.file(File(filePath))),
        ),
      ),
    );
  }
}
