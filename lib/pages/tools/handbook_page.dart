import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/handbook_repository.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';

/// 「锡院学生手册」——服务页入口。
///
/// 定位（依设计方案）：**主体是手册原文 + 规则来源 + 覆盖广度**。
/// 段落逐字照录、100 张表行列不拆散、28 处来源脚注原样保留、附录 E
/// （付印前内部核验清单）不面向学生展示。关键词「一键查」只是附带的
/// 定位手段，命中后一律回跳到原文章节，不改写、不生成答案、不拨号。
///
/// 四个界面：
/// - [HandbookPage]           手册目录（屏 1，主体入口）
/// - [HandbookChapterPage]    章节原文照录（屏 2）
/// - [HandbookSourcesPage]    来源与覆盖（屏 3）
/// - [HandbookSearchPage]     附带一键查（屏 4）
class HandbookPage extends StatefulWidget {
  const HandbookPage({super.key});

  @override
  State<HandbookPage> createState() => _HandbookPageState();
}

class _HandbookPageState extends State<HandbookPage> {
  HandbookData? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await HandbookRepository.instance.load();
      if (!mounted) return;
      setState(() => _data = d);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '手册数据载入失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('锡院学生手册',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: context.cardColor,
        foregroundColor:
            context.isDark ? Colors.white : AppTheme.primaryColor,
        elevation: 0,
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final err = _error;
    if (err != null) return _centered(context, Icons.error_outline_rounded, err);
    final d = _data;
    if (d == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return _home(context, d);
  }

