import 'package:flutter/material.dart';

import '../models/course_model.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

/// 跨专业自选 · 班级选择页。
///
/// 打开时从服务端拉全量班级（教务 357 个班，服务端缓存 30 分钟），
/// 本地按 关键字 / 年级 / 学院 过滤 —— 过滤不发请求。
/// 点选一个班 → 取它的课表 → 预览确认 → 把结果 pop 回调用方落库。
class ClassPickerPage extends StatefulWidget {
  const ClassPickerPage({
    super.key,
    required this.xnm,
    required this.xqm,
  });

  final String xnm;
  final String xqm;

  @override
  State<ClassPickerPage> createState() => _ClassPickerPageState();
}

class _ClassPickerPageState extends State<ClassPickerPage> {
  final TextEditingController _searchCtl = TextEditingController();
  final ScrollController _scrollCtl = ScrollController();

  List<Map<String, dynamic>> _all = [];
  List<Map<String, dynamic>> _shown = [];
  List<String> _grades = [];
  List<String> _colleges = [];

  bool _loading = true;
  String? _error;
  String? _loadingBhId; // 正在取课表的那一行

  String? _grade; // 年级过滤（null = 全部）
  String? _college; // 学院过滤（null = 全部）

  bool get _dark => Theme.of(context).brightness == Brightness.dark;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resp = await ApiService.searchClassList(
        xnm: widget.xnm,
        xqm: widget.xqm,
      );
      final data = resp['data'] as Map<String, dynamic>? ?? {};
      final list = (data['classes'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (!mounted) return;
      setState(() {
        _all = list;
        _loading = false;
        _grades = list
            .map((e) => (e['njdm_id'] ?? '').toString())
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
        _colleges = list
            .map((e) => (e['jgmc'] ?? '').toString())
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
        _applyFilter();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '班级列表加载失败，请检查网络后重试';
      });
    }
  }

  void _applyFilter() {
    final kw = _searchCtl.text.trim().toLowerCase();
    setState(() {
      _shown = _all.where((c) {
        final grade = (c['njdm_id'] ?? '').toString();
        final college = (c['jgmc'] ?? '').toString();
        if (_grade != null && grade != _grade) return false;
        if (_college != null && college != _college) return false;
        if (kw.isEmpty) return true;
        return (c['bj'] ?? '').toString().toLowerCase().contains(kw) ||
            (c['zymc'] ?? '').toString().toLowerCase().contains(kw) ||
            college.toLowerCase().contains(kw);
      }).toList();
    });
  }

