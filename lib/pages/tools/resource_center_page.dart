import 'package:flutter/material.dart';

import '../../services/control_service.dart';
import '../../services/resource_download_service.dart';
import '../../services/resource_store.dart';
import '../../theme/app_theme.dart';
import '../../widgets/empty_state_art.dart' show EmptyArtVariant;
import '../../widgets/state_views.dart';
import 'my_resource_uploads_page.dart';
import 'resource_upload_page.dart';
import 'resource_viewer_page.dart';

/// 资源中心（）。
///
/// 只按课程名和教材聚合，不按教师区分 —— 同一门课可能换老师。
/// 课程内两区：教材 PDF / 试卷（答案绑定在试卷下）。
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

  Future<void> _upload() async {
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
        title: const Text('资源中心',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: context.cardColor,
        elevation: 0,
        actions: [
          IconButton(
            onPressed: _openMyUploads,
            icon: const Icon(Icons.cloud_upload_outlined),
            tooltip: '我的上传',
          ),
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
    final time = _syncedAt == null ? '暂无本地缓存' : '上次同步 ${_formatDate(_syncedAt!)}';
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
                  fontSize: AppTheme.fontCaption, color: Colors.orange.shade900),
            ),
          ),
          if (failure.canRetry)
            TextButton(
              onPressed: _loading ? null : _load,
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 28)),
              child: const Text('重试', style: TextStyle(fontSize: AppTheme.fontCaption)),
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
            onPressed: () =>
                setState(() => _sortRecent = !_sortRecent),
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
                message: failure.message.isEmpty
                    ? '暂时无法加载资源列表'
                    : failure.message,
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
                              fontSize: AppTheme.fontSmall, color: context.textSecondary)),
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
                          fontSize: AppTheme.fontCaption, color: context.textTertiary),
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

  @override
  void initState() {
    super.initState();
    _course = widget.course;
  }

  Future<void> _openEntry(ResourceEntry entry) async {
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
    final path = await _downloadWithProgress(entry, save: true);
    if (path == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已保存到：$path')),
    );
  }

  Future<String?> _downloadWithProgress(
    ResourceEntry entry, {
    required bool save,
  }) async {
    BuildContext? dialogCtx;
    StateSetter? setDialog;
    var progress = 0.0;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogCtx = ctx;
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            setDialog = setStateDialog;
            return AlertDialog(
              title: Text(save ? '正在保存' : '正在打开',
                  style: const TextStyle(fontSize: AppTheme.fontTitle)),
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
              onProgress: report,
            )
          : await ResourceDownloadService.ensureCached(
              entry,
              _course.name,
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
      if (mounted) {
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
                  style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textPrimary)),
            ),
          const SizedBox(height: 16),
          _sectionTitle('一区 · 教材 PDF'),
          _entryList(_course.of(ResourceKind.textbook), '暂无教材 PDF'),
          const SizedBox(height: 16),
          _sectionTitle('二区 · 试卷'),
          _buildExamSection(),
        ],
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
    final papers = _course.of(ResourceKind.examPaper);
    final answers = _course.of(ResourceKind.answer);
    if (papers.isEmpty) {
      return _entryList(const [], '暂无试卷');
    }
    return Column(
      children: [
        for (var i = 0; i < papers.length; i++) ...[
          _entryList([papers[i]], ''),
          for (final a in answers.where((a) =>
              a.parentId == papers[i].fileId ||
              (a.parentId == 0 && i == 0)))
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: _entryList([a], ''),
            ),
          if (i != papers.length - 1) const SizedBox(height: 8),
        ],
      ],
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
            style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
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
                                style: const TextStyle(fontSize: AppTheme.fontBody)),
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