  Widget _centered(BuildContext context, IconData icon, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: context.textTertiary),
            const SizedBox(height: AppTheme.gapMd),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: AppTheme.fontBody, color: context.textSecondary)),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 屏 1：手册目录（主体入口）
  // ---------------------------------------------------------------------------
  Widget _home(BuildContext context, HandbookData d) {
    final cover = d.cover;
    final basis = cover.firstWhere(
      (t) => t.contains('内容依据'),
      orElse: () => '内容依据：学校官网及各部门公开信息',
    );
    final chapters = d.chapters.where((c) => !c.isAppendix).toList();
    final appendices = d.chapters.where((c) => c.isAppendix && !c.hidden).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppTheme.gapLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 版本 / 内容依据（顶部总览压缩：去掉覆盖范围整段与版本后缀）
          AppCard(
            radius: AppTheme.radiusLg,
            bordered: true,
            padding: const EdgeInsets.all(AppTheme.gapMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.menu_book_rounded,
                        size: 18, color: AppTheme.primaryColor),
                    const SizedBox(width: AppTheme.gapSm),
                    Text('2026 版',
                        style: TextStyle(
                            fontSize: AppTheme.fontTitle,
                            fontWeight: FontWeight.bold,
                            color: context.textPrimary)),
                  ],
                ),
                const SizedBox(height: AppTheme.gapSm),
                Text(basis.trim(),
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall,
                        color: context.textSecondary,
                        height: AppTheme.lineBody)),
                const SizedBox(height: AppTheme.gapSm),
                Wrap(
                  spacing: AppTheme.gapSm,
                  runSpacing: AppTheme.gapXs,
                  children: [
                    _statChip(context, '${d.chapterCount} 章 · ${d.appendixCount} 附录'),
                    _statChip(context, '${d.sectionCount} 节 · ${d.tableCount} 张表'),
                    _statChip(context, '${d.sourceFootnoteCount} 处来源'),
                    _statChip(context, '全文照录'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.gapMd),

          // 附带的关键词一键查入口
          _entryCard(
            context,
            icon: Icons.search_rounded,
            title: '附：关键词一键查',
            subtitle: '本地离线检索 · 命中后回跳手册原文',
            onTap: () => _push(context, HandbookSearchPage(data: d)),
          ),
          const SizedBox(height: AppTheme.gapMd),

          // 来源与覆盖入口
          _entryCard(
            context,
            icon: Icons.verified_outlined,
            title: '来源与覆盖',
            subtitle: '使用约定 · 部门来源 · 规章制度目录',
            onTap: () => _push(context, HandbookSourcesPage(data: d)),
          ),
          const SizedBox(height: AppTheme.gapLg),

          _sectionLabel(context, '正文 · ${chapters.length} 章'),
          const SizedBox(height: AppTheme.gapSm),
          for (var i = 0; i < chapters.length; i++)
            _chapterTile(context, d, chapters[i], '${i + 1}'),
          const SizedBox(height: AppTheme.gapLg),

          _sectionLabel(context, '附录 · ${appendices.length} 个'),
          const SizedBox(height: AppTheme.gapSm),
          Wrap(
            spacing: AppTheme.gapSm,
            runSpacing: AppTheme.gapSm,
            children: [
              for (final c in appendices)
                ActionChip(
                  label: Text(c.title,
                      style: TextStyle(
                          fontSize: AppTheme.fontSmall,
                          color: context.textPrimary)),
                  backgroundColor: context.subtleFill,
                  side: BorderSide(color: context.borderColor),
                  onPressed: () =>
                      _push(context, HandbookChapterPage(chapter: c)),
                ),
            ],
          ),
          const SizedBox(height: AppTheme.gapLg),
          Text(
            '本手册为 2026 版内容快照；金额、名额、时间类条款以当年通知为准。',
            style: TextStyle(
                fontSize: AppTheme.fontCaption,
                color: context.textTertiary,
                height: AppTheme.lineBody),
          ),
        ],
      ),
    );
  }

  Widget _statChip(BuildContext context, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.gapSm, vertical: AppTheme.gapXs),
      decoration: BoxDecoration(
        color: context.subtleFill,
        borderRadius: AppTheme.radiusSmAll,
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: AppTheme.fontCaption,
              color: context.textSecondary,
              fontWeight: FontWeight.w600)),
    );
  }

  Widget _entryCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return AppCard(
      radius: AppTheme.radiusLg,
      bordered: true,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.gapLg),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: context.subtleFill,
                  borderRadius: AppTheme.radiusSmAll,
                ),
                child: Icon(icon, size: 20, color: AppTheme.primaryColor),
              ),
              const SizedBox(width: AppTheme.gapMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: AppTheme.fontTitle,
                            fontWeight: FontWeight.bold,
                            color: context.textPrimary)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: AppTheme.fontSmall,
                            color: context.textSecondary)),
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

  Widget _chapterTile(
      BuildContext context, HandbookData d, HandbookChapter c, String no) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.gapSm),
      child: AppCard(
        radius: AppTheme.radiusMd,
        bordered: true,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _push(context, HandbookChapterPage(chapter: c)),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.gapMd, vertical: AppTheme.gapMd),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: context.subtleFill,
                    borderRadius: AppTheme.radiusSmAll,
                  ),
                  child: Text(no,
                      style: TextStyle(
                          fontSize: AppTheme.fontSmall,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.primaryColor)),
                ),
                const SizedBox(width: AppTheme.gapMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.title,
                          style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              fontWeight: FontWeight.w600,
                              color: context.textPrimary)),
                      const SizedBox(height: 2),
                      Text(
                          '${c.sectionCount} 节 · ${c.tableCount} 张表',
                          style: TextStyle(
                              fontSize: AppTheme.fontCaption,
                              color: context.textTertiary)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    size: 18, color: context.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String title) {
    return Text(title,
        style: TextStyle(
            fontSize: AppTheme.fontSmall,
            fontWeight: FontWeight.bold,
            color: context.textSecondary,
            letterSpacing: 0.3));
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }
}

// ---------------------------------------------------------------------------
// 屏 2：章节原文照录
// ---------------------------------------------------------------------------
class HandbookChapterPage extends StatefulWidget {
  const HandbookChapterPage({
    super.key,
    required this.chapter,
    this.initialSection,
  });