  Future<void> _pick(Map<String, dynamic> c) async {
    final bhId = (c['bh_id'] ?? '').toString();
    if (bhId.isEmpty || _loadingBhId != null) return;
    setState(() => _loadingBhId = bhId);
    try {
      final resp = await ApiService.fetchClassSchedule(
        xnm: widget.xnm,
        xqm: widget.xqm,
        bhId: bhId,
      );
      final data = resp['data'] as Map<String, dynamic>? ?? {};
      final raw = (data['courses'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final courses = <Course>[];
      for (final m in raw) {
        final name = (m['name'] ?? '').toString().trim();
        final wd = (m['weekday'] as num?)?.toInt();
        if (name.isEmpty || wd == null) continue;
        final start = (m['start_slot'] as num?)?.toInt() ?? 1;
        courses.add(Course(
          id: 'cls_${bhId}_$wd-$start',
          name: name,
          teacher: (m['teacher'] ?? '').toString().trim(),
          classroom: (m['classroom'] ?? '').toString().trim(),
          weekday: wd,
          startSlot: start,
          endSlot: (m['end_slot'] as num?)?.toInt() ?? start,
          weeks: (m['weeks'] ?? '').toString().trim(),
          colorValue: colorForName(name),
          source: CourseSource.server,
        ));
      }
      if (!mounted) return;
      if (courses.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('该班级本学期没有已发布的课表数据')));
        return;
      }
      final className = (c['bj'] ?? '').toString();
      final ok = await _confirmPreview(className, courses);
      if (ok == true && mounted) {
        Navigator.of(context).pop({'className': className, 'courses': courses});
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('课表获取失败，请稍后重试')));
      }
    } finally {
      if (mounted) setState(() => _loadingBhId = null);
    }
  }

  /// 预览确认：按星期分组展示，确认后才把结果带回。
  Future<bool?> _confirmPreview(String className, List<Course> courses) {
    final byDay = <int, List<Course>>{};
    for (final c in courses) {
      (byDay[c.weekday] ??= []).add(c);
    }
    final days = byDay.keys.toList()..sort();
    const dayNames = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('「$className」 ${courses.length} 门课',
            style: const TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final d in days) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Text(dayNames[d],
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.primaryColor)),
                  ),
                  for (final c in byDay[d]!)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(top: 6),
                            decoration: BoxDecoration(
                                color: Color(c.colorValue),
                                shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${c.name}\n'
                              '第${c.startSlot}-${c.endSlot}节 · ${c.classroom.isEmpty ? "未排" : c.classroom}'
                              '${c.weeks.isEmpty ? "" : " · ${c.weeks}"}',
                              style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.4,
                                  color: _dark
                                      ? Colors.grey.shade300
                                      : const Color(0xFF374151)),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('导入这份课表',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final surface = _dark ? const Color(0xFF1E1E1E) : Colors.white;
    final subColor =
        _dark ? Colors.grey.shade400 : const Color(0xFF6B7280);
    final line = _dark ? Colors.grey.shade700 : const Color(0xFFE5E7EB);
    return Scaffold(
      backgroundColor: _dark ? const Color(0xFF171717) : const Color(0xFFF7F8FA),
      appBar: AppBar(title: const Text('选择班级', style: TextStyle(fontSize: 17))),
      body: Column(
        children: [
          // 搜索框 + 过滤
          Container(
            color: surface,
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Column(children: [
              TextField(
                controller: _searchCtl,
                onChanged: (_) => _applyFilter(),
                style: TextStyle(fontSize: 14.5, color: _dark ? Colors.white : context.textPrimary),
                decoration: InputDecoration(
                  hintText: '搜班名 / 专业 / 学院，例如：25安工',
                  hintStyle: TextStyle(fontSize: 13.5, color: subColor),
                  isDense: true,
                  prefixIcon: Icon(Icons.search_rounded, size: 20, color: subColor),
                  suffixIcon: _searchCtl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: Icon(Icons.close_rounded, size: 18, color: subColor),
                          onPressed: () {
                            _searchCtl.clear();
                            _applyFilter();
                          }),
                  filled: true,
                  fillColor: _dark ? const Color(0xFF2A2A2A) : const Color(0xFFF3F4F6),
                  contentPadding: EdgeInsets.zero,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                _filterChip(
                    label: _grade ?? '年级',
                    active: _grade != null,
                    options: _grades,
                    onSel: (v) {
                      setState(() => _grade = v);
                      _applyFilter();
                    }),
                const SizedBox(width: 8),
                Expanded(
                  child: _filterChip(
                    label: _college ?? '学院',
                    active: _college != null,
                    options: _colleges,
                    onSel: (v) {
                      setState(() => _college = v);
                      _applyFilter();
                    },
                  ),
                ),
              ]),
            ]),
          ),
          Divider(height: 1, thickness: 0.5, color: line),
          // 列表
          Expanded(child: _buildList(surface, subColor, line)),
        ],
      ),
    );
  }

  Widget _filterChip({
    required String label,
    required bool active,
    required List<String> options,
    required ValueChanged<String?> onSel,
  }) {
    final subColor = _dark ? Colors.grey.shade400 : const Color(0xFF6B7280);
    return PopupMenuButton<String?>(
      onSelected: onSel,
      itemBuilder: (_) => [
        PopupMenuItem<String?>(
            value: null,
            child: Text('全部',
                style: TextStyle(
                    fontSize: 13.5,
                    color: active ? AppTheme.primaryColor : null))),
        for (final o in options)
          PopupMenuItem<String?>(
              value: o,
              child: Text(label == '年级' ? '$o 级' : o,
                  style: const TextStyle(fontSize: 13.5))),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active
              ? AppTheme.primaryColor.withOpacity(0.08)
              : (_dark ? const Color(0xFF2A2A2A) : Colors.white),
          border: Border.all(
              color:
                  active ? AppTheme.primaryColor : subColor.withOpacity(0.35)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: active
                          ? AppTheme.primaryColor
                          : subColor))),
          Icon(Icons.keyboard_arrow_down_rounded,
              size: 16, color: active ? AppTheme.primaryColor : subColor),
        ]),
      ),
    );
  }

  Widget _buildList(Color surface, Color subColor, Color line) {
    if (_loading) {
      return Center(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
          const CircularProgressIndicator(strokeWidth: 2.5),
          const SizedBox(height: 14),
          Text('正在加载班级列表…',
              style: TextStyle(fontSize: 13, color: subColor)),
        ]));
    }
    if (_error != null) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.cloud_off_rounded, size: 42, color: subColor),
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(fontSize: 13.5, color: subColor)),
        const SizedBox(height: 14),
        OutlinedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 17),
            label: const Text('重试')),
      ]));
    }
    if (_shown.isEmpty) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.search_off_rounded, size: 42, color: subColor),
        const SizedBox(height: 12),
        Text('没有匹配的班级',
            style: TextStyle(fontSize: 13.5, color: subColor)),
        const SizedBox(height: 6),
        Text('换个关键字，或清掉年级/学院过滤试试',
            style: TextStyle(fontSize: 12, color: subColor.withOpacity(0.8))),
      ]));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        controller: _scrollCtl,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        itemCount: _shown.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (ctx, i) {
          if (i == _shown.length) {
            return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Center(
                    child: Text('共 ${_shown.length} 个班（数据来自教务，仅供参考）',
                        style: TextStyle(fontSize: 11.5, color: subColor))));
          }
          final c = _shown[i];
          final bhId = (c['bh_id'] ?? '').toString();
          final busy = _loadingBhId == bhId;
          return InkWell(
            onTap: busy ? null : () => _pick(c),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: surface,
                border: Border.all(color: line),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(children: [
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((c['bj'] ?? '').toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                color: _dark
                                    ? Colors.white
                                    : context.textPrimary)),
                        const SizedBox(height: 2),
                        Text(
                          '${(c["zymc"] ?? "").toString()} · ${(c["jgmc"] ?? "").toString()}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: subColor),
                        ),
                      ]),
                ),
                const SizedBox(width: 10),
                if (busy)
                  const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else ...[
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text('${c["xkrs"] ?? "?"} 人',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.primaryColor)),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 20, color: subColor),
                ],
              ]),
            ),
          );
        },
      ),
    );
  }
}
