import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/timetable/timetable_api.dart';
import '../../services/timetable/timetable_import_service.dart';
import '../../services/timetable/timetable_models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';
import '../../widgets/empty_state_art.dart';
import '../../widgets/state_views.dart';

/// 一个班级的全部已发布课表（多版本）。
///
/// 页面分三段（设计稿 R3）：①班级基础信息 ②多版本等宽两列网格 ③课程预览。
/// 第三段跟着第二段的选中项**实时切换，不再发请求** —— 所有版本的课程在
/// 打开页面时已经一次性拿到了，切版本只是换一份内存里的列表。
///
/// 为什么坚持「多版本并存 + 用户自己选」：同一个班两个同学传的课表可能都不
/// 完整（一个漏了实验课、一个漏了选修）。替用户挑一份「最准的」等于赌博，
/// 而版本卡上写了门数、时间、上传者，他自己一眼就能判断。
class TimetableClassPage extends StatefulWidget {
  const TimetableClassPage({super.key, required this.classKey, this.summary});

  final String classKey;

  /// 从检索页带过来的摘要。有就先渲染出班级名，不用等网络。
  final TimetableClassSummary? summary;

  @override
  State<TimetableClassPage> createState() => _TimetableClassPageState();
}

class _TimetableClassPageState extends State<TimetableClassPage> {
  bool _loading = true;
  String _error = '';
  TimetableClassDetail? _detail;
  int _selected = 0;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    final result = await TimetableApi.classDetail(widget.classKey);
    if (!mounted) return;
    if (!result.ok) {
      setState(() {
        _loading = false;
        _error = result.message;
      });
      return;
    }
    final detail = TimetableClassDetail.fromJson(result.data);
    setState(() {
      _loading = false;
      _detail = detail;
      // 默认选中最新那一版（服务端已按发布时间倒序）。
      _selected = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final title = detail?.bj.isNotEmpty == true
        ? detail!.bj
        : (widget.summary?.bj.isNotEmpty == true ? widget.summary!.bj : '班级课表');

    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: Text(title,
            style: const TextStyle(
                fontSize: AppTheme.fontHeading, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) {
      return ListView(children: [
        const SizedBox(height: 80),
        ErrorState(message: _error, onRetry: _load),
      ]);
    }
    final detail = _detail;
    if (detail == null || detail.timetables.isEmpty) {
      return ListView(children: [
        const SizedBox(height: 70),
        EmptyState(
          message: '这个班还没有已发布的课表',
          hint: '审核通过的课表会出现在这里',
          icon: Icons.event_busy_rounded,
          artVariant: EmptyArtVariant.calendar,
        ),
      ]);
    }

    final version = detail.timetables[_selected.clamp(0, detail.timetables.length - 1)];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _infoCard(detail),
          const SizedBox(height: 16),
          _sectionTitle('班级课表', trailing: '${detail.timetables.length} 个版本'),
          const SizedBox(height: 8),
          _versionGrid(detail),
          const SizedBox(height: 18),
          _sectionTitle('课程预览', trailing: 'v${version.version} · ${version.courses.length} 门'),
          const SizedBox(height: 8),
          if (version.note.trim().isNotEmpty) _noteCard(version),
          _coursePreview(version),
          const SizedBox(height: 20),
          _importButton(version),
          const SizedBox(height: 8),
          Center(
            child: Text(
              '导入会覆盖本机「${detail.bj}」的课表；其他班级和其他学期的课表不受影响。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text, {String? trailing}) {
    return Row(children: [
      Text(text,
          style: TextStyle(
              fontSize: AppTheme.fontBody,
              fontWeight: FontWeight.w600,
              color: context.textPrimary)),
      const Spacer(),
      if (trailing != null)
        Text(trailing,
            style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary)),
    ]);
  }

  Widget _infoCard(TimetableClassDetail d) {
    final term = TimetableTerm(d.xnm, d.xqm);
    return AppCard(
      radius: AppTheme.radiusMd,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Column(children: [
        _infoRow('学年学期', term.label),
        _divider(),
        _infoRow('学院', d.jgmc.isEmpty ? '未填' : d.jgmc),
        _divider(),
        _infoRow('专业', d.zymc.isEmpty ? '未填' : d.zymc),
        _divider(),
        _infoRow('班级', d.bj, last: true),
      ]),
    );
  }

  Widget _infoRow(String label, String value, {bool last = false}) {
    return Padding(
      padding: EdgeInsets.only(top: 9, bottom: last ? 9 : 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 66,
            child: Text(label,
                style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary)),
          ),
        ],
      ),
    );
  }

  Widget _divider() => Padding(
        padding: const EdgeInsets.only(top: 9),
        child: Container(height: 1, color: context.borderColor.withValues(alpha: .6)),
      );

