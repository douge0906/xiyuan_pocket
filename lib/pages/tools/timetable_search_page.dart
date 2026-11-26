import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/course_storage.dart';
import '../../services/timetable/timetable_api.dart';
import '../../services/timetable/timetable_models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';
import '../../widgets/empty_state_art.dart';
import '../../widgets/state_views.dart';
import 'timetable_class_page.dart';
import 'timetable_upload_page.dart';

/// 锡院在线课表 · 班级检索。
///
/// 这里只做一件事：**按班级找到同学上传、并且已经审核发布的课表**。
/// 教务实时抓取的入口仍在课表页的「从教务系统导入」里，两条路互不影响 ——
/// 在线库是「别人已经传过、有人核对过」的那部分，断网也能看。
///
/// 相对设计稿的取舍：
///  · 设计稿写了「学年学期 chip 点开 bottom sheet」，但本仓库 R8 明确禁用
///    `showModalBottomSheet`（全局统一用居中 Dialog），这里按仓库规矩做。
///  · 设计稿的「社区课表库 / 我的教务（实时）」分段控件已按要求删掉。
///  · 关键字过滤走本地（已加载的班级列表），不再打一次请求 —— 357 个班在
///    内存里过滤是零延迟的，打成请求反而要等。
class TimetableSearchPage extends StatefulWidget {
  const TimetableSearchPage({super.key, this.initialTerm});

  /// 进来时默认选中的学期。null = 用当前系统时间推。
  final TimetableTerm? initialTerm;

  @override
  State<TimetableSearchPage> createState() => _TimetableSearchPageState();
}

class _TimetableSearchPageState extends State<TimetableSearchPage> {
  final TextEditingController _searchCtl = TextEditingController();
  late TimetableTerm _term;

  bool _loading = true;
  String _error = '';

  /// 服务端回来的原始班级列表。筛选与关键字都在它上面做。
  List<TimetableClassSummary> _all = const [];
  List<TimetableClassSummary> _shown = const [];

