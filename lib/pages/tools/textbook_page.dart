import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/user_config_provider.dart';
import '../../services/api_service.dart';
import '../../services/textbook_storage.dart';
import '../../theme/app_theme.dart';

/// 我的教材。
///
/// 数据来自教务处「教材预订」（`选课 → 教材预订`），**客户端直抓**：
/// 先打开业务页拿 csrftoken，再 POST 查询接口，解析正方返回的 JSON。
/// 学期可选（默认当前学期），结果缓存在本地，下次进入先显示再刷新。
class TextbookPage extends ConsumerStatefulWidget {
  const TextbookPage({super.key});

  @override
  ConsumerState<TextbookPage> createState() => _TextbookPageState();
}

class _TextbookPageState extends ConsumerState<TextbookPage> {
  bool _checking = true;
  bool _credentialBound = false;

  bool _loading = false;
  int _seconds = 0;
  Timer? _timer;

  List<Map<String, dynamic>> _books = [];
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

  Future<void> _bootstrap() async {
    await _load();
    await _loadCache();
    if (mounted && _credentialBound && _books.isEmpty && !_loading) {
      unawaited(_query());
    }
  }

  Future<void> _load() async {
    final config = await ref.read(userConfigProvider.notifier).ensureLoaded();
    if (!mounted) return;
    final bound = config.username.trim().isNotEmpty;
    setState(() {
      _credentialBound = bound;
      _checking = false;
    });
  }