  /// 等宽两列网格：版本卡只放三项（门数 / 时间 / 上传者）。
  ///
  /// 来源（本机课程表 / 导出的文件）**不占卡面** —— 它对"选哪一份"没有帮助，
  /// 只会把本来就只有三项的卡挤乱。需要的时候在课程预览下面的备注里能看到。
  Widget _versionGrid(TimetableClassDetail d) {
    final rows = <Widget>[];
    for (var i = 0; i < d.timetables.length; i += 2) {
      final left = d.timetables[i];
      final right = i + 1 < d.timetables.length ? d.timetables[i + 1] : null;
      rows.add(Padding(
        padding: EdgeInsets.only(bottom: i + 2 < d.timetables.length ? 10 : 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _versionCard(left, i)),
            const SizedBox(width: 10),
            Expanded(child: right == null ? const SizedBox.shrink() : _versionCard(right, i + 1)),
          ],
        ),
      ));
    }
    return Column(children: rows);
  }

  Widget _versionCard(TimetableVersion v, int index) {
    final on = index == _selected;
    return InkWell(
      onTap: () => setState(() => _selected = index),
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: on
              ? AppTheme.primaryColor.withValues(alpha: .08)
              : context.cardColor,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(
            color: on ? AppTheme.primaryColor : context.borderColor,
            width: on ? 1.4 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('v${v.version}',
                  style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                      color: on ? AppTheme.primaryColor : context.textPrimary)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(on ? '预览中' : '已发布',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: AppTheme.fontCaption,
                        color: on ? AppTheme.primaryColor : context.textTertiary)),
              ),
            ]),
            const SizedBox(height: 6),
            Text('${v.courses.length} 门课',
                style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textSecondary)),
            const SizedBox(height: 2),
            Text(timetableRelativeTime(v.publishedAt.isNotEmpty ? v.publishedAt : v.createdAt),
                style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary)),
            const SizedBox(height: 2),
            Text(v.uploaderName.isEmpty ? '匿名同学' : v.uploaderName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary)),
          ],
        ),
      ),
    );
  }

  Widget _noteCard(TimetableVersion v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: context.subtleFill,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_outline_rounded, size: 15, color: context.textTertiary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(v.note.trim(),
                style: TextStyle(
                    fontSize: AppTheme.fontCaption, height: 1.4, color: context.textSecondary)),
          ),
        ]),
      ),
    );
  }

  /// 按星期分组。空的那天不显示分组标题 —— 一周七行有五行是空的会让页面
  /// 看起来比实际长一倍。
  Widget _coursePreview(TimetableVersion v) {
    final byDay = <int, List<TimetableCourseItem>>{};
    for (final c in v.courses) {
      byDay.putIfAbsent(c.weekday, () => <TimetableCourseItem>[]).add(c);
    }
    final days = byDay.keys.toList()..sort();
    if (days.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text('这一版没有课程明细',
              style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
        ),
      );
    }

    const dayNames = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final blocks = <Widget>[];
    for (final day in days) {
      final list = byDay[day]!..sort((a, b) => a.startSlot.compareTo(b.startSlot));
      blocks.add(Padding(
        padding: EdgeInsets.only(top: blocks.isEmpty ? 0 : 12, bottom: 4),
        child: Text(dayNames[day],
            style: TextStyle(
                fontSize: AppTheme.fontSmall,
                fontWeight: FontWeight.w600,
                color: context.textSecondary)),
      ));
      for (final c in list) {
        blocks.add(_courseRow(c));
      }
    }
    return AppCard(
      radius: AppTheme.radiusMd,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: blocks),
    );
  }

  Widget _courseRow(TimetableCourseItem c) {
    final color = _colorForCourse(c.name);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 3,
          height: 34,
          margin: const EdgeInsets.only(top: 2, right: 8),
          decoration:
              BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppTheme.fontSmall,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary)),
                ),
                Text(c.slotLabel,
                    style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary)),
              ]),
              const SizedBox(height: 1),
              Text(
                [
                  if (c.teacher.isNotEmpty) c.teacher,
                  if (c.classroom.isNotEmpty) '@${c.classroom}',
                  if (c.weeks.isNotEmpty) c.weeks,
                ].join('  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  static const List<int> _colors = [
    0xFF3B82F6,
    0xFF10B981,
    0xFF8B5CF6,
    0xFFF59E0B,
    0xFFEC4899,
    0xFF14B8A6,
    0xFF6366F1,
    0xFF84CC16,
  ];

  Color _colorForCourse(String name) {
    var sum = 0;
    for (final unit in name.codeUnits) {
      sum = (sum + unit) & 0x7FFFFFFF;
    }
    return Color(_colors[sum % _colors.length]);
  }

  Widget _importButton(TimetableVersion v) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: _importing ? null : () => _import(v),
        style: FilledButton.styleFrom(
          backgroundColor: AppTheme.primaryColor,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 13),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
        ),
        child: _importing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
              )
            : Text('导入这份课表（v${v.version}）',
                style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }

  /// 导入前必须让用户看见自己会失去什么。
  ///
  /// 这一步不是"再确认一次"，而是唯一一次能看清差异的机会 —— 覆盖是一次性
  /// 替换，点下去本机那份旧课表就没了。
  Future<void> _import(TimetableVersion v) async {
    final detail = _detail;
    if (detail == null) return;

    setState(() => _importing = true);
    try {
      final existing = await TimetableImportService.findLocalTable(detail.bj);
      final oldCourses = existing?.courses ?? const [];
      final diff = TimetableImportService.diff(oldCourses, v.courses);

      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => _ImportConfirmDialog(
          className: detail.bj,
          term: TimetableTerm(detail.xnm, detail.xqm),
          version: v.version,
          courseCount: v.courses.length,
          hasExisting: existing != null,
          diff: diff,
        ),
      );
      if (ok != true || !mounted) return;

      await TimetableImportService.apply(
        bj: detail.bj,
        items: v.courses,
        xnm: detail.xnm,
        xqm: detail.xqm,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('已导入「${detail.bj}」的课表'),
          behavior: SnackBarBehavior.floating,
        ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('导入失败：$e'),
          behavior: SnackBarBehavior.floating,
        ));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }
}

