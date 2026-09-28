import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/api_service.dart';
import '../../services/exam_storage.dart';
import '../../providers/user_config_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/loading_overlay.dart';
import '../../widgets/site_links.dart';

/// 考试安排（v2.4.5 起与「成绩查询」彻底分开，各自独立页面）。
///
/// - 不再要求输入账密：直接使用「用户页已绑定的统一认证账号」。
/// - v2.4.7：**可选学期**（最近 6 个学期，默认当前学期）。
/// - 「本学期还没有考试安排」属于正常状态（开学初很常见），按空状态展示，
///   不计为失败 —— 教务系统此时返回 200 + 空列表。
class ExamQueryPage extends ConsumerStatefulWidget {
  const ExamQueryPage({super.key});

  @override
  ConsumerState<ExamQueryPage> createState() =>
      _ExamQueryPageState();
}

class _ExamQueryPageState extends ConsumerState<ExamQueryPage> {
  bool _checking = true;
  bool _credentialBound = false;

  bool _querying = false;
  int _seconds = 0;
  Timer? _timer;

  List<Map<String, dynamic>> _exams = [];
  String? _semester;
  bool _fromCache = false;
  DateTime? _cacheUpdatedAt;
  String? _errorText;

  /// 已选学期（学年码 / 学期码，3=第1学期、12=第2学期）
  String _xnm = '';
  String _xqm = '';

  @override
  void initState() {
    super.initState();
    final current = _semesterOptions().first;
    _xnm = current.xnm;
    _xqm = current.xqm;
    _bootstrap();
  }

