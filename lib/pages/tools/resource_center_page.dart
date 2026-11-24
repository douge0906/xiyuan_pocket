import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../../services/cancel_token.dart';
import '../../services/control_service.dart';
import '../../services/resource_download_service.dart';
import '../../services/resource_store.dart';
import '../../theme/app_theme.dart';
import '../../widgets/empty_state_art.dart' show EmptyArtVariant;
import '../../widgets/state_views.dart';
import 'my_resource_downloads_page.dart';
import 'my_resource_uploads_page.dart';
import 'resource_upload_page.dart';
import 'resource_text_preview_page.dart';
import 'resource_viewer_page.dart';

/// 网页版没有本地文件系统：path_provider 没有 Web 实现，dart:io 的
/// File 在浏览器里只会抛异常。涉及存盘/读盘的入口统一用这句提示。
const String _kWebFileHint = '网页版暂不支持下载到本机，请用安卓 App 打开';

/// 资源中心（）。
///
/// 按「课程 + 教材」聚合，不按教师区分 —— 同一门课可能换老师、换教材。
/// 课程内两区：教材 PDF / 试卷（答案绑定在试卷下，未关联答案单列）。
class ResourceCenterPage extends StatefulWidget {
  const ResourceCenterPage({super.key});

  @override
  State<ResourceCenterPage> createState() => _ResourceCenterPageState();
}

