part of 'course_table_home_page.dart';

/// 实验课导入确认面板（用户 m26008 #2）：按「实验课程」合并展示，
/// 并提供「实验室 -> 真实教室」的一次性批量替换。
///
/// 实验室字段就是课表里的教室。用户举例：天气预报综合实验室其实是勤学楼，
/// 点一下就能把这一批全部改成勤学楼，不用逐条编辑。
class _LabImportDialog extends StatefulWidget {
  const _LabImportDialog({required this.labs});

  final List<SyglLab> labs;

  @override
  State<_LabImportDialog> createState() => _LabImportDialogState();
}

class _LabImportDialogState extends State<_LabImportDialog> {
  static const List<String> _weekdays = [
    '',
    '一',
    '二',
    '三',
    '四',
    '五',
    '六',
    '日',
  ];

  /// 可变副本：教室批量替换会改写 place。
  late List<SyglLab> _labs;

  /// 选中的分组 key（课程 + 班级 + 学年/学期），不是裸课程名。
  late Set<String> _picked;

  @override
  void initState() {
    super.initState();
    _labs = List<SyglLab>.of(widget.labs);
    // 默认全部不选，由用户明确勾选要导入的实验课。
    _picked = <String>{};
  }

  /// 分组键：**课程 + 班级 + 学年/学期**。
  ///
  /// 同一门实验的不同时间段合到一张卡里全部展示，避免「看到一条、实际
  /// 导入多条」；教室、教师、时间不参与分组，卡片内逐条列出，每条都能
  /// 单独改教室（不再按 place 全局替换）。
  String _groupKey(SyglLab l) => [
        l.name,
        l.className,
        l.academicYear,
        l.academicTerm,
      ].join('\u0001');

  /// 分组 key -> 该组所有条目的下标。
  Map<String, List<int>> get _groups {
    final map = <String, List<int>>{};
    for (var i = 0; i < _labs.length; i++) {
      map.putIfAbsent(_groupKey(_labs[i]), () => <int>[]).add(i);
    }
    return map;
  }

  String _groupTitle(List<int> indexes) => _labs[indexes.first].name;

  String _groupSubtitle(List<int> indexes) {
    final first = _labs[indexes.first];
    final parts = <String>[
      if (first.className.isNotEmpty) '班级 ${first.className}' else '班级未知',
      if (first.academicYear.isNotEmpty)
        '${first.academicYear}学年'
            '${first.academicTerm.isEmpty ? '' : ' ${first.academicTerm}'}'
      else
        '学年未知',
    ];
    return parts.join(' · ');
  }

  /// 只改当前卡片对应的那一条实验，不再按 `place` 全局替换。
  /// 同一实验室名可能出现在多门实验里，全局替换会把用户没打开的实验一起改掉。
  void _applyClassroomAt(int index, String to) {
    final value = to.trim();
    if (value.isEmpty || index < 0 || index >= _labs.length) return;
    setState(() {
      _labs[index] = _labs[index].copyWith(place: value);
    });
  }