  /// 首次进入：先读本地缓存；**没有缓存时自动查一次** ——
  /// 查询按钮已收到右上角（刷新），不留「进去一片空白、不知道要点哪」的死路。
  Future<void> _bootstrap() async {
    await _load();
    await _loadCache();
    if (mounted && _credentialBound && _exams.isEmpty && !_querying) {
      unawaited(_query());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 可选学期：当前学期往前共 6 个（3 学年）。
  static List<({String xnm, String xqm, String label})> _semesterOptions() {
    final now = DateTime.now();
    var year = now.month >= 8 ? now.year : now.year - 1;
    var term = now.month >= 8 ? 3 : 12; // 8 月及以后 = 本学年第一学期
    final list = <({String xnm, String xqm, String label})>[];
    for (var i = 0; i < 6; i++) {
      list.add((
        xnm: '$year',
        xqm: '$term',
        label: '$year-${year + 1} 第${term == 3 ? 1 : 2}学期',
      ));
      if (term == 3) {
        year -= 1;
        term = 12;
      } else {
        term = 3;
      }
    }
    return list;
  }

  String get _selectedLabel {
    for (final o in _semesterOptions()) {
      if (o.xnm == _xnm && o.xqm == _xqm) return o.label;
    }
    return '$_xnm 学年';
  }

  Future<void> _pickSemester() async {
    final options = _semesterOptions();
    var currentIndex = 0;
    for (var i = 0; i < options.length; i++) {
      if (options[i].xnm == _xnm && options[i].xqm == _xqm) currentIndex = i;
    }
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
            for (var i = 0; i < options.length; i++)
              ListTile(
                dense: true,
                title: Text(options[i].label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: i == currentIndex
                          ? FontWeight.w700
                          : FontWeight.normal,
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
    setState(() {
      _xnm = options[picked].xnm;
      _xqm = options[picked].xqm;
      // 换了学期，之前的结果不属于它，清掉等重新查询
      _exams = [];
      _semester = null;
      _fromCache = false;
      _cacheUpdatedAt = null;
      _errorText = null;
    });
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

  Future<void> _loadCache() async {
    final cached = await ExamStorage.loadExams();
    if (cached.isEmpty || !mounted) return;
    final semester = await ExamStorage.loadSemester();
    final updatedAt = await ExamStorage.loadUpdatedAt();
    if (!mounted) return;
    setState(() {
      _exams = cached;
      _semester = semester;
      _fromCache = true;
      _cacheUpdatedAt = updatedAt;
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
      _errorText = null;
    });
    _startTimer();

    var fallbackApplied = false;
    try {
      // 不传账密：用本机已保存的凭证；学期用当前选择的
      final resp = await ApiService.fetchExams(
        xnm: _xnm,
        xqm: _xqm,
      );
      final data = resp['data'] as Map<String, dynamic>? ?? {};
      final rawList = (data['exams'] as List<dynamic>?) ?? [];
      final parsed =
          rawList.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      await ExamStorage.saveExams(parsed, semester: data['semester'] as String?);
      if (!mounted) return;
      setState(() {
        _exams = parsed;
        _semester = data['semester'] as String?;
        _fromCache = false;
        _cacheUpdatedAt = null;
      });
      if (parsed.isEmpty) _toast('本学期暂无考试安排');
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '').trim();
      // 查询失败但本地有缓存 → 继续展示缓存（不把已有内容清空）
      final cached = await ExamStorage.loadExams();
      if (cached.isNotEmpty && mounted) {
        final semester = await ExamStorage.loadSemester();
        final updatedAt = await ExamStorage.loadUpdatedAt();
        fallbackApplied = true;
        if (!mounted) return;
        setState(() {
          _exams = cached;
          _semester = semester;
          _fromCache = true;
          _cacheUpdatedAt = updatedAt;
        });
      } else if (mounted) {
        final text = msg.isEmpty ? '查询失败，请稍后重试' : msg;
        setState(() => _errorText = text);
        // 失败必须**明确弹横条**：此前只把错误写进页面主体，
        // 用户容易当成「点了没反应 / 获取失败也没反馈」。
        _toast(text);
      }
    } finally {
      _stopTimer();
      if (mounted) setState(() => _querying = false);
    }
    if (fallbackApplied) {
      _toast('教务系统暂时无法访问，已显示上次缓存的考试安排');
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
        title: const Text('考试安排',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        foregroundColor: isDark ? Colors.white : AppTheme.primaryColor,
        elevation: 0.5,
        // 仿掌上徐工：右上角一个刷新按钮（取代原来的大查询按钮）
        actions: [
          IconButton(
            onPressed: _querying ? null : _query,
            tooltip: '刷新考试安排',
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
                          ..._buildBody(isDark),
                          const SizedBox(height: 20),
                          _buildJwglEntry(isDark),
                          const SizedBox(height: 8),
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
                  _selectedLabel,
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

  List<Widget> _buildBody(bool isDark) {
    if (_errorText != null && _exams.isEmpty) {
      return [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.45)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_rounded,
                  size: 20, color: Color(0xFFEF4444)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _errorText!,
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
      ];
    }

    if (_exams.isEmpty) {
      return [
        _emptyState(isDark, Icons.event_busy_outlined,
            _semester == null ? '还没有查询结果，点上面的按钮开始查询' : '该学期暂无考试安排'),
      ];
    }

    return [
      // 仿掌上徐工：顶部一行小结（还剩几门）
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: SizedBox(
          width: double.infinity,
          child: Text(
            '还剩 ${_exams.length} 门考试',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.grey.shade400 : const Color(0xFF6B7280)),
          ),
        ),
      ),
      if (_semester != null)
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Row(
            children: [
              Text(
                _semester!,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.grey.shade300 : const Color(0xFF4B5563),
                ),
              ),
              if (_fromCache) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _cacheUpdatedAt == null
                        ? '缓存'
                        : '缓存 ${_cacheUpdatedAt!.month}/${_cacheUpdatedAt!.day}',
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFB45309)),
                  ),
                ),
              ],
            ],
          ),
        ),
      for (final e in _exams) _ExamTile(exam: e),
    ];
  }

  Widget _buildJwglEntry(bool isDark) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: OutlinedButton.icon(
        onPressed: () => _openExternal(kJwglLoginUrl),
        icon: const Icon(Icons.open_in_new_rounded, size: 19),
        label: const Text('在教务系统查询',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        style: OutlinedButton.styleFrom(
          foregroundColor: isDark ? Colors.grey.shade300 : const Color(0xFF4B5563),
          side: BorderSide(
              color: isDark ? const Color(0xFF3A3A3A) : const Color(0xFFD1D5DB)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
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

/// 单场考试卡片（版式仿掌上徐工）：
/// 第一行 = 课程名 + 地点 + 「补考」标记；第二行 = 时间 + 剩余天数。
class _ExamTile extends StatelessWidget {
  final Map<String, dynamic> exam;

  const _ExamTile({required this.exam});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.grey.shade400 : const Color(0xFF6B7280);
    final name = (exam['name'] ?? '未知科目').toString();
    final time = (exam['raw_time'] ?? '').toString().isNotEmpty
        ? exam['raw_time'].toString()
        : '${exam['date'] ?? ''} ${exam['start_time'] ?? ''}'.trim();
    final classroom = (exam['classroom'] ?? '').toString();
    final teacher = (exam['teacher'] ?? '').toString();
    // 教务系统不给「补考」标志位，用课程名判断（补考科目名里带「补考」）。
    final isResit = name.contains('补考');
    final days = _daysUntil(exam);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                ),
              ),
              if (classroom.isNotEmpty) ...[
                const SizedBox(width: 8),
                Icon(Icons.place_outlined, size: 15, color: muted),
                const SizedBox(width: 2),
                Text(classroom,
                    style: TextStyle(fontSize: 13, color: muted)),
              ],
              if (isResit) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('补考',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFEF4444))),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.schedule_rounded, size: 15, color: muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(time,
                    style: TextStyle(fontSize: 13.5, color: muted)),
              ),
              if (days != null && days >= 0)
                Text('$days 天',
                    style: TextStyle(fontSize: 13.5, color: muted)),
            ],
          ),
          if (teacher.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.person_outline_rounded, size: 15, color: muted),
                const SizedBox(width: 8),
                Text(teacher,
                    style: TextStyle(fontSize: 13, color: muted)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 距考试还有几天（`date` 形如 `2026-07-08`）。
  int? _daysUntil(Map<String, dynamic> e) {
    final d = DateTime.tryParse((e['date'] ?? '').toString().trim());
    if (d == null) return null;
    final today = DateTime.now();
    return DateTime(d.year, d.month, d.day)
        .difference(DateTime(today.year, today.month, today.day))
        .inDays;
  }
}