  String? _jgmc;
  String? _zymc;
  String? _bj;

  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final (xnm, xqm) = CourseStorage.semesterArgsFor(now);
    _term = widget.initialTerm ?? TimetableTerm(xnm, xqm);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    final result = await TimetableApi.search(xnm: _term.xnm, xqm: _term.xqm);
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _loading = false;
        _error = result.message;
      });
      return;
    }
    final raw = result.listOf('classes');
    final parsed = <TimetableClassSummary>[];
    for (final item in raw) {
      final c = TimetableClassSummary.fromJson(item);
      if (c != null) parsed.add(c);
    }
    setState(() {
      _loading = false;
      _all = parsed;
      // 换了学期，上一学期选中的筛选条件可能已经不存在了，全部清掉。
      _jgmc = null;
      _zymc = null;
      _bj = null;
      _applyFilter();
    });
  }

  void _applyFilter() {
    final kw = _searchCtl.text.trim().toLowerCase();
    setState(() {
      _shown = _all.where((c) {
        if (_jgmc != null && c.jgmc != _jgmc) return false;
        if (_zymc != null && c.zymc != _zymc) return false;
        if (_bj != null && c.bj != _bj) return false;
        if (kw.isEmpty) return true;
        return c.bj.toLowerCase().contains(kw) ||
            c.zymc.toLowerCase().contains(kw) ||
            c.jgmc.toLowerCase().contains(kw);
      }).toList();
    });
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _applyFilter);
  }

  List<String> _distinct(String Function(TimetableClassSummary) pick) {
    final set = <String>{};
    for (final c in _all) {
      final v = pick(c);
      if (v.isNotEmpty) set.add(v);
    }
    final list = set.toList()..sort();
    return list;
  }

  /// 改上级筛选时清空下级 —— 保留了上级学院的筛选却让专业继续指向别的学院，
  /// 结果必然是空列表，用户会以为「这个学院没有课表」。
  Future<void> _pickFilter({
    required String title,
    required List<String> options,
    required String? current,
    required void Function(String?) apply,
  }) async {
    final picked = await showDialog<_FilterPick>(
      context: context,
      builder: (_) => _FilterDialog(title: title, options: options, current: current),
    );
    if (picked == null || !mounted) return;
    setState(() => apply(picked.value));
    _applyFilter();
  }

  Future<void> _pickTerm() async {
    final picked = await showDialog<TimetableTerm>(
      context: context,
      builder: (_) => _TermDialog(current: _term),
    );
    if (picked == null || !mounted) return;
    if (picked == _term) return;
    setState(() => _term = picked);
    await _load();
  }

  void _openClass(TimetableClassSummary c) {
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => TimetableClassPage(classKey: c.classKey, summary: c),
        ))
        .then((_) => _load());
  }

  Future<void> _openUpload() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => TimetableUploadPage(term: _term)),
    );
    if (created == true) await _load();
  }

  Future<void> _openMine() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TimetableMyUploadsPage()),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final published = _all.length;
    final totalVersions = _all.fold<int>(0, (s, c) => s + c.timetableCount);
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('锡院在线课表',
            style: TextStyle(fontSize: AppTheme.fontHeading, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: '我的上传',
            icon: const Icon(Icons.upload_file_rounded),
            onPressed: _openMine,
          ),
          IconButton(
            tooltip: '上传班级课表',
            icon: const Icon(Icons.add_rounded),
            onPressed: _openUpload,
          ),
        ],
      ),
      body: Column(
        children: [
          _searchBar(),
          _chipRow(),
          if (!_loading && _error.isEmpty) _countLine(published, totalVersions),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: TextField(
        controller: _searchCtl,
        onChanged: _onSearchChanged,
        textInputAction: TextInputAction.search,
        style: TextStyle(fontSize: AppTheme.fontBody, color: context.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜班名 / 专业 / 学院，例如：25安工',
          hintStyle: TextStyle(fontSize: AppTheme.fontBody, color: context.textTertiary),
          prefixIcon: Icon(Icons.search_rounded, size: 20, color: context.textTertiary),
          suffixIcon: _searchCtl.text.isEmpty
              ? null
              : IconButton(
                  icon: Icon(Icons.close_rounded, size: 18, color: context.textTertiary),
                  onPressed: () {
                    _searchCtl.clear();
                    _applyFilter();
                  },
                ),
          filled: true,
          fillColor: context.cardColor,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            borderSide: BorderSide(color: context.borderColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            borderSide: BorderSide(color: context.borderColor),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            borderSide: BorderSide(color: AppTheme.primaryColor),
          ),
        ),
      ),
    );
  }

  Widget _chipRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          _chip(
            label: _term.label,
            active: true,
            trailing: Icons.expand_more_rounded,
            onTap: _pickTerm,
          ),
          _chip(
            label: _jgmc ?? '学院',
            active: _jgmc != null,
            trailing: _jgmc == null ? Icons.expand_more_rounded : Icons.close_rounded,
            onTap: () => _pickFilter(
              title: '选择学院',
              options: _distinct((c) => c.jgmc),
              current: _jgmc,
              apply: (v) {
                _jgmc = v;
                _zymc = null;
                _bj = null;
              },
            ),
          ),
          _chip(
            label: _zymc ?? '专业',
            active: _zymc != null,
            trailing: _zymc == null ? Icons.expand_more_rounded : Icons.close_rounded,
            onTap: () {
              final pool = _jgmc == null
                  ? _all
                  : _all.where((c) => c.jgmc == _jgmc).toList();
              final set = <String>{};
              for (final c in pool) {
                if (c.zymc.isNotEmpty) set.add(c.zymc);
              }
              final list = set.toList()..sort();
              _pickFilter(
                title: '选择专业',
                options: list,
                current: _zymc,
                apply: (v) {
                  _zymc = v;
                  _bj = null;
                },
              );
            },
          ),
          _chip(
            label: _bj ?? '班级',
            active: _bj != null,
            trailing: _bj == null ? Icons.expand_more_rounded : Icons.close_rounded,
            onTap: () {
              final pool = _all.where((c) {
                if (_jgmc != null && c.jgmc != _jgmc) return false;
                if (_zymc != null && c.zymc != _zymc) return false;
                return true;
              });
              final list = pool.map((c) => c.bj).toSet().toList()..sort();
              _pickFilter(
                title: '选择班级',
                options: list,
                current: _bj,
                apply: (v) => _bj = v,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _chip({
    required String label,
    required bool active,
    required IconData trailing,
    required VoidCallback onTap,
  }) {
    final color = active ? AppTheme.primaryColor : context.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active
                ? AppTheme.primaryColor.withValues(alpha: .08)
                : context.subtleFill,
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            border: Border.all(color: context.borderColor),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label,
                style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    color: active ? AppTheme.primaryColor : color)),
            const SizedBox(width: 2),
            Icon(trailing, size: 14, color: active ? AppTheme.primaryColor : color),
          ]),
        ),
      ),
    );
  }

  Widget _countLine(int classes, int versions) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '共 $classes 个班级　已审核发布 $versions 份课表',
          style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          ErrorState(message: _error, onRetry: _load),
        ],
      );
    }
    if (_shown.isEmpty) return _empty();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: _shown.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          if (i == _shown.length) return _uploadHint();
          return _classCard(_shown[i]);
        },
      ),
    );
  }

  /// 四种空态分开说，因为用户接下来该做的事完全不同。
  Widget _empty() {
    final kw = _searchCtl.text.trim();
    final hasFilter = _jgmc != null || _zymc != null || _bj != null;

    String message;
    String hint;
    VoidCallback primary;
    String primaryLabel;
    VoidCallback? secondary;
    String? secondaryLabel;

    if (kw.isNotEmpty) {
      message = '没有找到匹配「$kw」的班级';
      hint = '换一个关键词，或者清空筛选条件看看';
      primary = () {
        _searchCtl.clear();
        _applyFilter();
      };
      primaryLabel = '清空关键字';
      secondary = hasFilter
          ? () {
              setState(() {
                _jgmc = null;
                _zymc = null;
                _bj = null;
              });
              _applyFilter();
            }
          : null;
      secondaryLabel = hasFilter ? '重置筛选' : null;
    } else if (hasFilter) {
      message = '该筛选条件下还没有课表';
      hint = '你可以先上传一份，审核通过后同学就能查到';
      primary = _openUpload;
      primaryLabel = '上传班级课表';
      secondary = _load;
      secondaryLabel = '重新加载';
    } else {
      message = '这个学期还没有人上传课表';
      hint = '上传一份，审核通过后同学们就能检索到';
      primary = _openUpload;
      primaryLabel = '上传班级课表';
      secondary = _load;
      secondaryLabel = '重新加载';
    }

    return ListView(
      children: [
        const SizedBox(height: 60),
        EmptyState(
          message: message,
          hint: hint,
          icon: Icons.school_outlined,
          artVariant: EmptyArtVariant.search,
        ),
        const SizedBox(height: 8),
        Center(
          child: FilledButton(
            onPressed: primary,
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
            ),
            child: Text(primaryLabel),
          ),
        ),
        if (secondary != null && secondaryLabel != null) ...[
          const SizedBox(height: 4),
          Center(
            child: TextButton(
              onPressed: secondary,
              child: Text(secondaryLabel,
                  style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
            ),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _classCard(TimetableClassSummary c) {
    final consistencyColor = c.consistency.allSame
        ? context.successColor
        : (c.consistency.hasBaseline ? context.warningColor : context.textTertiary);
    return AppCard(
      radius: AppTheme.radiusMd,
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: () => _openClass(c),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(c.bj,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppTheme.fontTitle,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary)),
                ),
                if (c.njdmId.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text('${c.njdmId} 级',
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption, color: context.textTertiary)),
                  ),
                Icon(Icons.chevron_right_rounded, size: 18, color: context.textTertiary),
              ]),
              if (c.orgLine.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(c.orgLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall, color: context.textSecondary)),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _pill('${c.timetableCount} 份课表',
                      AppTheme.primaryColor, AppTheme.primaryColor.withValues(alpha: .10)),
                  Text('${c.courseCount} 门 · ${c.consistency.label}',
                      style: TextStyle(fontSize: AppTheme.fontCaption, color: consistencyColor)),
                  if (c.latestUploadedAt.isNotEmpty)
                    Text(timetableRelativeTime(c.latestUploadedAt),
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption, color: context.textTertiary)),
                  if (c.latestUploaderName.isNotEmpty)
                    Text(c.latestUploaderName,
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption, color: context.textTertiary)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill(String text, Color fg, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
      child: Text(text,
          style: TextStyle(fontSize: AppTheme.fontCaption, color: fg, fontWeight: FontWeight.w600)),
    );
  }

  Widget _uploadHint() {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Text(
        '没找到你班？你也可以上传本班的课表，审核通过后同学们就能检索到。',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary),
      ),
    );
  }
}

