import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../widgets/empty_state_art.dart';
import '../../widgets/state_views.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/api_service.dart';
import '../../providers/user_config_provider.dart';
import '../../providers/grade_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/loading_overlay.dart';
import '../../widgets/semester_picker.dart';
import '../../widgets/site_links.dart';
import '../../widgets/app_card.dart';

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

  /// 当前学期课程筛选 / 排序
  final TextEditingController _search = TextEditingController();
  String _keyword = '';
  String _filter = 'all'; // all / pass / fail
  String _sort = 'default'; // default / name / score / credit

  /// 本地缓存的成绩数据里的学期列表
  List<dynamic> _semesters = [];
  /// 缓存的保存时间（ISO8601），用于显示「数据新鲜度」。
  String _cacheSavedAt = '';
  /// 上次选的学期（跨启动记住；用户要求「退出时是哪个，下次进来还是哪个」）
  static const String _kSemesterKey = 'grade_selected_semester_v1';

  /// 当前选中的学期名（形如 `2025-2026 第1学期`，与教务系统命名一致）
  String _selectedName = '';

  @override
  void initState() {
    super.initState();
    _selectedName = _semesterNames().first;
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

  /// 可选学期名：优先用已缓存的真实学期；没有则按当前时间往前推 6 个
  /// （教务学期名格式 = `{学年} 第{1|2}学期`，所以推算出来的能直接对上）。
  List<String> _semesterNames() {
    final names = <String>[];
    for (final s in _semesters) {
      if (s is Map && (s['name'] != null)) {
        final n = s['name'].toString();
        if (n.isNotEmpty) names.add(n);
      }
    }
    // 以「按当前时间推算的最近 8 个学期」为骨架，再把缓存里出现过的更早学期补到末尾。
    // 原因：只用缓存会让「只修过 1-2 个学期」的同学选不到以前的学期（同学反馈的"缺少学期"）。
    final merged = <String>[...recentSemesterLabels()];
    for (final name in names) {
      if (!merged.contains(name)) merged.add(name);
    }
    return merged;
  }

  /// 最近一个**有成绩记录**的学期；都没有就退回第一个（最新）。
  String _firstWithGrades(List<String> names) {
    for (final name in names) {
      for (final s in _semesters) {
        if (s is Map && s['name'] == name) {
          final list = (s['courses'] as List<dynamic>?) ?? const [];
          if (list.isNotEmpty) return name;
        }
      }
    }
    return names.first;
  }

  Map<String, dynamic>? get _selectedSemester {
    for (final s in _semesters) {
      if (s is Map && s['name'] == _selectedName) {
        return Map<String, dynamic>.from(s);
      }
    }
    return null;
  }

  Future<void> _loadCachedSemesters() async {
    // 成绩缓存来自 gradeProvider（唯一数据源）
    final cached = await ref.read(gradeProvider.notifier).ensureLoaded();
    if (!mounted) return;
    final list = cached.semesters;
    String? saved;
    if (list.isNotEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        saved = prefs.getString(_kSemesterKey);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _loadingCache = false;
      if (list.isEmpty) return;
      _semesters = list;
      _cacheSavedAt = cached.savedAt;
      // 保留了已有选择就沿用；否则默认「最近一个**有成绩**的学期」。
      final names = _semesterNames();
      if (!names.contains(_selectedName)) {
        _selectedName = (saved != null && names.contains(saved))
            ? saved
            : _firstWithGrades(names);
      }
    });
  }

  Future<void> _pickSemester() async {
    final names = _semesterNames();
    var currentIndex = names.indexOf(_selectedName);
    if (currentIndex < 0) currentIndex = 0;
    final picked = await showSemesterPicker(
      context,
      labels: names,
      currentIndex: currentIndex,
    );
    if (picked == null || !mounted) return;
    setState(() => _selectedName = names[picked]);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSemesterKey, _selectedName);
    } catch (_) {}
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
          _cacheSavedAt = ''; // 本次是新查的，不再标「缓存」
          final names = _semesterNames();
          if (!names.contains(_selectedName)) {
            _selectedName = _firstWithGrades(names);
          }
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
        // 仿掌上徐工：右上角一个刷新按钮（取代原来的大查询按钮）
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
                        _buildSemesterRow(isDark),
                        const SizedBox(height: 12),
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

  Widget _buildOverview(bool isDark) {
    final state = ref.watch(gradeProvider);
    final summary = state.summary;
    if (summary.isEmpty && _semesters.isEmpty) return const SizedBox.shrink();

    var totalXf = _asDouble(summary['total_xf']);
    var gpa = _asDouble(summary['gpa']);
    var count = _asInt(summary['count']);
    final needCompute = summary.isEmpty || count == 0;
    var passed = 0;
    var xfjd = 0.0;
    for (final sem in _semesters) {
      if (sem is! Map) continue;
      for (final c in (sem['courses'] as List<dynamic>?) ?? const []) {
        if (c is! Map) continue;
        if (_passStatus(c['cj']?.toString() ?? '') == true) passed++;
        if (needCompute) {
          count++;
          final credit = _asDouble(c['xf']);
          totalXf += credit;
          xfjd += credit * _asDouble(c['jd']);
        }
      }
    }
    if (needCompute) {
      gpa = totalXf > 0 ? xfjd / totalXf : 0;
    }
    final passRate = count > 0 ? (passed / count * 100).round() : 0;
    final student = state.student;
    final name = (student['xm'] ?? '').toString().trim();

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
                icon: Icon(Icons.info_outline_rounded,
                    size: 16, color: context.textTertiary),
              ),
              if (name.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(name,
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall, color: context.textTertiary)),
              ],
              const Spacer(),
              Text('全部学期',
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption, color: context.textTertiary)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _metric('加权绩点', gpa.toStringAsFixed(2), ' / 5.0',
                  isDark, AppTheme.primaryColor),
              _metric('学分', totalXf.toStringAsFixed(1), '',
                  isDark, context.textPrimary),
              _metric('课程', '$count', ' 门',
                  isDark, context.textPrimary),
              _metric('及格率', '$passRate', '%',
                  isDark, passRate >= 60
                      ? const Color(0xFF10B981)
                      : const Color(0xFFEF4444)),
            ],
          ),
        ],
      ),
    );
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

  /// 学期选择（点击弹出选择面板）
  Widget _buildSemesterRow(bool isDark) {
    return Material(
      color: context.cardColor,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InkWell(
        onTap: _querying ? null : _pickSemester,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            border: Border.all(
                color: context.borderColor),
          ),
          child: Row(
            children: [
              Icon(Icons.date_range_rounded,
                  size: 20,
                  color: isDark ? Colors.grey.shade400 : const Color(0xFF9CA3AF)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _selectedName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                ),
              ),
              Icon(Icons.keyboard_arrow_down_rounded,
                  size: 22,
                  color: isDark ? Colors.grey.shade400 : const Color(0xFF9CA3AF)),
            ],
          ),
        ),
      ),
    );
  }

  /// 缓存时间提示（v2.3.1，2026-10-12 调整）。
  ///
  /// 背景：成绩查询结果会缓存到本地，重进页面直接展示 —— 但用户不知道
  /// 看到的是「刚查的」还是「上周的」。这里在结果顶部如实标注缓存时间。
  ///
  /// 🔴 2026-10-12：**不再把缓存判为「过期」**（用户要求：缓存不过期）。
  ///    原来超过 1 天会转成橙色警告「建议重新查询」；但成绩、考试这类数据
  ///    本身低频变更，没必要催用户重查 —— 现在任何时候都是中性样式，
  ///    只标注「本地缓存 · X 前」，查不查由用户自己决定。
  Widget _cacheHint(bool isDark) {
    if (_cacheSavedAt.isEmpty) return const SizedBox.shrink();
    DateTime? t;
    try {
      t = DateTime.tryParse(_cacheSavedAt);
    } catch (_) {}
    if (t == null) return const SizedBox.shrink();

    final diff = DateTime.now().difference(t);
    final ago = diff.inMinutes < 1
        ? '刚刚'
        : diff.inHours < 1
            ? '${diff.inMinutes} 分钟前'
            : diff.inHours < 24
                ? '${diff.inHours} 小时前'
                : '${diff.inDays} 天前';

    final fg = isDark ? Colors.grey.shade500 : Colors.grey.shade600;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        children: [
          Icon(Icons.history_rounded, size: 15, color: fg),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '本地缓存 · $ago · 下拉可刷新',
              style: TextStyle(fontSize: AppTheme.fontSmall, color: fg),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResult(bool isDark) {
    final summary = _selectedSemester;
    if (!_credentialBound && _semesters.isEmpty) {
      return _needLogin();
    }
    if (_message == null && summary == null) {
      return _emptyState(
          isDark, Icons.assignment_outlined, '还没有查询结果，下拉或点右上角刷新');
    }
    return Column(
      children: [
        // v2.3.1：缓存新鲜度提示（有缓存时才显示）
        _cacheHint(isDark),
        if (_message != null) _errorCard(),
        if (summary != null) ...[
          if (_message != null) const SizedBox(height: 12),
          _buildSemesterSummary(isDark, summary),
        ] else if (_message == null)
          _emptyState(isDark, Icons.school_outlined, '该学期暂无成绩'),
      ],
    );
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

  /// 所选学期的成绩（版式仿掌上徐工）：
  /// 顶部一行「学分靠左 / 绩点靠右」的小字小结，下面按课程逐条卡片。
  Widget _buildSemesterSummary(bool isDark, Map<String, dynamic> sem) {
    final xf = _asDouble(sem['total_xf']);
    final gpa = _asDouble(sem['gpa']);
    final courses = _semesterCourses(sem);
    final passed = courses.where((c) {
      return _passStatus(c['cj']?.toString() ?? '') == true;
    }).length;
    final visible = _visibleCourses(courses);
    final muted = isDark ? Colors.grey.shade400 : const Color(0xFF6B7280);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
          child: Row(
            children: [
              Text('该学期学分 ${xf.toStringAsFixed(1)}',
                  style: TextStyle(fontSize: AppTheme.fontSmall, color: muted)),
              const SizedBox(width: 10),
              Text('绩点 ${gpa.toStringAsFixed(2)}',
                  style: TextStyle(fontSize: AppTheme.fontSmall, color: muted)),
              const Spacer(),
              Text('${courses.length} 门 · 及格 $passed',
                  style: TextStyle(
                      fontSize: AppTheme.fontSmall, color: context.textTertiary)),
            ],
          ),
        ),
        if (courses.isNotEmpty) _buildCourseToolbar(),
        if (courses.isEmpty)
          _emptyState(isDark, Icons.school_outlined, '该学期暂无成绩')
        else if (visible.isEmpty)
          _emptyState(isDark, Icons.search_off_rounded, '没有匹配的课程')
        else
          for (final c in visible) _buildCourseTile(isDark, c),
      ],
    );
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
      final status = _passStatus(c['cj']?.toString() ?? '');
      if (_filter == 'pass') return status == true;
      if (_filter == 'fail') return status == false;
      return true;
    }).toList();

    int compareScore(Map<String, dynamic> a, Map<String, dynamic> b) {
      final sa = _scoreNum(a['cj']?.toString() ?? '') ?? -1;
      final sb = _scoreNum(b['cj']?.toString() ?? '') ?? -1;
      return sb.compareTo(sa);
    }

    switch (_sort) {
      case 'name':
        list.sort((a, b) => (a['kcmc'] ?? '')
            .toString()
            .compareTo((b['kcmc'] ?? '').toString()));
      case 'score':
        list.sort(compareScore);
      case 'credit':
        list.sort((a, b) =>
            _asDouble(b['xf']).compareTo(_asDouble(a['xf'])));
      default:
        break;
    }
    return list;
  }

  Widget _buildCourseToolbar() {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        children: [
          TextField(
            controller: _search,
            onChanged: (v) => setState(() => _keyword = v),
            decoration: InputDecoration(
              hintText: '搜索课程 / 教师 / 类型',
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              suffixIcon: _keyword.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16),
                      onPressed: () {
                        _search.clear();
                        setState(() => _keyword = '');
                      },
                    ),
              isDense: true,
              filled: true,
              fillColor: context.scaffoldColor,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                borderSide: BorderSide.none,
              ),
            ),
            style: const TextStyle(fontSize: AppTheme.fontSmall),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _filterChip('all', '全部'),
                      _filterChip('pass', '及格'),
                      _filterChip('fail', '不及格'),
                    ],
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '排序',
                initialValue: _sort,
                onSelected: (v) => setState(() => _sort = v),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'default', child: Text('默认顺序')),
                  PopupMenuItem(value: 'name', child: Text('课程名')),
                  PopupMenuItem(value: 'score', child: Text('分数从高到低')),
                  PopupMenuItem(value: 'credit', child: Text('学分从高到低')),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    children: [
                      Icon(Icons.sort_rounded,
                          size: 16, color: context.textSecondary),
                      const SizedBox(width: 3),
                      Text(
                        switch (_sort) {
                          'name' => '课程名',
                          'score' => '分数',
                          'credit' => '学分',
                          _ => '默认',
                        },
                        style: TextStyle(
                            fontSize: AppTheme.fontSmall, color: context.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String value, String label) {
    final selected = _filter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: AppTheme.fontCaption)),
        selected: selected,
        showCheckmark: false,
        onSelected: (_) => setState(() => _filter = value),
        visualDensity: VisualDensity.compact,
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
              if (_passStatus(rawScore) == false)
                const Text('不及格',
                    style: TextStyle(
                        fontSize: 9.5,
                        color: Color(0xFFEF4444),
                        fontWeight: FontWeight.w600)),
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

  int _asInt(Object? v) {
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  void _showGpaInfo() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('绩点怎么算'),
        content: const Text(
          '总览绩点 = Σ(课程学分 × 教务绩点) ÷ Σ课程学分。\n\n'
          '课程学分、绩点都来自教务成绩查询结果，App 不自行换算。\n\n'
          '及格率：数字成绩按 60 分判定；合格、通过、及格、优秀、良好、中等计为及格。',
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

  /// 判定是否及格：数字成绩按 60 分；文字成绩兼容「合格/通过/及格/优秀/良好/中等」。
  /// 未知文字不算及格也不算不及格（筛选时不误伤）。
  bool? _passStatus(String raw) {
    final n = _scoreNum(raw);
    if (n != null) return n >= 60;
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (RegExp(r'不合格|不通过|不及格|缺考|取消').hasMatch(s)) return false;
    if (RegExp(r'合格|通过|及格|优秀|良好|中等').hasMatch(s)) return true;
    return null;
  }

  /// 分数着色：≥90 标绿（优秀）、<60 标红（不及格）、其余用正文色。
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