  Future<void> _loadCache() async {
    final cached = await TextbookStorage.loadBooks();
    if (cached.isEmpty || !mounted) return;
    final semester = await TextbookStorage.loadSemester();
    final updatedAt = await TextbookStorage.loadUpdatedAt();
    if (!mounted) return;
    setState(() {
      _books = cached;
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
      _loading = true;
      _errorText = null;
    });
    _startTimer();

    var fallbackApplied = false;
    try {
      final resp = await ApiService.fetchTextbooks(xnm: _xnm, xqm: _xqm);
      final data = resp['data'] as Map<String, dynamic>? ?? {};
      final rawList = (data['books'] as List<dynamic>?) ?? [];
      final parsed =
          rawList.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      await TextbookStorage.saveBooks(parsed,
          semester: data['semester'] as String?);
      if (!mounted) return;
      setState(() {
        _books = parsed;
        _semester = data['semester'] as String?;
        _fromCache = false;
        _cacheUpdatedAt = null;
      });
      if (parsed.isEmpty) _toast('本学期暂无教材信息');
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '').trim();
      // 查询失败但本地有缓存 → 继续展示缓存（不把已有内容清空）
      final cached = await TextbookStorage.loadBooks();
      if (cached.isNotEmpty && mounted) {
        final semester = await TextbookStorage.loadSemester();
        final updatedAt = await TextbookStorage.loadUpdatedAt();
        fallbackApplied = true;
        if (!mounted) return;
        setState(() {
          _books = cached;
          _semester = semester;
          _fromCache = true;
          _cacheUpdatedAt = updatedAt;
        });
      } else if (mounted) {
        final text = msg.isEmpty ? '查询失败，请稍后重试' : msg;
        setState(() => _errorText = text);
        // 失败必须有明确反馈（否则用户会觉得「点了没反应」）
        _toast(text);
      }
    } finally {
      _stopTimer();
      if (mounted) setState(() => _loading = false);
    }
    if (fallbackApplied) {
      _toast('教务系统暂时无法访问，已显示上次缓存的教材信息');
    }
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
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: i == currentIndex
                          ? AppTheme.primaryColor
                          : context.textPrimary,
                    )),
                trailing: i == currentIndex
                    ? Icon(Icons.check_rounded,
                        size: 18, color: AppTheme.primaryColor)
                    : null,
                onTap: () => Navigator.pop(ctx, i),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _xnm = options[picked].xnm;
      _xqm = options[picked].xqm;
      // 换了学期，之前的结果不属于它，清掉等重新查询
      _books = [];
      _semester = null;
      _fromCache = false;
      _cacheUpdatedAt = null;
      _errorText = null;
    });
    await _query();
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
      backgroundColor:
          isDark ? const Color(0xFF121212) : AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('我的教材',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        foregroundColor: isDark ? Colors.white : AppTheme.primaryColor,
        elevation: 0.5,
        actions: [
          IconButton(
            onPressed: _loading ? null : _query,
            tooltip: '刷新教材',
            icon: _loading
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
          : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  children: [
                    _buildSemesterRow(isDark),
                    const SizedBox(height: 16),
                    ..._buildBody(isDark),
                  ],
                ),
    );
  }

  /// 学期选择（点击弹出选择面板）—— 与考试页同一形态。
  Widget _buildSemesterRow(bool isDark) {
    return Material(
      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: _loading ? null : _pickSemester,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: context.borderColor),
          ),
          child: Row(
            children: [
              Icon(Icons.date_range_rounded,
                  size: 20,
                  color:
                      isDark ? Colors.grey.shade400 : const Color(0xFF9CA3AF)),
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
                  color:
                      isDark ? Colors.grey.shade400 : const Color(0xFF9CA3AF)),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildBody(bool isDark) {
    if (_loading && _books.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 60),
          child: Column(
            children: [
              const CircularProgressIndicator(strokeWidth: 2.5),
              const SizedBox(height: 14),
              Text('正在获取教材信息，已等待 $_seconds 秒',
                  style: TextStyle(
                      fontSize: 12.5,
                      color: isDark
                          ? Colors.grey.shade400
                          : const Color(0xFF6B7280))),
            ],
          ),
        ),
      ];
    }

    if (_errorText != null && _books.isEmpty) {
      return [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border:
                Border.all(color: const Color(0xFFEF4444).withOpacity(0.45)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
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
                          color: context.textPrimary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 42,
                child: OutlinedButton(
                  onPressed: _loading ? null : _query,
                  child: const Text('重新获取'),
                ),
              ),
            ],
          ),
        ),
      ];
    }

    if (_visibleBooks.isEmpty) {
      return [_emptyState(isDark)];
    }

    return [
      if (_semester != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              Text(_semester!,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? Colors.grey.shade300
                        : const Color(0xFF4B5563),
                  )),
              if (_fromCache) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
      for (final b in _visibleBooks) _buildBookCard(isDark, b),
    ];
  }




  /// 实际展示的教材：**只保留「当前选中的学期」且「确实有教材」的条目**。
  ///
  /// 两条过滤都来自用户实测反馈：
  ///   ① 列表里混着**无教材的课程**（教材信息为空）→ 不该显示；
  ///   ② 列表里可能混着**其它学期**的教材 → 「按学期」应表现为**筛选**，而不是分组平铺。
  ///
  /// 过滤刻意保守：**只有条目确实带了学期字段、且与选中值不一致时才剔除**；
  /// 拿不到学期字段的条目一律保留 —— 否则一旦教务返回的字段名对不上，会把内容全过滤光。
  List<Map<String, dynamic>> get _visibleBooks {
    final sem = _xnm.trim();
    final term = _xqm.trim();
    return _books.where((b) {
      // ① 没有教材信息 → 不显示
      if ((b['book'] ?? '').toString().trim().isEmpty) return false;
      // ② 学期不匹配 → 不显示（字段缺失时不参与判断）
      final bs = (b['semester'] ?? '').toString().trim();
      final bt = (b['term'] ?? '').toString().trim();
      if (bs.isNotEmpty && !_sameSemester(bs, sem)) return false;
      if (bt.isNotEmpty && !_sameTerm(bt, term)) return false;
      return true;
    }).toList();
  }

  /// 学年比较：兼容 `2026` / `2026-2027` / `2026学年` 等写法（取其中的四位年份）。
  static bool _sameSemester(String got, String want) {
    if (got == want) return true;
    final g = RegExp(r'\d{4}').firstMatch(got)?.group(0);
    final w = RegExp(r'\d{4}').firstMatch(want)?.group(0);
    return g != null && w != null && g == w;
  }

  /// 学期比较：兼容编码（3 = 第一学期 / 12 = 第二学期）与 `1`/`2`、`第一学期` 等写法。
  static bool _sameTerm(String got, String want) {
    if (got == want) return true;
    int? norm(String s) {
      if (s.contains('一') || s == '1' || s == '3') return 1;
      if (s.contains('二') || s == '2' || s == '12') return 2;
      return null;
    }

    final g = norm(got);
    final w = norm(want);
    return g != null && g == w;
  }

  /// 单条教材卡片：课程名 + 征订状态 / 性质·教师 / 教材信息 / 上课地点。
  Widget _buildBookCard(bool isDark, Map<String, dynamic> b) {
    final muted = isDark ? Colors.grey.shade400 : const Color(0xFF6B7280);
    final name = (b['name'] ?? '').toString().trim();
    final teacher = (b['teacher'] ?? '').toString().trim();
    final nature = (b['nature'] ?? '').toString().trim();
    final book = (b['book'] ?? '').toString().trim();
    final classroom = (b['classroom'] ?? '').toString().trim();
    final status = (b['status'] ?? '').toString().trim();
    final meta = [
      if (nature.isNotEmpty) nature,
      if (teacher.isNotEmpty) teacher,
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        border: Border.all(color: context.borderColor),
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
                  name.isEmpty ? '未知课程' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                ),
              ),
              if (status.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: muted.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(status,
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: muted)),
                ),
              ],
            ],
          ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.school_outlined, size: 15, color: muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(meta,
                      style: TextStyle(fontSize: 13.5, color: muted)),
                ),
              ],
            ),
          ],
          if (book.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.menu_book_outlined, size: 15, color: muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(book,
                      style: TextStyle(fontSize: 13.5, color: muted)),
                ),
              ],
            ),
          ],
          if (classroom.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.place_outlined, size: 15, color: muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(classroom,
                      style: TextStyle(fontSize: 13.5, color: muted)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _emptyState(bool isDark) {
    final muted = isDark ? Colors.grey.shade400 : const Color(0xFF9CA3AF);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A1A) : Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(Icons.menu_book_rounded, size: 44, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(
            '暂无教材',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: context.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _semester == null
                ? '点右上角刷新获取本学期教材'
                : '$_semester 暂无教材预订信息',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.6, color: muted),
          ),
        ],
      ),
    );
  }

}