  Future<void> _editClassroom(int index, String from) async {
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => _ClassroomEditDialog(from: from, count: 1),
    );
    if (value != null) _applyClassroomAt(index, value);
  }

  String _sessionLine(SyglLab l) {
    final when = l.weekday >= 1 && l.weekday <= 7
        ? '周${_weekdays[l.weekday]} 第${l.startSlot}-${l.safeEndSlot}节'
        : '第${l.startSlot}-${l.safeEndSlot}节';
    final wk = l.weeks.isNotEmpty ? l.weeks : '全部周';
    return '$when · $wk';
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final allCourses = groups.length;
    final pickedCourses = _picked.length;
    final pickedEntries =
        _labs.where((l) => _picked.contains(_groupKey(l))).length;
    final width = (MediaQuery.of(context).size.width - 96).clamp(280.0, 420.0);
    return AlertDialog(
      backgroundColor: context.cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(color: AppTheme.cardStrokeColor(context.isDark)),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      title: Row(
        children: [
          Icon(Icons.science_rounded, size: 20, color: AppTheme.primaryColor),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('导入实验课',
                style: TextStyle(
                    fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
          ),
          Text('$pickedCourses / $allCourses 门 · $pickedEntries 条',
              style: TextStyle(
                  fontSize: AppTheme.fontSmall, color: context.textTertiary)),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
      content: SizedBox(
        width: width,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('实验课程',
                      style: TextStyle(
                          fontSize: AppTheme.fontSmall,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(
                        () => _picked = {for (final l in _labs) _groupKey(l)}),
                    child: const Text('全选'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _picked = <String>{}),
                    child: const Text('清空'),
                  ),
                ],
              ),
              for (final entry in groups.entries) _courseCard(context, entry),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消',
              style:
                  TextStyle(fontSize: AppTheme.fontBody, color: Colors.grey)),
        ),
        FilledButton(
          onPressed: pickedCourses == 0
              ? null
              : () {
                  final picked = <SyglLab>[];
                  for (var i = 0; i < _labs.length; i++) {
                    if (_picked.contains(_groupKey(_labs[i]))) {
                      picked.add(_labs[i]);
                    }
                  }
                  Navigator.of(context).pop(picked);
                },
          child: const Text('导入'),
        ),
      ],
    );
  }

  Widget _courseCard(BuildContext context, MapEntry<String, List<int>> entry) {
    final on = _picked.contains(entry.key);
    final labs = [for (final i in entry.value) _labs[i]];
    final teacherSet = <String>{
      for (final l in labs)
        if (l.teacher.isNotEmpty) l.teacher,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          onTap: () => setState(() {
            if (on) {
              _picked.remove(entry.key);
            } else {
              _picked.add(entry.key);
            }
          }),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: on
                  ? AppTheme.primaryColor.withValues(alpha: 0.08)
                  : context.subtleFill,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              border: Border.all(
                color: on ? AppTheme.primaryColor : context.borderColor,
                width: on ? 1.4 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  on
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: on ? AppTheme.primaryColor : context.textTertiary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_groupTitle(entry.value),
                          style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              fontWeight: FontWeight.w600,
                              color: context.textPrimary)),
                      const SizedBox(height: 2),
                      Text(_groupSubtitle(entry.value),
                          style: TextStyle(
                              fontSize: AppTheme.fontCaption,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.primaryColor)),
                      const SizedBox(height: 4),
                      for (var j = 0; j < entry.value.length; j++)
                        _sessionRow(entry.value[j], labs[j]),
                      if (teacherSet.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text('教师：${teacherSet.join('、')}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: AppTheme.fontCaption,
                                  color: context.textTertiary)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 卡片内的一条实验时间段；教室按钮只改这一条。
  Widget _sessionRow(int index, SyglLab lab) {
    final room = lab.place.trim().isEmpty ? '教室未识别' : lab.place.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text('${_sessionLine(lab)} · $room',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: context.textSecondary)),
        ),
        IconButton(
          tooltip: '只改这次实验的教室',
          onPressed: () => _editClassroom(index, lab.place),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          icon:
              Icon(Icons.edit_outlined, size: 15, color: AppTheme.primaryColor),
        ),
      ],
    );
  }
}

/// 教室批量改名输入框。
class _ClassroomEditDialog extends StatefulWidget {
  const _ClassroomEditDialog({required this.from, required this.count});

  final String from;
  final int count;

  @override
  State<_ClassroomEditDialog> createState() => _ClassroomEditDialogState();
}

class _ClassroomEditDialogState extends State<_ClassroomEditDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.from);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(color: AppTheme.cardStrokeColor(context.isDark)),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      title: Row(
        children: [
          Expanded(
            child: Text(widget.count > 1 ? '统一更改教室' : '更改这次实验的教室',
                style: TextStyle(
                    fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              widget.count > 1
                  ? '把「${widget.from}」在 ${widget.count} 条实验里全部改成：'
                  : '把这次实验的教室「${widget.from.isEmpty ? '未识别' : widget.from}」改成：',
              style: TextStyle(
                  fontSize: AppTheme.fontSmall, color: context.textSecondary)),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLength: 24,
            decoration: InputDecoration(
              labelText: '真实教室',
              hintText: '例如：勤学楼 301',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              isDense: true,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消',
              style:
                  TextStyle(fontSize: AppTheme.fontBody, color: Colors.grey)),
        ),
        FilledButton(
          onPressed: () {
            final v = _ctrl.text.trim();
            if (v.isEmpty) return;
            Navigator.of(context).pop(v);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
