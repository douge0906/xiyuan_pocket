import 'dart:async';

import 'package:flutter/material.dart';
import '../../widgets/empty_state_art.dart';
import '../../widgets/state_views.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/api_service.dart';
import '../../providers/user_config_provider.dart';
import '../../models/grade_stats.dart';
import '../../providers/grade_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/loading_overlay.dart';
import '../../widgets/site_links.dart';
import '../../widgets/app_card.dart';
import '../../widgets/semester_picker.dart';

/// 成绩查询（v2.4.5 起与「考试安排」彻底分开，各自独立页面）。
///
/// - 不再要求输入账密：直接使用「用户页已绑定的统一认证账号」，
///   由客户端去教务系统抓取。
/// - 推送链接 likewise 借用已绑定的推送链接，页面不再暴露该输入项。
/// - 界面刻意保持清爽：只有「账号一行 + 一个大按钮 + 结果」，不使用小字说明。
class GradeQueryPage extends ConsumerStatefulWidget {
  const GradeQueryPage({super.key});

  @override
  ConsumerState<GradeQueryPage> createState() =>
      _GradeQueryPageState();
}

class _GradeQueryPageState extends ConsumerState<GradeQueryPage> {
  bool _checking = true;
  bool _loadingCache = true;
  bool _credentialBound = false;

  bool _querying = false;
  int _seconds = 0;
  Timer? _timer;

  String? _message;

  /// 是否展开「全部 / 选修 / 学年」细账（2026-11-04 用户 m19892 #3）。
  ///
  /// 默认关：评奖评优只看必修，先把必修的那两个数摆出来；
  /// 想核对总和与选修时点一下展开。
  bool _showAllStats = false;

  /// 当前选中的学期（2026-11-04 用户 m19892 #1）。
  ///
  /// 空串 = 全部学期。用户原话：「成绩页面选择器 建议把这一块修改为
  /// 按时间排序 类似待办里的滚动选择器 如 26-27-1 / 25-26-2 / 25-26-1」。
  /// 默认仍是「全部学期」，不改变 m19335 #1「一次列完所有成绩」的口径。
  String _semesterFilter = '';

  /// 当前学期课程筛选 / 排序
  final TextEditingController _search = TextEditingController();
  String _keyword = '';

  /// 本地缓存的成绩数据里的学期列表
  List<dynamic> _semesters = [];
  /// 缓存的保存时间（ISO8601），用于显示「数据新鲜度」。
  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// 首次进入：先读本地缓存；**没有缓存时自动查一次** ——
  /// 查询按钮已收到右上角（刷新），不留「进去一片空白、不知道要点哪」的死路。
  Future<void> _bootstrap() async {
    await _load();
    await _loadCachedSemesters();
    if (mounted && _credentialBound && _semesters.isEmpty && !_querying) {
      unawaited(_query());
    }
  }