  final HandbookChapter chapter;
  final int? initialSection;

  @override
  State<HandbookChapterPage> createState() => _HandbookChapterPageState();
}

class _HandbookChapterPageState extends State<HandbookChapterPage> {
  final Map<int, GlobalKey> _sectionKeys = {};

  @override
  void initState() {
    super.initState();
    final si = widget.initialSection;
    if (si != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final k = _sectionKeys[si];
        if (k?.currentContext != null) {
          Scrollable.ensureVisible(
            k!.currentContext!,
            duration: const Duration(milliseconds: 300),
            alignment: 0.05,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final chapter = widget.chapter;
    final titled = <int>[];
    for (var i = 0; i < chapter.sections.length; i++) {
      if (chapter.sections[i].title.isNotEmpty) {
        _sectionKeys.putIfAbsent(i, () => GlobalKey());
        titled.add(i);
      }
    }

    final body = <Widget>[];

    // 章内锚点 chip（跳转小节）
    if (titled.length > 1) {
      body.add(Padding(
        padding: const EdgeInsets.only(bottom: AppTheme.gapMd),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final si in titled)
                Padding(
                  padding: const EdgeInsets.only(right: AppTheme.gapSm),
                  child: ActionChip(
                    label: Text(chapter.sections[si].title,
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption,
                            color: context.textPrimary)),
                    backgroundColor: context.subtleFill,
                    side: BorderSide(color: context.borderColor),
                    onPressed: () {
                      final k = _sectionKeys[si];
                      if (k?.currentContext != null) {
                        Scrollable.ensureVisible(
                          k!.currentContext!,
                          duration: const Duration(milliseconds: 300),
                          alignment: 0.05,
                        );
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
      ));
    }

    for (var si = 0; si < chapter.sections.length; si++) {
      final s = chapter.sections[si];
      if (s.title.isNotEmpty) {
        body.add(Container(
          key: _sectionKeys[si],
          padding: const EdgeInsets.only(
              top: AppTheme.gapSm, bottom: AppTheme.gapSm),
          child: Row(
            children: [
              Container(width: 3, height: 16, color: AppTheme.primaryColor),
              const SizedBox(width: AppTheme.gapSm),
              Expanded(
                child: Text(s.title,
                    style: TextStyle(
                        fontSize: AppTheme.fontTitle,
                        fontWeight: FontWeight.bold,
                        color: context.textPrimary)),
              ),
            ],
          ),
        ));
      }
      for (final b in s.blocks) {
        body.add(HandbookBlockView(block: b));
      }
    }
    body.add(const SizedBox(height: AppTheme.gapXl));

    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: Text(chapter.title,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: context.cardColor,
        foregroundColor:
            context.isDark ? Colors.white : AppTheme.primaryColor,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppTheme.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: body,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 屏 3：来源与覆盖
// ---------------------------------------------------------------------------
class HandbookSourcesPage extends StatelessWidget {
  const HandbookSourcesPage({super.key, required this.data});

  final HandbookData data;

  @override
  Widget build(BuildContext context) {
    final agreement = data.sectionParagraphs('一、', '1.3');
    final dChapter = data.chapter('附录 D');
    final cChapter = data.chapter('附录 C');

    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('来源与覆盖',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: context.cardColor,
        foregroundColor:
            context.isDark ? Colors.white : AppTheme.primaryColor,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppTheme.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _label(context, '使用约定（原文）'),
            const SizedBox(height: AppTheme.gapSm),
            AppCard(
              radius: AppTheme.radiusLg,
              bordered: true,
              padding: const EdgeInsets.all(AppTheme.gapLg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final p in agreement)
                    Padding(
                      padding:
                          const EdgeInsets.only(bottom: AppTheme.gapSm),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.check_circle_outline_rounded,
                              size: 14, color: context.successColor),
                          const SizedBox(width: AppTheme.gapSm),
                          Expanded(
                            child: Text(p,
                                style: TextStyle(
                                    fontSize: AppTheme.fontBody,
                                    color: context.textPrimary,
                                    height: AppTheme.lineBody)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppTheme.gapMd),

            // 来源统计
            Wrap(
              spacing: AppTheme.gapSm,
              runSpacing: AppTheme.gapSm,
              children: [
                _stat(context, '${data.sourceFootnoteCount} 处来源脚注'),
                _stat(context, '${data.chapterCount} 章正文'),
                _stat(context, '${data.tableCount} 张原文表'),
                _stat(context, '2026.11 核验'),
              ],
            ),
            const SizedBox(height: AppTheme.gapLg),

            if (dChapter != null) ...[
              _label(context, '附录 D · 信息来源与核验说明（原文表）'),
              const SizedBox(height: AppTheme.gapSm),
              for (final s in dChapter.sections)
                for (final b in s.blocks)
                  if (b.kind == 'tbl') HandbookBlockView(block: b),
              const SizedBox(height: AppTheme.gapLg),
            ],
            if (cChapter != null) ...[
              _label(context, '附录 C · 规章制度目录（原文表）'),
              const SizedBox(height: AppTheme.gapSm),
              for (final s in cChapter.sections)
                for (final b in s.blocks)
                  if (b.kind == 'tbl') HandbookBlockView(block: b),
              const SizedBox(height: AppTheme.gapLg),
            ],

            _label(context, '覆盖主题 · ${data.visibleChapters.length} 类'),
            const SizedBox(height: AppTheme.gapSm),
            Wrap(
              spacing: AppTheme.gapSm,
              runSpacing: AppTheme.gapSm,
              children: [
                for (final c in data.visibleChapters)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppTheme.gapSm,
                        vertical: AppTheme.gapXs),
                    decoration: BoxDecoration(
                      color: context.subtleFill,
                      borderRadius: AppTheme.radiusSmAll,
                    ),
                    child: Text(c.title,
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption,
                            color: context.textSecondary)),
                  ),
              ],
            ),
            const SizedBox(height: AppTheme.gapLg),
            Text(
              '附录 E 为付印前内部核验清单，不面向学生展示；'
              '官网未给出的数值不臆造，保留「待核验」标记。',
              style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: context.textTertiary,
                  height: AppTheme.lineBody),
            ),
            const SizedBox(height: AppTheme.gapXl),
          ],
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String title) {
    return Text(title,
        style: TextStyle(
            fontSize: AppTheme.fontSmall,
            fontWeight: FontWeight.bold,
            color: context.textSecondary));
  }

  Widget _stat(BuildContext context, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.gapMd, vertical: AppTheme.gapSm),
      decoration: BoxDecoration(
        color: context.subtleFill,
        borderRadius: AppTheme.radiusSmAll,
        border: Border.all(color: context.borderColor),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: AppTheme.fontSmall,
              fontWeight: FontWeight.w600,
              color: context.textPrimary)),
    );
  }
}

// ---------------------------------------------------------------------------
// 屏 4：附带一键查（关键词检索）
// ---------------------------------------------------------------------------
class HandbookSearchPage extends StatefulWidget {
  const HandbookSearchPage({super.key, required this.data});

  final HandbookData data;

  @override
  State<HandbookSearchPage> createState() => _HandbookSearchPageState();
}

class _HandbookSearchPageState extends State<HandbookSearchPage> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

  static const List<String> _hotWords = [
    '奖学金',
    '转专业',
    '校园卡',
    '申诉',
    '图书馆',
    '报修',
    '四级',
    '学费',
  ];

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      setState(() => _query = v.trim());
    });
  }

  void _submit(String v) {
    _debounce?.cancel();
    setState(() => _query = v.trim());
  }

  void _run(String v) {
    _controller.text = v;
    _submit(v);
  }

  @override
  Widget build(BuildContext context) {
    final q = _query;
    final hits = q.isEmpty ? <HandbookHit>[] : widget.data.search(q);

    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('关键词一键查',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: context.cardColor,
        foregroundColor:
            context.isDark ? Colors.white : AppTheme.primaryColor,
        elevation: 0,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppTheme.gapLg),
            child: TextField(
              controller: _controller,
              onChanged: _onChanged,
              onSubmitted: _submit,
              textInputAction: TextInputAction.search,
              style: TextStyle(
                  fontSize: AppTheme.fontBody, color: context.textPrimary),
              decoration: InputDecoration(
                hintText: '输入关键词，如「奖学金」「转专业」「425」',
                hintStyle: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    color: context.textTertiary),
                prefixIcon: Icon(Icons.search_rounded,
                    size: 20, color: context.textTertiary),
                isDense: true,
                filled: true,
                fillColor: context.surfaceColor,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: AppTheme.gapMd),
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
          Expanded(child: _results(context, q, hits)),
        ],
      ),
    );
  }

  Widget _results(BuildContext context, String q, List<HandbookHit> hits) {
    if (q.isEmpty) {
      return _zeroState(
        context,
        icon: Icons.manage_search_rounded,
        title: '关键词一键查（附带功能）',
        subtitle: '主体是按章浏览的手册原文；这里只帮你快速定位到原文章节。',
      );
    }
    if (hits.isEmpty) {
      return _zeroState(
        context,
        icon: Icons.search_off_rounded,
        title: '没有找到相关内容',
        subtitle: '换个关键词试试；检索仅覆盖 2026 版手册已有内容。',
        showHot: true,
      );
    }

    final best = hits.first;
    final rest = hits.length > 1 ? hits.sublist(1) : <HandbookHit>[];

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.gapLg, 0, AppTheme.gapLg, AppTheme.gapXl),
      children: [
        Text('最佳答案 · 命中原文',
            style: TextStyle(
                fontSize: AppTheme.fontSmall,
                fontWeight: FontWeight.bold,
                color: context.textSecondary)),
        const SizedBox(height: AppTheme.gapSm),
        _bestCard(context, best),
        if (rest.isNotEmpty) ...[
          const SizedBox(height: AppTheme.gapLg),
          Text('相关结果 · ${rest.length} 条',
              style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  fontWeight: FontWeight.bold,
                  color: context.textSecondary)),
          const SizedBox(height: AppTheme.gapSm),
          for (final h in rest.take(20)) _hitTile(context, h),
        ],
      ],
    );
  }

  Widget _bestCard(BuildContext context, HandbookHit h) {
    return AppCard(
      radius: AppTheme.radiusLg,
      bordered: true,
      padding: const EdgeInsets.all(AppTheme.gapLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _chapterLine(context, h),
          const SizedBox(height: AppTheme.gapSm),
          RichText(
            text: TextSpan(
              children: _highlightSpans(
                _snippet(h.text, h.terms),
                h.terms,
                TextStyle(
                    fontSize: AppTheme.fontBody,
                    color: context.textPrimary,
                    height: AppTheme.lineBody),
                TextStyle(
                    fontSize: AppTheme.fontBody,
                    color: context.textPrimary,
                    height: AppTheme.lineBody,
                    backgroundColor: context.warningColor.withValues(alpha: 0.18),
                    fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: AppTheme.gapMd),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _jump(context, h),
              icon: const Icon(Icons.menu_book_rounded, size: 16),
              label: const Text('查看章节原文'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hitTile(BuildContext context, HandbookHit h) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.gapSm),
      child: AppCard(
        radius: AppTheme.radiusMd,
        bordered: true,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _jump(context, h),
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.gapMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _chapterLine(context, h),
                const SizedBox(height: AppTheme.gapXs),
                RichText(
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    children: _highlightSpans(
                      _snippet(h.text, h.terms),
                      h.terms,
                      TextStyle(
                          fontSize: AppTheme.fontSmall,
                          color: context.textSecondary,
                          height: AppTheme.lineBody),
                      TextStyle(
                          fontSize: AppTheme.fontSmall,
                          color: context.textPrimary,
                          height: AppTheme.lineBody,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chapterLine(BuildContext context, HandbookHit h) {
    final parts = <String>[
      h.chapterTitle,
      if (h.sectionTitle.isNotEmpty) h.sectionTitle,
    ];
    return Row(
      children: [
        Icon(Icons.place_outlined, size: 13, color: context.infoColor),
        const SizedBox(width: AppTheme.gapXs),
        Expanded(
          child: Text(parts.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: context.textTertiary)),
        ),
        if (h.isSource)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: context.subtleFill,
              borderRadius: AppTheme.radiusSmAll,
            ),
            child: Text('来源',
                style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    color: context.successColor)),
          ),
      ],
    );
  }

  Widget _zeroState(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    bool showHot = false,
  }) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppTheme.gapLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: AppTheme.gapXl),
          Icon(icon, size: 44, color: context.textTertiary),
          const SizedBox(height: AppTheme.gapMd),
          Text(title,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: AppTheme.fontTitle,
                  fontWeight: FontWeight.bold,
                  color: context.textPrimary)),
          const SizedBox(height: AppTheme.gapSm),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  color: context.textSecondary,
                  height: AppTheme.lineBody)),
          const SizedBox(height: AppTheme.gapLg),
          Text('热门词',
              style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  fontWeight: FontWeight.bold,
                  color: context.textSecondary)),
          const SizedBox(height: AppTheme.gapSm),
          Wrap(
            spacing: AppTheme.gapSm,
            runSpacing: AppTheme.gapSm,
            children: [
              for (final w in _hotWords)
                ActionChip(
                  label: Text(w,
                      style: TextStyle(
                          fontSize: AppTheme.fontSmall,
                          color: context.textPrimary)),
                  backgroundColor: context.subtleFill,
                  side: BorderSide(color: context.borderColor),
                  onPressed: () => _run(w),
                ),
            ],
          ),
          const SizedBox(height: AppTheme.gapLg),
          Text('覆盖 ${widget.data.visibleChapters.length} 个章节 / 附录，'
              '检索在本地完成，不上传输入。',
              style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: context.textTertiary,
                  height: AppTheme.lineBody)),
        ],
      ),
    );
  }

  void _jump(BuildContext context, HandbookHit h) {
    final chapter = widget.data.chapters[h.chapterIndex];
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => HandbookChapterPage(
        chapter: chapter,
        initialSection: h.sectionIndex,
      ),
    ));
  }
}