/// 筛选对话框的一次选择结果。`value == null` 表示选了「全部」。
class _FilterPick {
  const _FilterPick(this.value);
  final String? value;
}

class _FilterDialog extends StatelessWidget {
  const _FilterDialog({required this.title, required this.options, required this.current});

  final String title;
  final List<String> options;
  final String? current;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(color: context.borderColor),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      title: Row(children: [
        Expanded(
          child: Text(title,
              style: const TextStyle(fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
        ),
        IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ]),
      content: SizedBox(
        width: double.maxFinite,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: ListView(
            shrinkWrap: true,
            children: [
              _row(context, '全部', null),
              for (final o in options) _row(context, o, o),
            ],
          ),
        ),
      ),
      actions: const [],
    );
  }

  Widget _row(BuildContext context, String label, String? value) {
    final selected = current == value;
    return InkWell(
      onTap: () => Navigator.of(context).pop(_FilterPick(value)),
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(children: [
          Expanded(
            child: Text(label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  color: selected ? AppTheme.primaryColor : context.textPrimary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                )),
          ),
          if (selected)
            Icon(Icons.check_rounded, size: 18, color: AppTheme.primaryColor),
        ]),
      ),
    );
  }
}

/// 选学年学期。三个学期是服务端硬约束（xqm 只能 3 / 12 / 16）。
class _TermDialog extends StatefulWidget {
  const _TermDialog({required this.current});