  Future<void> _loadCachedSemesters() async {
    // 成绩缓存来自 gradeProvider（唯一数据源）
    final cached = await ref.read(gradeProvider.notifier).ensureLoaded();
    if (!mounted) return;
    final list = cached.semesters;
    if (!mounted) return;
    setState(() {
      _loadingCache = false;
      if (list.isEmpty) return;
      _semesters = list;
      // 2026-11-04（m19335 #1）：不再有「选中的学期」，所有学期在本页平铺。
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // 配置来自 userConfigProvider（唯一数据源）
    final config = await ref.read(userConfigProvider.notifier).ensureLoaded();
    if (!mounted) return;
    setState(() {
      _checking = false;
      // 本地版「绑定」的语义 = 本地已填写统一认证账号
      _credentialBound = config.username.trim().isNotEmpty;
    });
  }

  void _startTimer() {
    _seconds = 0;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _query() async {
    if (_querying) return;
    setState(() {
      _querying = true;
      _message = null;
    });
    _startTimer();

    try {
      // 不传账密：用本机已保存的凭证
      final r = await ApiService.pushGrades();
      final semesters = (r['semesters'] as List<dynamic>?) ?? [];
      final partial = r['partial'] == true;
      if (semesters.isNotEmpty && !partial) {
        await ref.read(gradeProvider.notifier).save(
              semesters: semesters,
              summary: r['summary'] as Map<String, dynamic>?,
              student: r['student'] as Map<String, dynamic>?,
            );
      }
      if (!mounted) return;
      setState(() {
        // 成功不弹绿色横幅；只有部分学期抓取失败时给出可重试提示。
        _message = partial
            ? '部分学期查询失败，当前结果可能不完整，请重试'
            : null;
        if (semesters.isNotEmpty && (!partial || _semesters.isEmpty)) {
          _semesters = semesters;
        }
      });
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '').trim();
      if (!mounted) return;
      setState(() {
        _message = msg.isEmpty ? '查询失败，请稍后重试' : msg;
      });
    } finally {
      _stopTimer();
      if (mounted) setState(() => _querying = false);
    }
  }

  Future<void> _openExternal(String url) async {
    try {
      // 跳系统浏览器：内嵌 WebView 打开官网会错位、遮挡，体验差。
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) _toast('打开失败：$e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('成绩查询',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: context.cardColor,
        foregroundColor: isDark ? Colors.white : AppTheme.primaryColor,
        elevation: 0, // 2026-10-13：原 0.5 会在顶部多一道浅阴影，与全局 appBarTheme（0）不一致
        // 右上角只留刷新。
        //
        // 2026-11-04（m19335 #1）：用户明确「成绩总览指的单纯是所有搜索框加所有成绩，
        // 不是什么总览页面」→ 删掉独立的总览页入口（`GradeOverviewPage`），
        // 改成**本页把所有学期的成绩平铺在一起**，上方一个搜索框统管全部。
        actions: [
          IconButton(
            onPressed: _querying ? null : _query,
            tooltip: '刷新成绩',
            icon: _querying
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: (_checking || _loadingCache)
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
          : Stack(
              children: [
                Positioned.fill(
                  child: RefreshIndicator(
                    onRefresh: _query,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        // 2026-11-04（m19335 #1）：学期选择器撤掉 ——
                        // 所有学期的成绩都在本页平铺，不需要先选一个。
                        _buildOverview(isDark),
                        const SizedBox(height: 16),
                        _buildResult(isDark),
                        const SizedBox(height: 20),
                        SiteLinksRow(onOpen: _openExternal),
                      ],
                    ),
                  ),
                ),
                if (_querying)
                  Positioned.fill(child: LoadingOverlay(seconds: _seconds)),
              ],
            ),
    );
  }

  /// 总览卡。
  ///
  /// 🔴 2026-11-04（用户 m19892 #3）：**主显必修，选修收进折叠区**。
  ///    用户原话：「我校评奖评优等只看必修课成绩，选修课成绩是不计入的，
  ///    即『60=100』，建议右上角的绩点优先显示『必修课绩点』和
  ///    『必修课加权平均成绩』，选修课可以隐藏，点一下进去可以看总和和选修」。
  ///    所以这张卡的默认视图只回答一件事：**必修课打成了什么样**。
  Widget _buildOverview(bool isDark) {
    final state = ref.watch(gradeProvider);
    final summary = state.summary;
    if (summary.isEmpty && _semesters.isEmpty) return const SizedBox.shrink();

    final all = _allCourses();
    final reqList = all.where((c) => kindOfCourse(c) == CourseKind.required);
    final eleList = all.where((c) => kindOfCourse(c) == CourseKind.elective);
    final unkList = all.where((c) => kindOfCourse(c) == CourseKind.unknown);

    final req = CourseStats.from(reqList);
    final ele = CourseStats.from(eleList);
    final every = CourseStats.from(all);

    // 教务没回 `kcxzmc` 的学校（或老缓存）里必修会是空的。
    // 这时退回「全部」，但下面那行会明说「未区分必修」，不含糊。
    final main = req.isEmpty ? every : req;
    final mainIsRequired = !req.isEmpty;
    final mainTag = mainIsRequired ? '必修' : '全部';

    final name = (state.student['xm'] ?? '').toString().trim();
    final muted = context.textTertiary;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 15),
      radius: AppTheme.radiusMd,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('总览',
                  style: TextStyle(
                      fontSize: AppTheme.fontSmall,
                      fontWeight: FontWeight.w700,
                      color: context.textPrimary)),
              IconButton(
                onPressed: _showGpaInfo,
                tooltip: '绩点口径',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.info_outline_rounded, size: 16, color: muted),
              ),
              if (name.isNotEmpty) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppTheme.fontSmall, color: muted)),
                ),
              ],
              const Spacer(),
              if (!every.isEmpty)
                InkWell(
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  onTap: () => setState(() => _showAllStats = !_showAllStats),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_showAllStats ? '收起' : '全部 / 选修',
                            style: TextStyle(
                                fontSize: AppTheme.fontCaption,
                                color: context.textTertiary)),
                        Icon(
                            _showAllStats
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.keyboard_arrow_down_rounded,
                            size: 15,
                            color: muted),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _metric('$mainTag课绩点', main.gpa.toStringAsFixed(2), ' / 5.0',
                  isDark, AppTheme.primaryColor),
              _metric('$mainTag加权', main.avgText, '', isDark,
                  context.textPrimary),
              _metric('$mainTag学分', main.credits.toStringAsFixed(1), '',
                  isDark, context.textPrimary),
            ],
          ),
          // 2026-11-06（用户 m01524 #6）：「我校评奖评优是按照每学年一次的，
          // 所以总览可以按照学年」。学年分账因此从折叠区提到主视图，
          // 累计三数仍在上方供整体参考。
          ..._buildYearRows(isDark),
          if (_showAllStats && !every.isEmpty) ...[
            const SizedBox(height: 12),
            Divider(height: 1, color: context.borderColor),
            const SizedBox(height: 10),
            _statLine('全部', every, isDark),
            const SizedBox(height: 6),
            _statLine('选修', ele, isDark),
            if (unkList.isNotEmpty) ...[
              const SizedBox(height: 6),
              _statLine('未标注性质', CourseStats.from(unkList), isDark),
            ],
          ],
        ],
      ),
    );
  }

  /// 展开区的一行：`全部 · 绩点 3.55 · 加权 86.2 · 84.0 学分`
  Widget _statLine(String tag, CourseStats s, bool isDark) {
    final muted = context.textTertiary;
    if (s.isEmpty) {
      return Row(
        children: [
          SizedBox(
            width: 66,
            child: Text(tag,
                style: TextStyle(
                    fontSize: AppTheme.fontSmall, color: context.textSecondary)),
          ),
          Text('暂无', style: TextStyle(fontSize: AppTheme.fontSmall, color: muted)),
        ],
      );
    }
    return Row(
      children: [
        SizedBox(
          width: 66,
          child: Text(tag,
              style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  fontWeight: FontWeight.w600,
                  color: context.textSecondary)),
        ),
        Expanded(
          child: Text(
            '绩点 ${s.gpa.toStringAsFixed(2)} · 加权 ${s.avgText} · '
            '${s.credits.toStringAsFixed(1)} 学分 · ${s.count} 门',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AppTheme.fontSmall, color: muted),
          ),
        ),
      ],
    );
  }

  /// 按学年聚合（评奖评优是每学年一次，用户 m19892 #3 明确要求）。
  ///
  /// 学年从学期名里取：教务给的是 `2025-2026 第1学期` 这种，
  /// 取前 9 个字符即 `2025-2026`，展示时压成 `25-26`。
  List<Widget> _buildYearRows(bool isDark) {
    final buckets = <String, List<Map<String, dynamic>>>{};
    for (final s in _semesters) {
      if (s is! Map) continue;
      final m = Map<String, dynamic>.from(s);
      final name = (m['name'] ?? '').toString();
      final match = RegExp(r'(\d{4})-(\d{4})').firstMatch(name);
      final key = match == null
          ? (name.isEmpty ? '未知学年' : name)
          : '${match.group(1)}-${match.group(2)}';
      buckets.putIfAbsent(key, () => []).addAll(_semesterCourses(m));
    }
    if (buckets.isEmpty) return const [];

    final keys = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
    final rows = <Widget>[];
    for (final k in keys) {
      final list = buckets[k]!;
      // 学年平均同样只算必修：与主视图同一口径，否则用户没法拿它对账。
      final reqOnly =
          list.where((c) => kindOfCourse(c) == CourseKind.required).toList();
      final source = reqOnly.isEmpty ? list : reqOnly;
      final s = CourseStats.from(source);
      if (s.isEmpty) continue;
      final tag = RegExp(r'^(\d{4})-(\d{4})$').firstMatch(k);
      final label = tag == null
          ? k
          : '${tag.group(1)!.substring(2)}-${tag.group(2)!.substring(2)} 学年';
      final muted = context.textTertiary;
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          children: [
            SizedBox(
              width: 78,
              child: Text(label,
                  style: TextStyle(
                      fontSize: AppTheme.fontSmall,
                      fontWeight: FontWeight.w500,
                      color: context.textSecondary)),
            ),
            Expanded(
              child: Text(
                '绩点 ${s.gpa.toStringAsFixed(2)}'
                '${reqOnly.isEmpty ? '' : '（必修）'} · 加权 ${s.avgText}'
                ' · ${s.count} 门',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: AppTheme.fontSmall, color: muted),
              ),
            ),
          ],
        ),
      ));
    }
    if (rows.isEmpty) return const [];
    return [
      const SizedBox(height: 12),
      Divider(height: 1, color: context.borderColor),
      const SizedBox(height: 10),
      Text('按学年',
          style: TextStyle(
              fontSize: AppTheme.fontCaption,
              fontWeight: FontWeight.w600,
              color: context.textSecondary)),
      ...rows,
    ];
  }

  /// 所有学期的全部课程（不去重，一个学期一门课算一门）。
  List<Map<String, dynamic>> _allCourses() {
    final out = <Map<String, dynamic>>[];
    for (final s in _semesters) {
      if (s is! Map) continue;
      out.addAll(_semesterCourses(Map<String, dynamic>.from(s)));
    }
    return out;
  }

  Widget _metric(String label, String value, String unit, bool isDark,
      Color color) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: isDark ? Colors.grey.shade500 : Colors.grey.shade500)),
          const SizedBox(height: 2),
          Text.rich(
            TextSpan(
              text: value,
              style: TextStyle(
                  fontSize: 19, fontWeight: FontWeight.w700, color: color),
              children: [
                TextSpan(
                  text: unit,
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      fontWeight: FontWeight.w400,
                      color: context.textTertiary),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// 所有学期的成绩平铺在一起，上方一个搜索框 + 排序统管全部。
  ///
  /// 2026-11-04（m19335 #1）：用户原话「成绩总览指的单纯是所有搜索框加所有成绩，
  /// 不是什么总览页面」→ 删掉独立的总览页与学期选择器，本页一次列完所有学期。
  Widget _buildResult(bool isDark) {
    if (!_credentialBound && _semesters.isEmpty) {
      return _needLogin();
    }
    final sections = <Map<String, dynamic>>[];
    for (final s in _semesters) {
      if (s is! Map) continue;
      final map = Map<String, dynamic>.from(s);
      if (_semesterCourses(map).isEmpty) continue;
      sections.add(map);
    }
    if (_message == null && sections.isEmpty) {
      return _emptyState(
          isDark, Icons.assignment_outlined, '还没有查询结果，下拉或点右上角刷新');
    }

    // 按学期名倒序 = 时间从新到旧（2026-11-04 用户 m19892 #1 的「按时间排序」）。
    sections.sort((a, b) => '${b['name']}'.compareTo('${a['name']}'));

    // 选了某个学期就只留那一段；`_semesterFilter` 为空串表示全部。
    final shown = _semesterFilter.isEmpty
        ? sections
        : sections
            .where((s) => _shortSemName('${s['name']}') == _semesterFilter)
            .toList();

    final hits = <MapEntry<Map<String, dynamic>, List<Map<String, dynamic>>>>[];
    var total = 0;
    for (final sem in shown) {
      final courses = _visibleCourses(_semesterCourses(sem));
      total += courses.length;
      if (courses.isNotEmpty) hits.add(MapEntry(sem, courses));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_message != null) _errorCard(),
        // 2026-11-04（用户 m20455 #5）：学期选择器「明显化」+ 搜索框压缩，
        // 两者并排一行。原来选择器是左对齐的一行小字、搜索框单独占整块卡片，
        // 视觉重心全在搜索上，用户找不到切换学期的地方。
        if (sections.isNotEmpty)
          Row(
            children: [
              _buildSemesterSelector(isDark, sections),
              const SizedBox(width: 8),
              Expanded(child: _buildSearchField()),
            ],
          ),
        if (sections.isNotEmpty) const SizedBox(height: 10),
        if (sections.isEmpty)
          _emptyState(isDark, Icons.school_outlined, '暂无成绩数据')
        else if (total == 0)
          _emptyState(isDark, Icons.search_off_rounded, '没有匹配的课程')
        else
          for (final hit in hits) _buildSemesterSection(isDark, hit.key, hit.value),
      ],
    );
  }

  /// 学期选择器（2026-11-04 用户 m19892 #1）。
  ///
  /// 一排胶囊按钮的样子太占地方，这里做成「当前值 + 下拉箭头」一行，
  /// 点开是滚轮（[showSemesterPicker] 内部已是 CupertinoPicker）。
  Widget _buildSemesterSelector(bool isDark, List<Map<String, dynamic>> sections) {
    final label = _semesterFilter.isEmpty
        ? '全部学期'
        : _semesterFilter;
    final count = _semesterFilter.isEmpty
        ? sections.length
        : sections
            .where((s) => _shortSemName('${s['name']}') == _semesterFilter)
            .length;
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          onTap: sections.isEmpty ? null : () => _pickSemesterFilter(sections),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.event_note_rounded,
                    size: 15, color: context.textTertiary),
                const SizedBox(width: 5),
                Text(label,
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall,
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary)),
                const SizedBox(width: 4),
                Text('($count)',
                    style: TextStyle(
                        fontSize: AppTheme.fontCaption,
                        color: context.textTertiary)),
                Icon(Icons.expand_more_rounded,
                    size: 17, color: context.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickSemesterFilter(List<Map<String, dynamic>> sections) async {
    final labels = <String>['全部学期', ...sections.map((s) => _shortSemName('${s['name']}'))];
    final current = _semesterFilter.isEmpty
        ? 0
        : labels.indexOf(_semesterFilter).clamp(0, labels.length - 1);
    final picked = await showSemesterPicker(
      context,
      labels: labels,
      currentIndex: current,
      title: '选择学期',
    );
    if (picked == null || !mounted) return;
    setState(() => _semesterFilter = picked == 0 ? '' : labels[picked]);
  }

  Widget _needLogin() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        children: [
          Icon(Icons.person_off_outlined,
              size: 34, color: context.textTertiary),
          const SizedBox(height: 8),
          Text('还没有绑定统一认证账号',
              style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary)),
          const SizedBox(height: 4),
          Text('请先在「我的」绑定账号，再回来刷新成绩',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: AppTheme.fontSmall, height: 1.4, color: context.textTertiary)),
        ],
      ),
    );
  }

  Widget _errorCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(
            color: const Color(0xFFEF4444).withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 20, color: Color(0xFFEF4444)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _message!,
              style: TextStyle(
                  fontSize: AppTheme.fontSmall, height: 1.5, color: context.textPrimary),
            ),
          ),
          TextButton(
            onPressed: _querying ? null : _query,
            child: const Text('重试', style: TextStyle(fontSize: AppTheme.fontSmall)),
          ),
        ],
      ),
    );
  }

  /// 一个学期的成绩段：学期名 + 学分绩点小结 + 该学期命中的课程卡。
  ///
  /// 版式沿用「掌上徐工」口味：小字小结放上面，课程卡逐条往下。
  /// 搜索框已提到 `_buildResult` 顶部统管全部学期，这里不再重复渲染。
  Widget _buildSemesterSection(
      bool isDark, Map<String, dynamic> sem, List<Map<String, dynamic>> visible) {
    final courses = _semesterCourses(sem);
    final all = courses.length;
    final name = (sem['name'] ?? '').toString();
    final muted = isDark ? Colors.grey.shade400 : const Color(0xFF6B7280);

    // 2026-11-04（用户 m19892 #3）：学期小结也走必修口径，与顶部总览一致。
    // 原来这里读的是教务给的 `total_xf` / `gpa`（含选修），
    // 于是「总览说必修绩点 3.6、这一行说 3.4」，用户没法对账。
    final reqOnly =
        courses.where((c) => kindOfCourse(c) == CourseKind.required).toList();
    final eleOnly =
        courses.where((c) => kindOfCourse(c) == CourseKind.elective).toList();
    final stats = CourseStats.from(reqOnly.isEmpty ? courses : reqOnly);
    final reqTag = reqOnly.isEmpty ? '' : '必修';
    final summaryText = [
      '$reqTag绩点 ${stats.gpa.toStringAsFixed(2)}',
      '$reqTag加权 ${stats.avgText}',
      '${stats.credits.toStringAsFixed(1)} 学分',
      if (eleOnly.isNotEmpty) '另有选修 ${eleOnly.length} 门',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 12, 2, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  name.isEmpty ? '未知学期' : _shortSemName(name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text('$all 门',
                  style: TextStyle(
                      fontSize: AppTheme.fontSmall, color: context.textTertiary)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
          child: Text(
            summaryText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: AppTheme.fontSmall, height: 1.35, color: muted),
          ),
        ),
        for (final c in visible) _buildCourseTile(isDark, c),
      ],
    );
  }

  /// 学期名压成 `25-26-1`（2026-11-04 用户 m19892 #1）。
  ///
  /// 教务给的是 `2025-2026 第1学期`，在标题行里占 13 个字符，
  /// 和右边的「N 门」挤在一起时容易省略；短格式与选择器的标签统一。
  String _shortSemName(String raw) {
    final m = RegExp(r'(\d{4})-(\d{4})').firstMatch(raw);
    if (m == null) return raw;
    final a = m.group(1)!.substring(2);
    final b = m.group(2)!.substring(2);
    // 学期号：优先认「第1/第2学期」，其次认中文「一/二」，兜底 1
    final half = RegExp(r'第\s*([12])').firstMatch(raw)?.group(1) ??
        (raw.contains('一') ? '1' : (raw.contains('二') ? '2' : '1'));
    return '$a-$b-$half';
  }

  List<Map<String, dynamic>> _semesterCourses(Map<String, dynamic> sem) {
    final raw = (sem['courses'] as List<dynamic>?) ?? const [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  List<Map<String, dynamic>> _visibleCourses(
      List<Map<String, dynamic>> courses) {
    final q = _keyword.trim().toLowerCase();
    var list = courses.where((c) {
      if (q.isNotEmpty) {
        final name = (c['kcmc'] ?? '').toString().toLowerCase();
        final type = (c['kcxzmc'] ?? '').toString().toLowerCase();
        final teacher = (c['jsxm'] ?? '').toString().toLowerCase();
        if (!name.contains(q) &&
            !type.contains(q) &&
            !teacher.contains(q)) {
          return false;
        }
      }
      return true;
    }).toList();

    // 2026-11-04（用户 m20455 #5）：排序功能整体移除。
    // 保留教务返回的原始顺序 —— 学期内按课程号，找课靠搜索不靠排序。
    return list;
  }

  /// 搜索框（2026-11-04 用户 m20455 #5）。
  ///
  /// 用户原话：「成绩页面搜索框优化，压缩并且去除排序功能」。
  /// 原来是一个整块卡片：上面一行输入框、下面一行排序菜单，占了一百多 dp。
  /// 现在压成 38 高的单行、不带排序菜单，与学期选择器并排。
  /// 排序本来就要点两次才用得上，默认顺序保留教务返回顺序（学期内按课程号）。
  Widget _buildSearchField() {
    return SizedBox(
      height: 38,
      child: TextField(
        controller: _search,
        onChanged: (v) => setState(() => _keyword = v),
        decoration: InputDecoration(
          hintText: '搜索课程 / 教师',
          isDense: true,
          filled: true,
          fillColor: context.surfaceColor,
          prefixIcon: Icon(Icons.search_rounded, size: 17, color: context.textTertiary),
          prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          suffixIcon: _keyword.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close_rounded, size: 15),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                  onPressed: () {
                    _search.clear();
                    setState(() => _keyword = '');
                  },
                ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            borderSide: BorderSide(color: context.borderColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            borderSide: BorderSide(color: context.borderColor),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            borderSide: BorderSide(color: AppTheme.primaryColor),
          ),
        ),
        style: const TextStyle(fontSize: AppTheme.fontSmall),
      ),
    );
  }

  /// 单门课程卡片：课程名 + 「类型 · 学分 · 绩点」，右侧大号分数（按分段着色）。
  Widget _buildCourseTile(bool isDark, Map<String, dynamic> course) {
    final name = (course['kcmc'] ?? '').toString().trim();
    final type = (course['kcxzmc'] ?? '').toString().trim();
    final teacher = (course['jsxm'] ?? '').toString().trim();
    final xf = _asDouble(course['xf']).toStringAsFixed(1);
    final jd = _asDouble(course['jd']).toStringAsFixed(1);
    final rawScore = course['cj']?.toString().trim() ?? '';
    final score = rawScore.isEmpty ? '—' : rawScore;
    final meta = [
      if (type.isNotEmpty) type,
      '$xf 学分',
      '绩点 $jd',
      if (teacher.isNotEmpty) teacher,
    ].join(' · ');

    return AppCard(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      radius: AppTheme.radiusMd,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? '未知课程' : name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTheme.fontTitle,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  meta,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    height: 1.35,
                    color: isDark
                        ? Colors.grey.shade400
                        : const Color(0xFF6B7280),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                score,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: _scoreColor(isDark, score),
                ),
              ),
              // 2026-11-04（m18409 #5）：不再标「不及格」——
              // 及格与否是学校认定的事，分数本身已经把话说清楚了。
            ],
          ),
        ],
      ),
    );
  }

  double _asDouble(Object? v) {
    if (v is num) return v.toDouble();
    return double.tryParse('$v') ?? 0;
  }


  void _showGpaInfo() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('绩点怎么算'),
        content: const Text(
          '总览默认只统计**必修课**：绩点 = Σ(必修学分 × 教务绩点) ÷ Σ必修学分，'
          '加权 = Σ(必修学分 × 分数) ÷ Σ参与计算的必修学分。\n\n'
          '选修课按用户所在学校的评奖口径单列（点「全部 / 选修」展开看），'
          '不并入主视图。\n\n'
          '加权平均只计入**有数字成绩**的课程；「优秀 / 良好 / 通过」这类等级制'
          '成绩没有可换算的数值，不计入平均，也不影响绩点以外的数字。\n\n'
          '学年平均按学期名的学年前缀聚合，同样只算必修。\n\n'
          '课程学分、绩点全部来自教务成绩查询结果，App 不自行换算；'
          '是否及格由学校认定，本页只呈现原始分数与学分。',
          style: TextStyle(fontSize: AppTheme.fontBody, height: 1.55),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  double? _scoreNum(String raw) {
    final m = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(raw.trim());
    return m == null ? null : double.tryParse(m.group(0)!);
  }

  /// 分数着色：≥90 标绿（高分）、<60 标红（低分）、其余用正文色。
  /// 注意这是**分数段着色**，不表达「及格/不及格」—— 见 m18409 #5。
  Color _scoreColor(bool isDark, String score) {
    final normal = isDark ? Colors.white : AppTheme.textPrimaryLight;
    final n = _scoreNum(score);
    if (n == null) return normal;
    if (n >= 90) return const Color(0xFF10B981);
    if (n >= 60) return normal;
    return const Color(0xFFEF4444);
  }

  Widget _emptyState(bool isDark, IconData icon, String text) {
    // 空态统一走共享组件（2026-10-20）
    return EmptyState(
      icon: icon,
      // 成绩 → 一张带上升折线的成绩单。
      artVariant: EmptyArtVariant.report,
      message: text,
    );
  }

}