class _ResourceCenterPageState extends State<ResourceCenterPage> {
  final TextEditingController _search = TextEditingController();
  List<ResourceCourse> _courses = const [];
  bool _loading = true;
  String? _error;
  String _query = '';
  String _filter = 'all';
  bool _sortRecent = true;
  ControlFailure? _failure;
  String? _syncedAt;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _failure = null;
    });
    final cached = await ResourceStore.loadCachedResult();
    if (!mounted) return;
    if (cached.courses.isNotEmpty || cached.syncedAt != null) {
      setState(() {
        _courses = cached.courses;
        _syncedAt = cached.syncedAt;
        _loading = false;
      });
    }
    final result = await ResourceStore.loadCoursesResult();
    if (!mounted) return;
    setState(() {
      _courses = result.courses;
      _failure = result.failure;
      _syncedAt = result.syncedAt;
      _loading = false;
      if (result.courses.isEmpty && result.failure == null) {
        _error = '还没有收录课程，去「我的教材」同步后再来看看';
      }
    });
  }

  List<ResourceCourse> get _filtered {
    final q = _query.trim().toLowerCase();
    var list = _courses.where((c) {
      if (q.isNotEmpty &&
          !c.name.toLowerCase().contains(q) &&
          !c.book.toLowerCase().contains(q)) {
        return false;
      }
      return switch (_filter) {
        'has' => c.totalCount > 0,
        'textbook' => c.of(ResourceKind.textbook).isNotEmpty,
        'exam' => c.of(ResourceKind.examPaper).isNotEmpty,
        'answer' => c.of(ResourceKind.answer).isNotEmpty,
        _ => true,
      };
    }).toList();
    if (_sortRecent) {
      list.sort((a, b) => b.latestAt.compareTo(a.latestAt));
    } else {
      list.sort((a, b) => a.name.compareTo(b.name));
    }
    return list;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openMyUploads() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const MyResourceUploadsPage(),
    ));
  }

  Future<void> _openMyDownloads() async {
    if (kIsWeb) {
      _toast(_kWebFileHint);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const MyResourceDownloadsPage(),
    ));
  }

  Future<void> _upload() async {
    // 浏览器里 file_picker 返回的 PlatformFile.path 为 null，
    // 上传会一路走到「没有可上传的文件」—— 不如直接说清楚。
    if (kIsWeb) {
      _toast('网页版暂不支持上传文件，请用安卓 App');
      return;
    }
    final submitted = await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ResourceUploadPage()),
    );
    if (!mounted) return;
    if (submitted == true) {
      _toast('已提交审核，通过后会出现在资源中心');
    }
    _load();
  }

  Future<void> _open(ResourceCourse course) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _CourseResourcesPage(course: course),
    ));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Scaffold(
      backgroundColor: isDark ? context.scaffoldColor : Colors.white,
      appBar: AppBar(
        title:
            const Text('资源中心', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: context.cardColor,
        elevation: 0,
        actions: [
          // 🔴 Web 上这两项必然失败（下载到本机 / 上传文件都依赖原生能力，
          //    见 _openMyDownloads / _upload 里的 kIsWeb 兜底）→ 直接不显示，
          //    免得用户点了只吃到一句「网页版暂不支持」。
          //    「我的上传」是云端列表，Web 可用，保留。
          if (!kIsWeb)
            IconButton(
              onPressed: _openMyDownloads,
              icon: const Icon(Icons.download_for_offline_outlined),
              tooltip: '我的下载',
            ),
          IconButton(
            onPressed: _openMyUploads,
            icon: const Icon(Icons.cloud_upload_outlined),
            tooltip: '我的上传',
          ),
          if (!kIsWeb)
            IconButton(
              onPressed: _upload,
              icon: const Icon(Icons.upload_file_rounded),
              tooltip: '上传资源',
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: '搜索课程',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                isDense: true,
                filled: true,
                fillColor: context.surfaceColor,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: AppTheme.radiusMdAll,
                  borderSide: BorderSide(color: context.borderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: AppTheme.radiusMdAll,
                  borderSide: BorderSide(color: context.borderColor),
                ),
              ),
            ),
          ),
          _buildToolbar(),
          if (_failure != null) _buildOfflineBanner(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildOfflineBanner() {
    final failure = _failure!;
    final time =
        _syncedAt == null ? '暂无本地缓存' : '上次同步 ${_formatDate(_syncedAt!)}';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: .08),
        borderRadius: AppTheme.radiusSmAll,
        border: Border.all(color: Colors.orange.withValues(alpha: .25)),
      ),
      child: Row(
        children: [
          Icon(
            failure.kind == ControlFailureKind.offline
                ? Icons.cloud_off_rounded
                : Icons.sync_problem_rounded,
            size: 16,
            color: Colors.orange.shade800,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${failure.message} · $time',
              style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: Colors.orange.shade900),
            ),
          ),
          if (failure.canRetry)
            TextButton(
              onPressed: _loading ? null : _load,
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 28)),
              child: const Text('重试',
                  style: TextStyle(fontSize: AppTheme.fontCaption)),
            ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    const filters = [
      ('all', '全部'),
      ('has', '有资源'),
      ('textbook', '教材'),
      ('exam', '试卷'),
      ('answer', '答案'),
    ];
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final f in filters)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(f.$2,
                          style: const TextStyle(fontSize: AppTheme.fontSmall)),
                      selected: _filter == f.$1,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _filter = f.$1),
                    ),
                  ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => setState(() => _sortRecent = !_sortRecent),
            icon: Icon(
                _sortRecent
                    ? Icons.schedule_rounded
                    : Icons.sort_by_alpha_rounded,
                size: 16),
            label: Text(_sortRecent ? '最近' : '课程名',
                style: const TextStyle(fontSize: AppTheme.fontSmall)),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      // 用统一的 LoadingOverlay 骨架而不是裸 CircularProgressIndicator：
      // 全库散着 40 处裸转圈，这一处先收口（2026-11-03）。
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_courses.isEmpty) {
      // 🔴 2026-11-03：本页原来是全库唯一「既无 ErrorState 也无 EmptyState」
      // 的页面 —— 请求失败时只显示一行灰字「暂无课程」，用户看不出是
      // 网断了、控制台挂了还是真的没收录，也没法重试。
      //
      // 现在按 `_failure` 区分两种性质完全不同的状态：
      //   · 有 failure（网络/服务端问题）→ ErrorState，文案带原因 + 重试
      //   · 没有 failure（接口通了但确实没数据）→ EmptyState，引导去同步
      final failure = _failure;
      if (failure != null) {
        return RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              const SizedBox(height: 40),
              ErrorState(
                message:
                    failure.message.isEmpty ? '暂时无法加载资源列表' : failure.message,
                onRetry: _load,
              ),
            ],
          ),
        );
      }
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 24),
            EmptyState(
              message: _error ?? '还没有收录课程',
              hint: '去「我的教材」同步一次，回来就能看到这门课的资料',
              artVariant: EmptyArtVariant.book,
              action: OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重新加载'),
              ),
            ),
          ],
        ),
      );
    }
    final list = _filtered;
    if (list.isEmpty) {
      return EmptyState(
        message: '没有找到相关课程',
        hint: '试试换一个关键词，或清掉上面的筛选条件',
        artVariant: EmptyArtVariant.search,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          for (final course in list) ...[
            _courseCard(course),
            const SizedBox(height: AppTheme.gapSm),
          ],
        ],
      ),
    );
  }

  Widget _courseCard(ResourceCourse course) {
    final textbookCount = course.of(ResourceKind.textbook).length;
    final paperCount = course.of(ResourceKind.examPaper).length;
    final answerCount = course.of(ResourceKind.answer).length;
    return Material(
      color: context.surfaceColor,
      borderRadius: AppTheme.radiusMdAll,
      child: InkWell(
        borderRadius: AppTheme.radiusMdAll,
        onTap: () => _open(course),
        child: Container(
          padding: const EdgeInsets.all(AppTheme.gapMd),
          decoration: BoxDecoration(
            borderRadius: AppTheme.radiusMdAll,
            border: Border.all(color: context.borderColor),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 60,
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: .07),
                  borderRadius: AppTheme.radiusSmAll,
                  border: Border.all(
                    color: AppTheme.primaryColor.withValues(alpha: .14),
                  ),
                ),
                child: Icon(Icons.menu_book_rounded,
                    size: 22, color: AppTheme.primaryColor),
              ),
              const SizedBox(width: AppTheme.gapMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(course.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: AppTheme.fontBody,
                            fontWeight: FontWeight.w600)),
                    if (course.hasBook) ...[
                      const SizedBox(height: 3),
                      Text(course.book,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: AppTheme.fontSmall,
                              color: context.textSecondary)),
                    ],
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (textbookCount > 0)
                          _tag('教材 $textbookCount', AppTheme.primaryColor)
                        else if (course.hasBook)
                          _tag('教材', AppTheme.primaryColor),
                        if (paperCount > 0)
                          _tag('试卷 $paperCount', Colors.blueGrey),
                        if (answerCount > 0)
                          _tag('答案 $answerCount', Colors.teal),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${_formatDate(course.latestAt)} · ${_formatBytes(course.totalSize)}',
                      style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          color: context.textTertiary),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 20, color: context.textTertiary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(text,
          style: TextStyle(fontSize: AppTheme.fontCaption, color: color)),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

