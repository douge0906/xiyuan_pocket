import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/study_models.dart';
import '../../providers/user_config_provider.dart';
import '../../services/api_service.dart';
import '../../services/campus/jwgl_client.dart';
import '../../services/study_store.dart';
import '../../theme/app_theme.dart';
import '../../widgets/empty_state_art.dart';
import '../../widgets/loading_overlay.dart';
import '../../widgets/state_views.dart';

/// 我的学业 —— 把教务「学生学业情况查询」（`N105515`）搬进 App。
///
/// 一页五层（用户 2026-11-02 定的结构）：
///
/// ```
/// ┌ 顶栏      我的学业                          [刷新]
/// ├ 总览卡    GPA 3.62 · 计划135门 · 通过17门 · 在读15门
/// │           ━━━━━━━━░░░░░░  40 / 165 学分
/// ├ 状态筛选  全部 / 未过 / 在读 / 未修 / 已修
/// ├ 折叠板块  通识（必）       27门 通过14        🔴
/// │             · 每题：名称 / 性质·学分·学时 / 状态徽章
/// └ 页脚      数据来自教务 · <抓取时间>
/// ```
///
/// ## 三条设计取舍
///
/// 1. **总览数字全部照抄教务**，不自己算。教务页顶部就有「计划总课程 135 门
///    通过 17 门 未通过 0 门 未修 103 门 在读 15 门」，自己算必然和学校页面
///    对不上，用户一眼就发现。
/// 2. **课程行只给三样**：名称、`性质 · 学分 · 学时`、状态徽章。用户明确要求
///    「课程只标注重要信息」，成绩/绩点/建议学期都塞进点开的详情里。
/// 3. **拿不到培养方案就直说**。教务没给这一届配培养方案时显示
///    「教务暂未配置培养方案」，不伪造一份「未修」清单 —— 课表里没有的课，
///    我们根本不知道存不存在。
class MyStudyPage extends ConsumerStatefulWidget {
  const MyStudyPage({super.key});

  @override
  ConsumerState<MyStudyPage> createState() => _MyStudyPageState();
}

class _MyStudyPageState extends ConsumerState<MyStudyPage> {
  bool _checking = true;
  bool _credentialBound = false;

  bool _loading = false;
  int _seconds = 0;
  Timer? _timer;

  StudyArchive? _archive;
  bool _fromCache = false;
  DateTime? _cacheUpdatedAt;
  String? _errorText;

  /// 当前状态筛选。空集合 = 全部。
  Set<StudyState> _filter = {};

  /// 展开的板块 id。
  final Set<String> _expanded = <String>{};

  /// 当前学年 / 学期（Mode B 查课表要用；`xqm` 3=第1学期、12=第2学期）
  String _xnm = '';
  String _xqm = '';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _xnm = '${now.month >= 8 ? now.year : now.year - 1}';
    _xqm = now.month >= 8 ? '3' : '12';
    _bootstrap();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 首次进入：先读本机已绑定的账号 → 再读缓存 → 都没有就自动抓一次。
  ///
  /// 「自动抓一次」是有意的：进来一片空白、还要用户自己找右上角刷新，
  /// 是这轮刚统一掉的死路（考试页/教材页同规矩）。
  Future<void> _bootstrap() async {
    final config = await ref.read(userConfigProvider.notifier).ensureLoaded();
    if (!mounted) return;
    setState(() {
      _credentialBound = config.username.trim().isNotEmpty;
      _checking = false;
    });

    await _loadCache();
    if (mounted && _credentialBound && _archive == null && !_loading) {
      unawaited(_refresh(silent: true));
    }
  }