// ---------------------------------------------------------------------------
// 共享：原文块渲染（段落逐字 / 表格行列不拆 / 来源脚注原样）
// ---------------------------------------------------------------------------
class HandbookBlockView extends StatelessWidget {
  const HandbookBlockView({super.key, required this.block});

  final HandbookBlock block;

  @override
  Widget build(BuildContext context) {
    if (block.isSource) return _sourceCard(context);
    if (block.kind == 'tbl') return _table(context);
    final t = block.text.trim();
    if (t.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.gapMd),
      child: SelectableText(
        t,
        style: TextStyle(
          fontSize: AppTheme.fontBody,
          color: context.textPrimary,
          height: AppTheme.lineBody,
        ),
      ),
    );
  }

  Widget _sourceCard(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: AppTheme.gapMd),
      padding: const EdgeInsets.all(AppTheme.gapMd),
      decoration: BoxDecoration(
        color: context.subtleFill,
        borderRadius: AppTheme.radiusSmAll,
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified_outlined,
                  size: 14, color: context.successColor),
              const SizedBox(width: 6),
              Text('来源 · 原文照录',
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      fontWeight: FontWeight.bold,
                      color: context.textSecondary)),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            block.text.trim(),
            style: TextStyle(
              fontSize: AppTheme.fontSmall,
              color: context.textPrimary,
              height: AppTheme.lineBody,
            ),
          ),
        ],
      ),
    );
  }

  Widget _table(BuildContext context) {
    final rows = block.rows;
    if (rows.isEmpty) return const SizedBox.shrink();
    final cols =
        rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);

    // 表格必须在「有界宽度」里排版：横向 SingleChildScrollView 会给子级
    // 无限宽度约束，Table 的 FlexColumnWidth 在无限宽度下会报错。
    // 这里用 LayoutBuilder 取到页面可用宽度，再给 Table 一个确定的宽度；
    // 列多到放不下时才横向滚动，行列始终对齐、不拆散。
    return LayoutBuilder(
      builder: (context, constraints) {
        final minWidth = cols * 110.0;
        final available = constraints.maxWidth;
        final width = available.isFinite
            ? (available < minWidth ? minWidth : available)
            : minWidth;
        return Padding(
          padding: const EdgeInsets.only(bottom: AppTheme.gapMd),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: Table(
                defaultColumnWidth: const FlexColumnWidth(1.0),
                border: TableBorder.all(
                  color: context.borderColor,
                  width: 1,
                  borderRadius: AppTheme.radiusSmAll,
                ),
                children: [
                  for (var ri = 0; ri < rows.length; ri++)
                    TableRow(
                      decoration: BoxDecoration(
                        color: ri == 0 ? context.subtleFill : null,
                      ),
                      children: [
                        for (var ci = 0; ci < cols; ci++)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            child: SelectableText(
                              ci < rows[ri].length ? rows[ri][ci] : '',
                              style: TextStyle(
                                fontSize: AppTheme.fontSmall,
                                color: context.textPrimary,
                                height: 1.4,
                                fontWeight: ri == 0 ? FontWeight.w600 : null,
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 检索片段高亮
// ---------------------------------------------------------------------------
String _snippet(String text, List<String> terms) {
  final flat = text.replaceAll('\n', ' ').trim();
  if (flat.length <= 140) return flat;
  final lower = flat.toLowerCase();
  int first = -1;
  for (final t in terms) {
    if (t.isEmpty) continue;
    final i = lower.indexOf(t);
    if (i >= 0 && (first < 0 || i < first)) first = i;
  }
  if (first < 0) return '${flat.substring(0, 140)}…';
  final start = first > 30 ? first - 30 : 0;
  final end = start + 140 < flat.length ? start + 140 : flat.length;
  return '${start > 0 ? '…' : ''}${flat.substring(start, end)}'
      '${end < flat.length ? '…' : ''}';
}

List<InlineSpan> _highlightSpans(
  String text,
  List<String> terms,
  TextStyle base,
  TextStyle hit,
) {
  final lower = text.toLowerCase();
  final marks = <List<int>>[];
  for (final t in terms) {
    if (t.isEmpty) continue;
    int start = 0;
    while (true) {
      final i = lower.indexOf(t, start);
      if (i < 0) break;
      marks.add([i, i + t.length]);
      start = i + t.length;
    }
  }
  if (marks.isEmpty) return [TextSpan(text: text, style: base)];
  marks.sort((a, b) => a[0].compareTo(b[0]));
  final merged = <List<int>>[];
  for (final m in marks) {
    if (merged.isNotEmpty && m[0] <= merged.last[1]) {
      if (m[1] > merged.last[1]) merged.last[1] = m[1];
    } else {
      merged.add([m[0], m[1]]);
    }
  }
  final spans = <InlineSpan>[];
  var cur = 0;
  for (final m in merged) {
    if (m[0] > cur) {
      spans.add(TextSpan(text: text.substring(cur, m[0]), style: base));
    }
    spans.add(TextSpan(text: text.substring(m[0], m[1]), style: hit));
    cur = m[1];
  }
  if (cur < text.length) {
    spans.add(TextSpan(text: text.substring(cur), style: base));
  }
  return spans;
}