String _formatDate(String iso) {
  if (iso.trim().isEmpty) return '暂无更新';
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 60) return '${diff.inMinutes.clamp(1, 59)} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';
}

class _CourseResourcesPage extends StatefulWidget {
  const _CourseResourcesPage({required this.course});
  final ResourceCourse course;

  @override
  State<_CourseResourcesPage> createState() => _CourseResourcesPageState();
}

class _CourseResourcesPageState extends State<_CourseResourcesPage> {
  late final ResourceCourse _course;
  ResourceQuota? _quota;

  /// 下载/打开闸门：进度框是 barrierDismissible: false，连点会叠出第二层，
  /// 而两层各拿一个 CancelToken，取消一层另一层还在跑，关不干净。
  bool _busy = false;

  /// 试卷区简易检索关键词（匹配试卷文件名，忽略大小写与空白）。
  final TextEditingController _paperController = TextEditingController();
  String _paperQuery = '';

  @override
  void initState() {
    super.initState();
    _course = widget.course;
    _loadQuota();
  }

  Future<void> _loadQuota() async {
    final quota = await ControlService.fetchResourceQuota();
    if (!mounted || quota == null) return;
    setState(() => _quota = quota);
  }

  @override
  void dispose() {
    _paperController.dispose();
    super.dispose();
  }