  final TimetableTerm current;

  @override
  State<_TermDialog> createState() => _TermDialogState();
}

class _TermDialogState extends State<_TermDialog> {
  late final List<TimetableTerm> _terms;

  @override
  void initState() {
    super.initState();
    // 从「本学期的上一学期」到「下下学期」都给出来 —— 用户常常要查上一学期
    // 的课表（补考、重修时对照），也需要提前看下学期的。
    final now = DateTime.now();
    final (xnm, xqm) = CourseStorage.semesterArgsFor(now);
    final current = TimetableTerm(xnm, xqm);
    final prev = xqm == '3'
        ? TimetableTerm('${int.tryParse(xnm.split('-').first)! - 1}-${int.tryParse(xnm.split('-').first)}', '12')
        : TimetableTerm(xnm, '3');
    _terms = [prev, current, current.next, current.next.next];
    // 去重：跨年推演可能撞车。
    final seen = <TimetableTerm>{};
    _terms.removeWhere((t) => !seen.add(t));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(color: context.borderColor),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      title: Row(children: [
        const Expanded(
          child: Text('选择学年学期',
              style: TextStyle(fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
        ),
        IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ]),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final t in _terms)
              InkWell(
                onTap: () => Navigator.of(context).pop(t),
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Row(children: [
                    Expanded(
                      child: Text(t.label,
                          style: TextStyle(
                            fontSize: AppTheme.fontBody,
                            color: t == widget.current
                                ? AppTheme.primaryColor
                                : context.textPrimary,
                            fontWeight: t == widget.current
                                ? FontWeight.w600
                                : FontWeight.w400,
                          )),
                    ),
                    if (t == widget.current)
                      Icon(Icons.check_rounded, size: 18, color: AppTheme.primaryColor),
                  ]),
                ),
              ),
          ],
        ),
      ),
      actions: const [],
    );
  }
}
