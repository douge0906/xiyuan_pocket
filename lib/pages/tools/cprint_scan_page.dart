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
import 'cprint_scan_detail_page.dart';
import 'resource_viewer_page.dart';

/// 图书馆云打印「扫描件」。
///
/// ## 为什么页面长这样
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
/// 设计稿里「保留 30 天」那句是示意文案（接口不返回该字段），已按
/// §6 的警告改成「过期文件不可下载」。
class CprintScanPage extends StatefulWidget {
  const CprintScanPage({super.key});

  @override
  State<CprintScanPage> createState() => _CprintScanPageState();
}

enum _LoadState { loading, ready, needsAuth, error }

class _CprintScanPageState extends State<CprintScanPage> {
  _LoadState _state = _LoadState.loading;
  String _error = '';
  List<CprintScanItem> _items = const [];
  Map<String, CprintLocalFile> _local = const {};
  String _trueName = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    setState(() {
      _state = _LoadState.loading;
      _error = '';
    });
    final auth = await CprintClient.authorize();
    if (!mounted) return;
    if (!auth.ok) {
      setState(() {
        _state = _LoadState.needsAuth;
        _error = auth.message;
      });
      return;
    }
    _trueName = auth.trueName ?? CprintClient.trueName ?? '';
    await _loadList();
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
      final auth = await CprintClient.authorize(force: true);
      if (!mounted) return;
      if (!auth.ok) {
        _toast(auth.message);
        return;
      }
      _trueName = auth.trueName ?? _trueName;
    }
    await _loadList();
  }

  /// 需要用户输密码（本机没存密码）时，弹一次输入框。
  Future<bool> _askPassword() async {
    final ctl = TextEditingController();
    final pwd = await showDialog<String>(
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
                '再输一次统一认证密码',
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
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'App 里没有保存密码（「我的 → 登录」里的「记住密码」没开）。'
              '这一次需要手动输入，之后 40 分钟内不用再输。',
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                height: 1.5,
                color: ctx.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: '统一认证密码',
                isDense: true,
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消',
                style: TextStyle(color: ctx.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctl.text),
            child: const Text('授权'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (pwd == null || pwd.isEmpty) return false;
    final auth = await CprintClient.authorize(password: pwd, force: true);
    if (!mounted) return false;
    if (!auth.ok) {
      _toast(auth.message);
      return false;
    }
    _trueName = auth.trueName ?? _trueName;
    return true;
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
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text(
          '云打印扫描件',
          style: TextStyle(
            fontSize: AppTheme.fontHeading,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _state == _LoadState.loading ? null : _loadList,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadList,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case _LoadState.loading:
        return const Center(child: CircularProgressIndicator());
      case _LoadState.needsAuth:
        return _authView();
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
      if (_trueName.isNotEmpty) _trueName,
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
              _typeIcon(item.docType),
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
                          _pill('已过期', context.warningColor),
                        ],
                        if (local != null) ...[
                          const SizedBox(width: 6),
                          _pill('已下载', context.successColor),
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

  Widget _typeIcon(CprintDocType type) {
    final (icon, color) = switch (type.classType) {
      'pdf' => (Icons.picture_as_pdf_rounded, const Color(0xFFDC2626)),
      'img' => (Icons.image_rounded, const Color(0xFF059669)),
      'word' => (Icons.description_rounded, const Color(0xFF2563EB)),
      'excel' => (Icons.table_chart_rounded, const Color(0xFF15803D)),
      'ppt' => (Icons.slideshow_rounded, const Color(0xFFEA580C)),
      'txt' => (Icons.article_rounded, const Color(0xFF6B7280)),
      _ => (Icons.insert_drive_file_rounded, const Color(0xFF6B7280)),
    };
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Icon(icon, size: 21, color: color),
    );
  }

  Widget _pill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppTheme.fontCaption,
          height: 1.2,
          color: color,
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

  Widget _authView() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 40, 16, 24),
      children: [
        AppCard(
          radius: AppTheme.radiusLg,
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lock_outline_rounded,
                      size: 18, color: AppTheme.primaryColor),
                  const SizedBox(width: 8),
                  Text(
                    // 不叫「需要授权」—— 用户不知道要授权给谁、为什么。
                    // 这一屏唯一要做的事就是「登录一次」，标题直接说这件事。
                    '登录一次图书馆云打印',
                    style: TextStyle(
                      fontSize: AppTheme.fontTitle,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _error.isEmpty ? '登录状态已失效，请重新授权' : _error,
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  height: 1.55,
                  color: context.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    final ok = await _askPassword();
                    if (ok) await _loadList();
                  },
                  child: const Text('用统一认证登录'),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '用你登录掌上锡院的统一认证账号，不用另外注册。'
                '不在校园网时会自动走学校的 WebVPN。',
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  height: 1.5,
                  color: context.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
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