  Future<void> _openEntry(ResourceEntry entry) async {
    // docx 的正文由服务端抽取，网页版照样能看。
    // 其余（PDF 预览、doc、压缩包）都要先落成本地文件再打开，网页版做不到。
    if (kIsWeb && !entry.isDocx) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_kWebFileHint)),
      );
      return;
    }
    if (entry.isDocx) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ResourceTextPreviewPage(
          title: entry.name,
          fileId: entry.fileId,
          onDownload: () => _download(entry),
        ),
      ));
      return;
    }
    if (entry.isDoc) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            side: BorderSide(color: context.borderColor),
          ),
          title: Row(
            children: [
              const Expanded(child: Text('暂不支持在线预览')),
            IconButton(
              tooltip: '关闭',
              onPressed: () => Navigator.pop(ctx),
              icon: Icon(Icons.close_rounded,
                  size: 20, color: context.textTertiary),
            ),
            ],
          ),
          content: Text(
            '${entry.name}\n\n旧版 .doc 文件需要下载后用 Word / WPS 打开。',
            style: const TextStyle(fontSize: AppTheme.fontSmall),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _download(entry);
              },
              child: const Text('下载'),
            ),
          ],
        ),
      );
      return;
    }
    if (!entry.isPdf) {
      await _download(entry);
      return;
    }
    final path = await _downloadWithProgress(entry, save: false);
    if (path == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ResourceViewerPage(
        title: entry.name,
        filePath: path,
      ),
    ));
  }

  Future<void> _download(ResourceEntry entry) async {
    if (kIsWeb) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_kWebFileHint)),
      );
      return;
    }
    // 先看本机有没有：有就别再下一遍（费流量，也费用户等待）。
    // `listDownloads()` 已经过滤掉文件已被删掉的条目，命中的一定点得开。
    final local = await _findLocalCopy(entry);
    if (!mounted) return;
    if (local != null) {
      final again = await _askReuseLocal(local);
      if (!mounted || again == null) return;
      if (!again) {
        // 「直接打开」：不再联网，走本地文件。
        await _openLocal(local);
        return;
      }
      // 「重新下载」：落到下面原来的流程。
    }
    final path = await _downloadWithProgress(entry, save: true);
    if (path == null || !mounted) return;
    unawaited(_loadQuota());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已保存到：$path')),
    );
  }

  /// 本机是否已有这个文件（按服务端 fileId 认，同名不同课不会串）。
  Future<DownloadedResource?> _findLocalCopy(ResourceEntry entry) async {
    if (entry.fileId <= 0) return null;
    try {
      final items = await ResourceDownloadService.listDownloads();
      for (final it in items) {
        if (it.fileId == entry.fileId) return it;
      }
    } catch (_) {}
    return null;
  }

  /// 「这个文件已经下载过了」→ true = 重新下载，false = 直接打开，null = 取消。
  Future<bool?> _askReuseLocal(DownloadedResource local) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          side: BorderSide(color: context.borderColor),
        ),
        title: Row(
          children: [
            const Expanded(
              child: Text('这个文件已经下载过了',
                  style: TextStyle(fontSize: AppTheme.fontTitle)),
            ),
            IconButton(
              tooltip: '关闭',
              onPressed: () => Navigator.pop(ctx),
              icon: Icon(Icons.close_rounded,
                  size: 20, color: context.textTertiary),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(local.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: AppTheme.fontSmall)),
            const SizedBox(height: 8),
            Text('本机已保存，可以直接打开，不用再下一遍。',
                style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    color: context.textSecondary)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重新下载'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('直接打开'),
          ),
        ],
      ),
    );
  }

  /// 打开本机已保存的那份（不联网）。
  Future<void> _openLocal(DownloadedResource local) async {
    final lower = local.name.toLowerCase();
    if (lower.endsWith('.pdf')) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ResourceViewerPage(
          title: local.name,
          filePath: local.path,
        ),
      ));
      return;
    }
    if (lower.endsWith('.docx')) {
      // 正文是服务端抽的：抽不到时（断网 / 服务端没存正文）必须还有出口，
      // 所以两个参数都要给 —— 只给 downloadLabel 不给 onDownload 的话，
      // `ResourceTextPreviewPage` 压根不会渲染那个按钮。
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ResourceTextPreviewPage(
          title: local.name,
          fileId: local.fileId,
          onDownload: () => _shareLocal(local),
          downloadLabel: '用其他应用打开本地文件',
        ),
      ));
      return;
    }
    // .doc 等：本机有文件但没法在 App 内看，直接甩给系统打开。
    await _shareLocal(local);
  }

  /// 把本机这份文件交给系统（选其他 App 打开 / 发给自己）。
  Future<void> _shareLocal(DownloadedResource local) async {
    try {
      await Share.shareXFiles([XFile(local.path)], text: local.name);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '打开失败：${e.toString().replaceFirst('Exception: ', '')}'),
        ),
      );
    }
  }

  Future<String?> _downloadWithProgress(
    ResourceEntry entry, {
    required bool save,
  }) async {
    if (_busy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('上一个文件还在处理，请等它完成')),
      );
      return null;
    }
    _busy = true;
    try {
      return await _downloadWithProgressInner(entry, save: save);
    } finally {
      _busy = false;
    }
  }

  Future<String?> _downloadWithProgressInner(
    ResourceEntry entry, {
    required bool save,
  }) async {
    BuildContext? dialogCtx;
    StateSetter? setDialog;
    var progress = 0.0;
    var cancelling = false;
    final cancelToken = CancelToken();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogCtx = ctx;
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            setDialog = setStateDialog;
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                side: BorderSide(color: context.borderColor),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(save ? '正在保存' : '正在打开',
                        style: const TextStyle(fontSize: AppTheme.fontTitle)),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    // 进度框不能点外部关，但右上角 × 就是「取消」的同义入口，
                    // 与 R8「点 × 或保存/取消才关闭」一致。
                    onPressed: cancelling
                        ? null
                        : () {
                            cancelToken.cancel();
                            setDialog?.call(() => cancelling = true);
                          },
                    icon: Icon(Icons.close_rounded,
                        size: 20, color: context.textTertiary),
                  ),
                ],
              ),
              content: SizedBox(
                width: 260,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(entry.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: AppTheme.fontSmall)),
                    const SizedBox(height: 14),
                    LinearProgressIndicator(
                        value: progress > 0 ? progress : null),
                    const SizedBox(height: 8),
                    Text('${(progress * 100).toInt()}%',
                        style: const TextStyle(fontSize: AppTheme.fontSmall)),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: cancelling
                            ? null
                            : () {
                                cancelToken.cancel();
                                setDialog?.call(() => cancelling = true);
                              },
                        child: Text(cancelling ? '正在取消…' : '取消'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    // 等对话框真正挂载，避免下载过快时 dialogCtx 仍为空。
    await Future<void>.delayed(Duration.zero);

    void report(int received, int total) {
      if (total <= 0) return;
      final ctx = dialogCtx;
      if (ctx == null || !ctx.mounted) return;
      setDialog?.call(() => progress = received / total);
    }

    try {
      final path = save
          ? await ResourceDownloadService.saveToDocuments(
              entry,
              _course.name,
              cancelToken: cancelToken,
              onProgress: report,
            )
          : await ResourceDownloadService.ensureCached(
              entry,
              _course.name,
              cancelToken: cancelToken,
              onProgress: report,
            );
      if (dialogCtx != null && dialogCtx!.mounted) {
        Navigator.of(dialogCtx!).pop();
      }
      return path;
    } catch (e) {
      if (dialogCtx != null && dialogCtx!.mounted) {
        Navigator.of(dialogCtx!).pop();
      }
      final cancelled =
          e is ControlFailure && e.kind == ControlFailureKind.cancelled;
      if (!cancelled && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Scaffold(
      backgroundColor: isDark ? context.scaffoldColor : Colors.white,
      appBar: AppBar(
        title: Text(_course.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: context.cardColor,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          if (_course.hasBook)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: context.surfaceColor,
                borderRadius: AppTheme.radiusMdAll,
                border: Border.all(color: context.borderColor),
              ),
              child: Text('教材：${_course.book}',
                  style: TextStyle(
                      fontSize: AppTheme.fontSmall,
                      color: context.textPrimary)),
            ),
          if (_quota != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: .07),
                  borderRadius: AppTheme.radiusSmAll,
                ),
                child: Text(
                  '今日下载剩余 ${_quota!.remaining}/${_quota!.limit} 次'
                  '（基础 ${_quota!.baseLimit} 次/天'
                  '${_quota!.bonusLimit > 0 ? '，已邀 ${_quota!.invitedCount} 人 +${_quota!.bonusLimit} 次' : '，邀请 1 人 +${_quota!.bonusPerInvite} 次'}）',
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: AppTheme.primaryColor),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          _sectionTitle('一区 · 教材 PDF'),
          _entryList(_course.of(ResourceKind.textbook), '暂无教材 PDF'),
          const SizedBox(height: 16),
          _sectionTitle('二区 · 试卷'),
          if (_course.of(ResourceKind.examPaper).isNotEmpty) ...[
            _paperSearchBox(),
            const SizedBox(height: 10),
          ],
          _buildExamSection(),
        ],
      ),
    );
  }

  /// 课程内试卷简易检索框：按试卷文件名关键词过滤（答案跟随命中的试卷）。
  Widget _paperSearchBox() {
    return TextField(
      controller: _paperController,
      onChanged: (v) => setState(() => _paperQuery = v),
      decoration: InputDecoration(
        hintText: '检索试卷（按文件名 / 年份）',
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        isDense: true,
        filled: true,
        fillColor: context.surfaceColor,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: OutlineInputBorder(
          borderRadius: AppTheme.radiusMdAll,
          borderSide: BorderSide(color: context.borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppTheme.radiusMdAll,
          borderSide: BorderSide(color: context.borderColor),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: TextStyle(
            fontSize: AppTheme.fontSmall,
            fontWeight: FontWeight.w700,
            color: context.textPrimary,
          )),
    );
  }

  Widget _buildExamSection() {
    final allPapers = _course.of(ResourceKind.examPaper);
    final answers = _course.of(ResourceKind.answer);
    // 🔴 v1.0.9：旧数据里 parent_id=0 的答案不再默认挂到第一份试卷。
    //    没有绑定关系的答案单独列成“未关联答案”，避免用户误以为它属于某份卷子。
    final orphans = answers.where((a) => a.parentId == 0).toList();
    if (allPapers.isEmpty) {
      return Column(
        children: [
          _entryList(const [], '暂无试卷'),
          if (orphans.isNotEmpty) ...[
            const SizedBox(height: 14),
            _sectionTitle('未关联答案'),
            _entryList(orphans, ''),
          ],
        ],
      );
    }
    final q = _paperQuery.trim().toLowerCase();
    final papers = q.isEmpty
        ? allPapers
        : allPapers.where((p) => p.name.toLowerCase().contains(q)).toList();
    if (papers.isEmpty) {
      return _entryList(const [], '没有匹配「$_paperQuery」的试卷');
    }
    return Column(
      children: [
        for (var i = 0; i < papers.length; i++) ...[
          _entryList([papers[i]], ''),
          for (final a in answers
              .where((a) => a.parentId != 0 && a.parentId == papers[i].fileId))
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: _entryList([a], ''),
            ),
          if (i != papers.length - 1) const SizedBox(height: 8),
        ],
        if (orphans.isNotEmpty) ...[
          const SizedBox(height: 14),
          _sectionTitle('未关联答案'),
          _entryList(orphans, ''),
        ],
      ],
    );
  }

  Future<void> _reportEntry(ResourceEntry entry, String reason) async {
    final detail = TextEditingController();
    const labels = {
      'broken': '文件失效 / 打不开',
      'mismatch': '内容与课程不符',
      'duplicate': '重复资源',
      'copyright': '侵权 / 不宜内容',
      'other': '其他问题',
    };
    final submitted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          side: BorderSide(color: context.borderColor),
        ),
        title: Row(
          children: [
            Expanded(child: Text('反馈：${labels[reason] ?? '资源问题'}')),
            IconButton(
              tooltip: '关闭',
              onPressed: () => Navigator.pop(ctx, false),
              icon: Icon(Icons.close_rounded,
                  size: 20, color: context.textTertiary),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: AppTheme.fontSmall)),
            const SizedBox(height: 12),
            TextField(
              controller: detail,
              maxLength: 200,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '补充说明（可选）',
                hintText: '例如：打开后是空白页、答案与试卷不对应',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('提交反馈')),
        ],
      ),
    );
    if (submitted != true || !mounted) {
      detail.dispose();
      return;
    }
    final detailText = detail.text.trim();
    detail.dispose();
    final failure = await ControlService.reportResource(
      uploadId: entry.uploadId,
      fileId: entry.fileId,
      reason: reason,
      detail: detailText,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(failure?.message ?? '反馈已提交，管理员会尽快处理')),
    );
  }

  Widget _entryList(List<ResourceEntry> entries, String emptyText) {
    if (entries.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: AppTheme.radiusMdAll,
          border: Border.all(color: context.borderColor),
        ),
        child: Text(emptyText,
            style: TextStyle(
                fontSize: AppTheme.fontSmall, color: context.textTertiary)),
      );
    }
    return Column(
      children: [
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: context.surfaceColor,
              borderRadius: AppTheme.radiusMdAll,
              child: InkWell(
                borderRadius: AppTheme.radiusMdAll,
                onTap: () => _openEntry(entry),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: AppTheme.radiusMdAll,
                    border: Border.all(color: context.borderColor),
                  ),
                  child: Row(
                    children: [
                      Icon(
                          entry.kind == ResourceKind.answer
                              ? Icons.fact_check_outlined
                              : Icons.description_outlined,
                          size: 20,
                          color: context.textSecondary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                entry.kind == ResourceKind.answer
                                    ? '答案 · ${entry.name}'
                                    : entry.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: AppTheme.fontBody)),
                            const SizedBox(height: 3),
                            Text(
                              '${_formatBytes(entry.size)} · '
                              '${_formatDate(entry.createdAt)}'
                              '${entry.downloads > 0 ? ' · 下载 ${entry.downloads}' : ''}',
                              style: TextStyle(
                                  fontSize: AppTheme.fontCaption,
                                  color: context.textTertiary),
                            ),
                            if (entry.contributor.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                '贡献者：${entry.contributor}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: AppTheme.fontCaption,
                                    color: context.textTertiary),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (entry.fileId > 0 && entry.uploadId > 0)
                        PopupMenuButton<String>(
                          tooltip: '反馈问题',
                          icon: Icon(Icons.more_horiz_rounded,
                              size: 19, color: context.textSecondary),
                          onSelected: (value) => _reportEntry(entry, value),
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                                value: 'broken', child: Text('文件失效 / 打不开')),
                            PopupMenuItem(
                                value: 'mismatch', child: Text('内容与课程不符')),
                            PopupMenuItem(
                                value: 'duplicate', child: Text('重复资源')),
                            PopupMenuItem(
                                value: 'copyright', child: Text('侵权 / 不宜内容')),
                            PopupMenuItem(value: 'other', child: Text('其他问题')),
                          ],
                        ),
                      IconButton(
                        onPressed: () => _download(entry),
                        icon: const Icon(Icons.download_rounded, size: 19),
                        tooltip: '保存到本机',
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.all(6),
                        color: context.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