  Future<void> _loadCache() async {
    final cached = await StudyStore.load();
    if (cached == null || !mounted) return;
    final updatedAt = await StudyStore.loadUpdatedAt();
    if (!mounted) return;
    setState(() {
      _archive = cached;
      _fromCache = true;
      _cacheUpdatedAt = updatedAt;
      // 默认展开第一个板块：一进来就有内容，不用先点一下
      if (cached.blocks.isNotEmpty && _expanded.isEmpty) {
        _expanded.add(cached.blocks.first.id);
      }
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

  Future<void> _refresh({bool silent = false}) async {
    // 🔴 重入保护：连点刷新会并发抓 10 个板块，后完成的旧结果会覆盖新的
    if (_loading) return;
    setState(() {
      _loading = true;
      _errorText = null;
    });
    _startTimer();

    try {
      final data = await ApiService.fetchStudy(xnm: _xnm, xqm: _xqm);
      final archive = data['data'] as StudyArchive;
      await StudyStore.save(archive);
      if (!mounted) return;
      setState(() {
        _archive = archive;
        _fromCache = false;
        _cacheUpdatedAt = null;
        if (archive.blocks.isNotEmpty &&
            !_expanded.contains(archive.blocks.first.id) &&
            _expanded.isEmpty) {
          _expanded.add(archive.blocks.first.id);
        }
      });
    } catch (e) {
      final msg = _humanize(e);
      if (!mounted) return;
      // 抓取失败但本机有缓存 → 继续展示缓存，不清空（本项目的铁律）
      if (_archive != null) {
        setState(() => _errorText = msg);
        if (!silent) _toast(msg);
      } else {
        setState(() => _errorText = msg);
      }
    } finally {
      _stopTimer();
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 异常文案：`CampusException` 自带中文，其他异常去掉 `Exception: ` 前缀。
  String _humanize(Object e) {
    if (e is CampusException) return e.message;
    return e.toString().replaceFirst('Exception: ', '').trim();
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
        title:
            const Text('我的学业', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: context.cardColor,
        foregroundColor: isDark ? Colors.white : AppTheme.primaryColor,
        elevation: 0,
        actions: [
          IconButton(
            onPressed: _loading || !_credentialBound ? null : _refresh,
            tooltip: '重新获取学业数据',
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
          : !_credentialBound
              ? _buildNeedLogin()
              : Stack(
                  children: [
                    Positioned.fill(child: _buildBody(isDark)),
                    if (_loading)
                      Positioned.fill(
                        child: LoadingOverlay(
                          seconds: _seconds,
                          message: '正在从教务系统读取学业数据，请稍候…',
                        ),
                      ),
                  ],
                ),
    );
  }

  Widget _buildNeedLogin() {
    return EmptyState(
      message: '请先登录统一认证账号',
      hint: '「我的学业」要读取你在教务系统里的培养方案\n请到「我的」页面完成登录',
      artVariant: EmptyArtVariant.report,
    );
  }

  Widget _buildBody(bool isDark) {
    final archive = _archive;
    if (archive == null) {
      if (_errorText != null) {
        return ErrorState(message: _errorText!, onRetry: _refresh);
      }
      return const EmptyState(
        message: '还没有学业数据',
        hint: '点右上角刷新，从教务系统读取一次',
        artVariant: EmptyArtVariant.report,
      );
    }

    // 「教务暂未配置」是确定的结论，不是加载失败 —— 不显示重试按钮
    if (archive.isUnconfigured && archive.blocks.isEmpty) {
      return EmptyState(
        message: '教务暂未配置培养方案',
        hint: '${archive.notice}\n'
            '这是教务系统对你这届学生的状态，不是 App 的问题。\n'
            '学校配置完成后，点右上角刷新即可看到。',
        artVariant: EmptyArtVariant.report,
      );
    }

    final blocks = _filter.isEmpty ? archive.blocks : archive.filtered(_filter);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        if (_errorText != null) ...[
          _buildErrorBanner(isDark, _errorText!),
          const SizedBox(height: 12),
        ],
        _buildOverview(archive, isDark),
        const SizedBox(height: 16),
        _buildFilters(archive, isDark),
        const SizedBox(height: 12),
        if (blocks.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: EmptyState(
              message: '当前筛选下没有课程',
              hint: '换一个状态看看，或点「全部」',
              artVariant: EmptyArtVariant.search,
            ),
          )
        else
          for (final b in blocks) ...[
            _buildBlock(b, isDark),
            const SizedBox(height: 10),
          ],
        const SizedBox(height: 8),
        _buildFooter(archive),
      ],
    );
  }

  // ==================== ① 总览卡 ====================

  Widget _buildOverview(StudyArchive a, bool isDark) {
    final creditText = _creditLine(a);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (a.gpa != null) ...[
                Text(
                  a.gpa!.toStringAsFixed(2),
                  style: TextStyle(
                    fontSize: 30,
                    height: 1.0,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    color: context.textPrimary,
                  ),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text('GPA',
                      style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          height: 1.0,
                          color: context.textTertiary)),
                ),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  children: [
                    if (a.totalCourses != null)
                      _metric('计划', '${a.totalCourses}门'),
                    if (a.passedCourses != null)
                      _metric('通过', '${a.passedCourses}门'),
                    if (a.studyingCourses != null)
                      _metric('在读', '${a.studyingCourses}门'),
                  ],
                ),
              ),
            ],
          ),
          if (a.major.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    a.major,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall, color: context.textSecondary),
                  ),
                ),
                if (a.mode == StudyMode.degraded)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.warning.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('仅课表',
                        style: TextStyle(
                            fontSize: 10, color: Color(0xFFB45309))),
                  ),
              ],
            ),
          ],
          if (creditText != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: _creditProgress(a),
                minHeight: 5,
                backgroundColor: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : const Color(0xFFF1F3F5),
                valueColor: AlwaysStoppedAnimation<Color>(
                    AppTheme.primaryColor.withValues(alpha: 0.55)),
              ),
            ),
            const SizedBox(height: 6),
            Text(creditText,
                style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
          ],
        ],
      ),
    );
  }

  Widget _metric(String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: TextStyle(
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w600,
                color: context.textPrimary)),
        const SizedBox(width: 3),
        Text(label,
            style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary)),
      ],
    );
  }

  /// `已获 40 / 要求 165 学分`。两个值都得有才显示 —— 只有一个时算不出进度，
  /// 显示出来只会让人以为「还差 0 分」。
  String? _creditLine(StudyArchive a) {
    final got = a.earnedCredits;
    final need = a.requiredCredits;
    if (got == null || need == null || need <= 0) return null;
    return '已获 ${_trim(got)} / 要求 ${_trim(need)} 学分';
  }

  double _creditProgress(StudyArchive a) {
    final got = a.earnedCredits;
    final need = a.requiredCredits;
    if (got == null || need == null || need <= 0) return 0;
    return (got / need).clamp(0.0, 1.0);
  }

  // ==================== ② 状态筛选 ====================

  Widget _buildFilters(StudyArchive a, bool isDark) {
    final counts = a.stateCounts;
    final total = a.allCourses.length;

    final items = <(Set<StudyState>, String, int)>[
      (const <StudyState>{}, '全部', total),
      ({StudyState.failed}, '未过', counts[StudyState.failed] ?? 0),
      ({StudyState.studying}, '在读', counts[StudyState.studying] ?? 0),
      ({StudyState.notStarted}, '未修', counts[StudyState.notStarted] ?? 0),
      ({StudyState.passed}, '已修', counts[StudyState.passed] ?? 0),
      if ((counts[StudyState.replaced] ?? 0) > 0)
        ({StudyState.replaced}, '替代', counts[StudyState.replaced] ?? 0),
    ];

    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final (states, label, count) = items[i];
          // 「未过」为 0 时不出按钮：点进去是空的，纯属干扰
          if (label == '未过' && count == 0) return const SizedBox.shrink();
          final selected = _setEquals(_filter, states);
          return ChoiceChip(
            label: Text(
              count > 0 ? '$label $count' : label,
              style: const TextStyle(fontSize: AppTheme.fontSmall),
            ),
            selected: selected,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => setState(() {
              _filter = states;
              // 换筛选后原来展开的板块可能不存在了，清掉重开第一个
              _expanded.clear();
            }),
          );
        },
      ),
    );
  }

  static bool _setEquals(Set<StudyState> a, Set<StudyState> b) =>
      a.length == b.length && a.every(b.contains);

  // ==================== ③ 折叠板块 ====================

  Widget _buildBlock(StudyBlock b, bool isDark) {
    final open = _expanded.contains(b.id);
    return Container(
      decoration: BoxDecoration(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: context.borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() {
              if (open) {
                _expanded.remove(b.id);
              } else {
                _expanded.add(b.id);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Column(
                children: [
                  Row(
                    children: [
                      _statusDot(b),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          b.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTheme.fontBody,
                            fontWeight: FontWeight.w600,
                            color: context.textPrimary,
                          ),
                        ),
                      ),
                      Text(
                        '${b.courseCount}门 · 通过 ${b.passedCount}',
                        style: TextStyle(
                            fontSize: AppTheme.fontSmall, color: context.textTertiary),
                      ),
                      const SizedBox(width: 2),
                      AnimatedRotation(
                        turns: open ? 0.5 : 0,
                        duration: const Duration(milliseconds: 160),
                        child: Icon(Icons.keyboard_arrow_down_rounded,
                            size: 20, color: context.textTertiary),
                      ),
                    ],
                  ),
                  if (open) ...[
                    const SizedBox(height: 10),
                    _buildBlockStats(b, isDark),
                  ],
                ],
              ),
            ),
          ),
          if (open)
            Container(
              width: double.infinity,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.02)
                  : const Color(0xFFFAFBFC),
              child: Column(
                children: [
                  for (final c in b.courses) _buildCourseRow(c, isDark),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 状态点：未过 → 红；有未达标 → 黄；全通过 → 绿；空板块 → 灰。
  Widget _statusDot(StudyBlock b) {
    late final Color color;
    if (b.courses.isEmpty) {
      color = context.textTertiary.withValues(alpha: 0.5);
    } else if (b.courses.any((c) => c.state == StudyState.failed)) {
      color = AppTheme.danger;
    } else if (!b.isComplete) {
      color = AppTheme.warning;
    } else {
      color = AppTheme.success;
    }
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  /// 展开后的统计行。**只显示有值的** —— 教务对子板块的「要求学分」一律给 `1.0`
  /// （实测 10 个子节点全是这个怪值），显示出来只会让人以为「这板块只要 1 学分」。
  Widget _buildBlockStats(StudyBlock b, bool isDark) {
    final parts = <String>['学分合计 ${_trim(b.courseCredits)}'];
    if (b.earnedCredits != null && b.earnedCredits! > 0) {
      parts.add('已获 ${_trim(b.earnedCredits!)}');
    }
    if (b.courses.any((c) => c.state == StudyState.studying)) {
      final n = b.courses.where((c) => c.state == StudyState.studying).length;
      parts.add('在读 $n');
    }
    if (b.courses.any((c) => c.state == StudyState.failed)) {
      final n = b.courses.where((c) => c.state == StudyState.failed).length;
      parts.add('未过 $n');
    }
    return Row(
      children: [
        Expanded(
          child: Text(
            parts.join(' · '),
            style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textSecondary),
          ),
        ),
        Text('完成 ${(b.progress * 100).round()}%',
            style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary)),
      ],
    );
  }

  // ==================== ④ 课程行 ====================

  Widget _buildCourseRow(StudyCourse c, bool isDark) {
    return InkWell(
      onTap: () => _showCourseDetail(c),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: context.borderColor.withValues(alpha: 0.5),
              width: 0.6,
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      height: 1.3,
                      color: context.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    c.subtitleLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall,
                        height: 1.3,
                        color: context.textTertiary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _stateBadge(c.state),
          ],
        ),
      ),
    );
  }

  Widget _stateBadge(StudyState s) {
    late final Color color;
    switch (s) {
      case StudyState.failed:
        color = AppTheme.danger;
        break;
      case StudyState.studying:
        color = AppTheme.primaryColor;
        break;
      case StudyState.notStarted:
        color = context.textTertiary;
        break;
      case StudyState.passed:
        color = AppTheme.success;
        break;
      case StudyState.replaced:
        color = const Color(0xFF8B5CF6);
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        s.label,
        style: TextStyle(
            fontSize: AppTheme.fontCaption, height: 1.1, color: color, fontWeight: FontWeight.w500),
      ),
    );
  }

  /// 课程详情：**居中 Dialog**（R8：禁底部弹窗），右上角 ×。
  void _showCourseDetail(StudyCourse c) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor:
            context.cardColor,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLg)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                        c.name,
                        style: TextStyle(
                          fontSize: AppTheme.fontTitle,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    icon: Icon(Icons.close_rounded,
                        size: 20, color: context.textTertiary),
                    splashRadius: 18,
                  ),
                ],
              ),
              const SizedBox(height: 2),
              _detailRow('修读状态',
                  c.state.label + (c.stateFromServer ? '' : '（客户端推导）')),
              if (c.courseNo.isNotEmpty) _detailRow('课程号', c.courseNo),
              _detailRow('课程性质', c.nature.isEmpty ? '—' : c.nature),
              _detailRow('课程类别', c.category.isEmpty ? '—' : c.category),
              _detailRow('学分', _trim(c.credits)),
              if (c.hours.isNotEmpty) _detailRow('学时', c.hours),
              if (c.studyYear.isNotEmpty || c.studyTerm.isNotEmpty)
                _detailRow(
                    '修读学期',
                    [c.studyYear, c.studyTerm]
                        .where((e) => e.isNotEmpty)
                        .join(' ')),
              if (c.suggestYear.isNotEmpty || c.suggestTerm.isNotEmpty)
                _detailRow(
                    '建议学期',
                    [c.suggestYear, c.suggestTerm]
                        .where((e) => e.isNotEmpty)
                        .join(' ')),
              if (c.hasScore) ...[
                const SizedBox(height: 4),
                Container(height: 0.6, color: context.borderColor),
                const SizedBox(height: 4),
                if (c.score.isNotEmpty) _detailRow('成绩', c.score),
                if (c.maxScore.isNotEmpty && c.maxScore != c.score)
                  _detailRow('最高成绩', c.maxScore),
                if (c.gpa.isNotEmpty) _detailRow('绩点', c.gpa),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 68,
            child: Text(label,
                style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                  fontSize: AppTheme.fontSmall, height: 1.4, color: context.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== ⑤ 错误条 / 页脚 ====================

  Widget _buildErrorBanner(bool isDark, String msg) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.danger.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_rounded, size: 18, color: Color(0xFFEF4444)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$msg\n下面是上次成功获取的数据。',
              style: TextStyle(
                  fontSize: AppTheme.fontSmall, height: 1.5, color: context.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(StudyArchive a) {
    final at = a.fetchedAt ?? _cacheUpdatedAt;
    final parts = <String>['数据来自正方教务系统'];
    if (a.mode == StudyMode.degraded) parts.add('教务暂未配置培养方案，按课程类别分组');
    if (a.notice.isNotEmpty && a.mode != StudyMode.degraded) {
      parts.add(a.notice);
    }
    if (at != null) parts.add('更新于 ${_fmtTime(at)}');
    if (_fromCache) parts.add('本地缓存');

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        parts.join(' · '),
        textAlign: TextAlign.center,
        style: TextStyle(
            fontSize: AppTheme.fontCaption, height: 1.7, color: context.textTertiary),
      ),
    );
  }

  static String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.month}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  /// `6.0` → `6`，`2.5` → `2.5`。学分不拖 `.0` 尾巴。
  static String _trim(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(1);
  }
}
