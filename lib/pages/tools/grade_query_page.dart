import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/api_service.dart';
import '../../providers/user_config_provider.dart';
import '../../providers/grade_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/loading_overlay.dart';
import '../../widgets/site_links.dart';

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
  bool _credentialBound = false;

  bool _querying = false;
  int _seconds = 0;
  Timer? _timer;

  String? _message;
  bool _success = false;

  /// 本地缓存的成绩数据里的学期列表
  List<dynamic> _semesters = [];
  /// 缓存的保存时间（ISO8601），用于显示「数据新鲜度」。
  String _cacheSavedAt = '';
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
    if (names.isNotEmpty) return names;

    final now = DateTime.now();
    var year = now.month >= 8 ? now.year : now.year - 1;
    var term = now.month >= 8 ? 1 : 2;
    for (var i = 0; i < 6; i++) {
      names.add('$year-${year + 1} 第$term学期');
      if (term == 2) {
        year -= 1;
        term = 1;
      } else {
        term = 2;
      }
    }
    return names;
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
    if (list.isEmpty) return;
    setState(() {
      _semesters = list;
      _cacheSavedAt = cached.savedAt; // 记录缓存时间，供顶部提示
      // 保留了已有选择就沿用；否则默认最新学期
      final names = _semesterNames();
      if (!names.contains(_selectedName)) _selectedName = names.first;
    });
  }

  Future<void> _pickSemester() async {
    final names = _semesterNames();
    var currentIndex = names.indexOf(_selectedName);
    if (currentIndex < 0) currentIndex = 0;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Text('选择学期',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimary)),
            const SizedBox(height: 4),
            for (var i = 0; i < names.length; i++)
              ListTile(
                dense: true,
                title: Text(names[i],
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          i == currentIndex ? FontWeight.w700 : FontWeight.normal,
                      color: context.textPrimary,
                    )),
                trailing: i == currentIndex
                    ? const Icon(Icons.check_rounded,
                        size: 20, color: Color(0xFF3B82F6))
                    : null,
                onTap: () => Navigator.of(ctx).pop(i),
              ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _selectedName = names[picked]);
  }

  @override
  void dispose() {
    _timer?.cancel();
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
    setState(() {
      _querying = true;
      _message = null;
    });
    _startTimer();

    try {
      // 不传账密：用本机已保存的凭证
      final r = await ApiService.pushGrades();
      final semesters = (r['semesters'] as List<dynamic>?) ?? [];
      if (semesters.isNotEmpty) {
          await ref.read(gradeProvider.notifier).save(
                semesters: semesters,
                summary: r['summary'] as Map<String, dynamic>?,
                student: r['student'] as Map<String, dynamic>?,
              );
      }
      if (!mounted) return;
      setState(() {
        _success = true;
        _message = (r['message'] as String?) ?? '成绩查询成功';
        if (semesters.isNotEmpty) {
          _semesters = semesters;
          _cacheSavedAt = ''; // 本次是新查的，不再标「缓存」
          // 之前选的学期不在本次结果里 → 回到最新学期
          if (!_semesterNames().contains(_selectedName)) {
            _selectedName = _semesterNames().first;
          }
        }
      });
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '').trim();
      if (!mounted) return;
      setState(() {
        _success = false;
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
      backgroundColor: isDark ? const Color(0xFF121212) : AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('成绩查询',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        foregroundColor: isDark ? Colors.white : AppTheme.primaryColor,
        elevation: 0.5,
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
      body: _checking
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
          : Stack(
                  children: [
                    Positioned.fill(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32), // v1.7.1 统一页面边距：原 16
                        children: [
                          _buildSemesterRow(isDark),
                          const SizedBox(height: 16),
                          _buildResult(isDark),
                          const SizedBox(height: 20),
                          SiteLinksRow(onOpen: _openExternal),
                        ],
                      ),
                    ),
                    if (_querying)
                      Positioned.fill(child: LoadingOverlay(seconds: _seconds)),
                  ],
                ),
    );
  }

  /// 学期选择（点击弹出选择面板）
  Widget _buildSemesterRow(bool isDark) {
    return Material(
      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: _querying ? null : _pickSemester,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
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
                    fontSize: 14,
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

/// 缓存新鲜度提示（v2.3.1）。
  ///
  /// 背景：成绩查询结果会缓存到本地，重进页面直接展示 —— 但用户不知道
  /// 看到的是「刚查的」还是「上周的」。这里在结果顶部显式标注缓存时间，
  /// 并在超过 1 天时用醒目色提示「建议重新查询」。
  Widget _cacheHint(bool isDark) {
    if (_cacheSavedAt.isEmpty) return const SizedBox.shrink();
    DateTime? t;
    try {
      t = DateTime.tryParse(_cacheSavedAt);
    } catch (_) {}
    if (t == null) return const SizedBox.shrink();

    final diff = DateTime.now().difference(t);
    final stale = diff.inDays >= 1;
    final ago = diff.inMinutes < 1
        ? '刚刚'
        : diff.inHours < 1
            ? '${diff.inMinutes} 分钟前'
            : diff.inHours < 24
                ? '${diff.inHours} 小时前'
                : '${diff.inDays} 天前';

    final fg = stale
        ? const Color(0xFFB45309)
        : (isDark ? Colors.grey.shade500 : Colors.grey.shade500);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: stale
            ? const Color(0xFFFFF7ED)
            : (isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF9FAFB)),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: stale
                ? const Color(0xFFF59E0B).withOpacity(0.4)
                : context.borderColor),
      ),
      child: Row(
        children: [
          Icon(stale ? Icons.schedule_rounded : Icons.check_circle_outline_rounded,
              size: 15, color: fg),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              stale ? '本地缓存（$ago）· 建议重新查询' : '本地缓存 · $ago',
              style: TextStyle(fontSize: 12, color: fg),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResult(bool isDark) {
    final summary = _selectedSemester;
    if (_message == null && summary == null) {
      return _emptyState(isDark, Icons.assignment_outlined, '还没有查询结果，点上面的按钮开始查询');
    }
    final color = _success ? const Color(0xFF10B981) : const Color(0xFFEF4444);
    return Column(
      children: [
        // v2.3.1：缓存新鲜度提示（有缓存时才显示）
        _cacheHint(isDark),
        if (_message != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withOpacity(0.45)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_success ? Icons.check_circle_rounded : Icons.error_rounded,
                    size: 20, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _message!,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      color: context.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (summary != null) ...[
          if (_message != null) const SizedBox(height: 12),
          _buildSemesterSummary(isDark, summary),
        ],
      ],
    );
  }

  /// 所选学期的成绩（版式仿掌上徐工）：
  /// 顶部一行「学分靠左 / 绩点靠右」的小字小结，下面按课程逐条卡片。
  Widget _buildSemesterSummary(bool isDark, Map<String, dynamic> sem) {
    final xf = (sem['total_xf'] as num? ?? 0).toDouble();
    final gpa = (sem['gpa'] as num? ?? 0).toDouble();
    final courses = (sem['courses'] as List<dynamic>?) ?? const [];
    final muted = isDark ? Colors.grey.shade400 : const Color(0xFF6B7280);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 小结行：与下方卡片的左右边缘对齐
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
          child: Row(
            children: [
              Text('该学期学分 ${xf.toStringAsFixed(1)}',
                  style: TextStyle(fontSize: 12.5, color: muted)),
              const Spacer(),
              Text('该学期绩点 ${gpa.toStringAsFixed(2)} / 5.0',
                  style: TextStyle(fontSize: 12.5, color: muted)),
            ],
          ),
        ),
        if (courses.isEmpty)
          _emptyState(isDark, Icons.school_outlined, '该学期暂无成绩')
        else
          for (final c in courses)
            _buildCourseTile(isDark, Map<String, dynamic>.from(c as Map)),
      ],
    );
  }

  /// 单门课程卡片：课程名 + 「类型 · 学分 · 绩点」，右侧大号分数（按分段着色）。
  Widget _buildCourseTile(bool isDark, Map<String, dynamic> course) {
    final name = (course['kcmc'] as String? ?? '').trim();
    final type = (course['kcxzmc'] as String? ?? '').trim();
    final xf = (course['xf'] as num? ?? 0).toStringAsFixed(1);
    final jd = (course['jd'] as num? ?? 0).toStringAsFixed(1);
    final score = course['cj']?.toString() ?? '';
    final meta = [
      if (type.isNotEmpty) type,
      '$xf 学分',
      '绩点$jd',
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? '未知课程' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  meta,
                  style: TextStyle(
                    fontSize: 12.5,
                    color:
                        isDark ? Colors.grey.shade400 : const Color(0xFF6B7280),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            score,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: _scoreColor(isDark, score),
            ),
          ),
        ],
      ),
    );
  }

  /// 分数着色：≥90 标绿（优秀）、<60 标红（不及格）、其余用正文色。
  Color _scoreColor(bool isDark, String score) {
    final normal = isDark ? Colors.white : const Color(0xFF1F2937);
    final n = double.tryParse(score.trim());
    if (n == null) return normal;
    if (n >= 90) return const Color(0xFF10B981);
    if (n >= 60) return normal;
    return const Color(0xFFEF4444);
  }

  Widget _emptyState(bool isDark, IconData icon, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A1A) : Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(icon, size: 34, color: Colors.grey.shade400),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.grey.shade400 : const Color(0xFF9CA3AF),
            ),
          ),
        ],
      ),
    );
  }

}
