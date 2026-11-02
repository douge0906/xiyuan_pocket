import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/control_service.dart';
import '../../services/resource_store.dart';
import '../../theme/app_theme.dart';

/// 上传资源：搜索教材 → 选区域 → 教材 PDF 或「试卷 + 答案」一次提交。
class ResourceUploadPage extends StatefulWidget {
  const ResourceUploadPage({super.key});

  @override
  State<ResourceUploadPage> createState() => _ResourceUploadPageState();
}

class _ResourceUploadPageState extends State<ResourceUploadPage> {
  final TextEditingController _note = TextEditingController();
  final TextEditingController _contributor = TextEditingController();
  final List<PlatformFile> _paperFiles = [];
  final List<PlatformFile> _answerFiles = [];

  List<ResourceCourse> _courses = const [];
  ResourceCourse? _selected;
  bool _loadingCourses = true;
  ResourceKind _area = ResourceKind.textbook;
  bool _saving = false;
  double _progress = 0;
  int _currentFile = 0;
  int _totalFiles = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCourses();
    _loadContributor();
  }

  /// 带出上次成功上传时填的署名，省得每次重打。
  ///
  /// 只在输入框还空着时填 —— 读 prefs 是异步的，用户可能已经抢先输入了，
  /// 直接覆盖会把刚打的字冲掉。
  Future<void> _loadContributor() async {
    final saved = await ResourceStore.loadContributor();
    if (!mounted || saved.isEmpty) return;
    if (_contributor.text.isNotEmpty) return;
    _contributor.text = saved;
  }

  @override
  void dispose() {
    _note.dispose();
    _contributor.dispose();
    super.dispose();
  }

  Future<void> _loadCourses() async {
    final list = await ResourceStore.loadCourses();
    if (!mounted) return;
    setState(() {
      _courses = list;
      _loadingCourses = false;
    });
  }

  bool get _isExam => _area == ResourceKind.examPaper;
  List<PlatformFile> get _allFiles =>
      [..._paperFiles, if (_isExam) ..._answerFiles];
  int get _totalSize =>
      _allFiles.fold<int>(0, (sum, f) => sum + f.size);
  bool get _overSize => _totalSize > 80 * 1024 * 1024;

  Future<void> _pickBook() async {
    final query = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) {
          final q = query.text.trim().toLowerCase();
          final list = _courses.where((c) {
            if (q.isEmpty) return true;
            return c.name.toLowerCase().contains(q) ||
                c.book.toLowerCase().contains(q);
          }).toList();
          return AlertDialog(
            title: const Text('选择教材'),
            content: SizedBox(
              width: 360,
              height: 420,
              child: Column(
                children: [
                  TextField(
                    controller: query,
                    onChanged: (_) => setDialog(() {}),
                    decoration: const InputDecoration(
                      hintText: '搜索课程或教材',
                      prefixIcon: Icon(Icons.search_rounded, size: 20),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: _loadingCourses
                        ? const Center(
                            child:
                                CircularProgressIndicator(strokeWidth: 2.5))
                        : list.isEmpty
                            ? const Center(child: Text('没有匹配的课程'))
                            : ListView.separated(
                                itemCount: list.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 6),
                                itemBuilder: (context, i) {
                                  final c = list[i];
                                  final selected = _selected?.key == c.key;
                                  return Material(
                                    color: selected
                                        ? AppTheme.primaryColor
                                            .withValues(alpha: .07)
                                        : context.surfaceColor,
                                    borderRadius: AppTheme.radiusSmAll,
                                    child: InkWell(
                                      borderRadius: AppTheme.radiusSmAll,
                                      onTap: () {
                                        setState(() => _selected = c);
                                        Navigator.of(ctx).pop();
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 9),
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              AppTheme.radiusSmAll,
                                          border: Border.all(
                                              color: selected
                                                  ? AppTheme.primaryColor
                                                      .withValues(alpha: .4)
                                                  : context.borderColor),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(c.name,
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                    fontSize: AppTheme.fontBody,
                                                    fontWeight:
                                                        FontWeight.w600)),
                                            if (c.hasBook)
                                              Text(c.book,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                      fontSize: AppTheme.fontSmall,
                                                      color:
                                                          context.textSecondary)),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
            ],
          );
        },
      ),
    );
    // 🔴 释放搜索框控制器（每次打开教材选择弹窗泄漏一个）。
    query.dispose();
  }

  List<String> get _extensions => _isExam
      ? const ['pdf', 'doc', 'docx']
      : const ['pdf'];

  Future<void> _pickFiles({required bool answer}) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: !(_isExam && !answer),
        type: FileType.custom,
        allowedExtensions: _extensions,
        withData: false,
      );
      // 🔴 系统文件选择器是原生 Activity，用户可在里面停留任意久，
      //    期间页面可能被系统回收 → 返回后必须先判 mounted。
      if (!mounted) return;
      if (result == null || result.files.isEmpty) return;
      setState(() {
        final target = answer ? _answerFiles : _paperFiles;
        if (_isExam && !answer) target.clear();
        for (final f in result.files) {
          final duplicate = target.any(
              (x) => x.name == f.name && x.size == f.size && x.path == f.path);
          if (!duplicate && f.size > 0) target.add(f);
        }
      });
    } catch (_) {
      _toast('无法打开文件选择器');
    }
  }

  Future<void> _submit() async {
    final course = _selected;
    if (course == null) {
      _toast('请先选择教材');
      return;
    }
    if (_paperFiles.isEmpty) {
      _toast(_isExam ? '请选择试卷文件' : '请选择教材 PDF');
      return;
    }
    if (_overSize) {
      _toast('总大小 ${_fmtSize(_totalSize)}，超过 80MB 上限');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _progress = 0;
      _currentFile = 1;
      _totalFiles = _allFiles.length;
    });
    final error = await ControlService.uploadResource(
      courseName: course.name,
      bookName: course.book,
      area: _isExam ? 'exam' : 'textbook',
      note: _note.text,
      contributor: _contributor.text,
      paperFiles: _paperFiles,
      answerFiles: _isExam ? _answerFiles : const [],
      onProgress: (sent, total, current, totalFiles) {
        if (!mounted) return;
        setState(() {
          _progress = total > 0 ? (sent / total).clamp(0.0, 1.0) : 0;
          _currentFile = current;
          _totalFiles = totalFiles;
        });
      },
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      setState(() => _error = error);
      _toast(error);
      return;
    }
    // 成功才记住，避免把打错的署名也存下来复用。
    await ResourceStore.saveContributor(_contributor.text);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Scaffold(
      backgroundColor: isDark ? context.scaffoldColor : Colors.white,
      appBar: AppBar(
        title: const Text('上传资源',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: context.cardColor,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _label('选择教材'),
          const SizedBox(height: 8),
          _bookSelector(),
          const SizedBox(height: 18),
          _label('选择上传区域'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _areaCard(
                  ResourceKind.textbook,
                  Icons.picture_as_pdf_outlined,
                  '教材 PDF',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _areaCard(
                  ResourceKind.examPaper,
                  Icons.assignment_outlined,
                  '试卷',
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (!_isExam)
            _uploadZone(
              title: '教材 PDF',
              subtitle: '仅 PDF，可多选，单个 ≤ 80MB',
              files: _paperFiles,
              onPick: () => _pickFiles(answer: false),
              onRemove: (f) => setState(() => _paperFiles.remove(f)),
            )
          else ...[
            _uploadZone(
              title: '试卷',
              subtitle: 'PDF / DOC / DOCX，可多选，必选',
              files: _paperFiles,
              onPick: () => _pickFiles(answer: false),
              onRemove: (f) => setState(() => _paperFiles.remove(f)),
            ),
            const SizedBox(height: 12),
            _uploadZone(
              title: '答案（可选）',
              subtitle: '随这份试卷一起提交，PDF / DOC / DOCX',
              files: _answerFiles,
              onPick: () => _pickFiles(answer: true),
              onRemove: (f) => setState(() => _answerFiles.remove(f)),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            '已选 ${_allFiles.length} 个文件 · 共 ${_fmtSize(_totalSize)} / 80MB',
            style: TextStyle(
              fontSize: AppTheme.fontSmall,
              color: _overSize
                  ? Theme.of(context).colorScheme.error
                  : context.textTertiary,
            ),
          ),
          if (_saving) ...[
            const SizedBox(height: 14),
            LinearProgressIndicator(
                value: _progress > 0 ? _progress : null),
            const SizedBox(height: 6),
            Text(
              '正在上传 第 $_currentFile / $_totalFiles 个 · '
              '${(_progress * 100).toInt()}%',
              style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textSecondary),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    color: Theme.of(context).colorScheme.error)),
            TextButton(
              onPressed: _saving ? null : _submit,
              child: const Text('重试上传'),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _contributor,
            maxLength: ResourceStore.contributorMaxLength,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: '署名',
              hintText: '例：小姜（留空则不显示贡献者）',
              helperText: '会随资源展示，下次上传自动带出',
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _note,
            maxLines: 2,
            maxLength: 200,
            decoration: const InputDecoration(
              labelText: '备注',
              hintText: '给审核人员看的备注',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 46,
            child: ElevatedButton(
              onPressed: _saving ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
              ),
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Text(_allFiles.isEmpty
                      ? '提交审核'
                      : '提交审核（${_allFiles.length} 个文件）'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Text(text,
      style: TextStyle(
          fontSize: AppTheme.fontSmall,
          fontWeight: FontWeight.w700,
          color: context.textPrimary));

  Widget _bookSelector() {
    return InkWell(
      onTap: _loadingCourses ? null : _pickBook,
      borderRadius: AppTheme.radiusMdAll,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: AppTheme.radiusMdAll,
          border: Border.all(color: context.borderColor),
        ),
        child: Row(
          children: [
            Icon(Icons.menu_book_rounded,
                size: 18, color: AppTheme.primaryColor),
            const SizedBox(width: 8),
            Expanded(
              child: _selected == null
                  ? Text(_loadingCourses ? '正在加载教材…' : '请选择教材',
                      style: TextStyle(
                          fontSize: AppTheme.fontSmall, color: context.textTertiary))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_selected!.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: AppTheme.fontBody,
                                fontWeight: FontWeight.w600)),
                        if (_selected!.hasBook)
                          Text(_selected!.book,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: AppTheme.fontSmall,
                                  color: context.textSecondary)),
                      ],
                    ),
            ),
            Icon(Icons.search_rounded,
                size: 18, color: context.textTertiary),
          ],
        ),
      ),
    );
  }

  Widget _uploadZone({
    required String title,
    required String subtitle,
    required List<PlatformFile> files,
    required VoidCallback onPick,
    required ValueChanged<PlatformFile> onRemove,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _saving ? null : onPick,
          borderRadius: AppTheme.radiusMdAll,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(
              color: context.surfaceColor,
              borderRadius: AppTheme.radiusMdAll,
              border: Border.all(
                  color: AppTheme.primaryColor.withValues(alpha: .35)),
            ),
            child: Column(
              children: [
                Icon(Icons.upload_rounded,
                    size: 24, color: AppTheme.primaryColor),
                const SizedBox(height: 5),
                Text(files.isEmpty ? '选择$title' : '继续添加$title',
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall, color: context.textPrimary)),
                const SizedBox(height: 3),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: AppTheme.fontCaption, color: context.textTertiary)),
              ],
            ),
          ),
        ),
        if (files.isNotEmpty)
          for (final f in files)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: context.surfaceColor,
                borderRadius: AppTheme.radiusSmAll,
                border: Border.all(color: context.borderColor),
              ),
              child: Row(
                children: [
                  Icon(Icons.insert_drive_file_outlined,
                      size: 17, color: context.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${f.name} · ${_fmtSize(f.size)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: AppTheme.fontSmall)),
                  ),
                  IconButton(
                    onPressed: _saving ? null : () => onRemove(f),
                    icon: const Icon(Icons.close_rounded, size: 16),
                    constraints: const BoxConstraints(),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _areaCard(ResourceKind kind, IconData icon, String label) {
    final selected = _area == kind;
    return InkWell(
      onTap: _saving
          ? null
          : () => setState(() {
                _area = kind;
                _paperFiles.clear();
                _answerFiles.clear();
                _error = null;
              }),
      borderRadius: AppTheme.radiusMdAll,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primaryColor.withValues(alpha: .07)
              : context.surfaceColor,
          borderRadius: AppTheme.radiusMdAll,
          border: Border.all(
            color: selected
                ? AppTheme.primaryColor.withValues(alpha: .45)
                : context.borderColor,
          ),
        ),
        child: Column(
          children: [
            Icon(icon,
                size: 20,
                color: selected
                    ? AppTheme.primaryColor
                    : context.textSecondary),
            const SizedBox(height: 5),
            Text(label,
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? AppTheme.primaryColor
                      : context.textPrimary,
                )),
          ],
        ),
      ),
    );
  }

  String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