/// 导入确认。破坏性操作，主按钮写「覆盖并导入」而不是「导入」。
class _ImportConfirmDialog extends StatelessWidget {
  const _ImportConfirmDialog({
    required this.className,
    required this.term,
    required this.version,
    required this.courseCount,
    required this.hasExisting,
    required this.diff,
  });

  final String className;
  final TimetableTerm term;
  final int version;
  final int courseCount;
  final bool hasExisting;
  final TimetableDiffSummary diff;

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
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 16, 10),
      title: Row(children: [
        Expanded(
          child: Text(hasExisting ? '覆盖本机课表？' : '导入这份课表？',
              style: const TextStyle(
                  fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
        ),
        IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ]),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _kv(context, '课表名称', className),
              _kv(context, '学年学期', term.label),
              _kv(context, '课程数', '$courseCount 门（v$version）'),
              if (hasExisting) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: context.warningColor.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    border: Border.all(color: context.warningColor.withValues(alpha: .35)),
                  ),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.warning_amber_rounded, size: 16, color: context.warningColor),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('将覆盖你已有的「$className」课表。',
                          style: TextStyle(
                              fontSize: AppTheme.fontSmall,
                              height: 1.4,
                              color: context.warningColor)),
                    ),
                  ]),
                ),
              ],
              if (diff.hasChanges) ...[
                const SizedBox(height: 12),
                _diffBlock(context),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('取消',
                    style: TextStyle(fontSize: AppTheme.fontBody, color: context.textSecondary)),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: hasExisting ? context.dangerColor : AppTheme.primaryColor,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
          ),
          child: Text(hasExisting ? '覆盖并导入' : '导入',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 62,
            child: Text(k,
                style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
          ),
          Expanded(
            child: Text(v,
                style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textPrimary)),
          ),
        ],
      ),
    );
  }

  Widget _diffBlock(BuildContext context) {
    // 明细最多列 8 条：全列出来在手机上会撑出一屏，用户反而看不到按钮。
    final details = diff.details.take(8).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('和本机这份的差别',
            style: TextStyle(
                fontSize: AppTheme.fontSmall,
                fontWeight: FontWeight.w600,
                color: context.textSecondary)),
        const SizedBox(height: 6),
        if (diff.added > 0)
          _diffLine(context, '+ 新增 ${diff.added} 门', context.successColor),
        if (diff.changed > 0)
          _diffLine(context, '~ 变更 ${diff.changed} 门', context.warningColor),
        if (diff.removed > 0)
          _diffLine(context, '− 移除 ${diff.removed} 门', context.dangerColor),
        const SizedBox(height: 4),
        for (final d in details)
          Padding(
            padding: const EdgeInsets.only(bottom: 3, left: 2),
            child: Text(
              '· ${d.name}${d.detail.isEmpty ? '' : '（${d.detail}）'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary),
            ),
          ),
        if (diff.details.length > details.length)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text('…还有 ${diff.details.length - details.length} 条',
                style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary)),
          ),
      ],
    );
  }

  Widget _diffLine(BuildContext context, String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(text,
          style: TextStyle(
              fontSize: AppTheme.fontSmall, fontWeight: FontWeight.w600, color: color)),
    );
  }
}
