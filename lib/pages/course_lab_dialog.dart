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
    '', '一', '二', '三', '四', '五', '六', '日',
  ];

  /// 可变副本：教室批量替换会改写 place。
  late List<SyglLab> _labs;
  /// 选中的课程名（按课程分组勾选）。默认全选。
  late Set<String> _picked;

  @override
  void initState() {
    super.initState();
    _labs = List<SyglLab>.of(widget.labs);
    _picked = {for (final l in _labs) l.name};
  }

  /// 课程名 -> 该组所有条目的下标。
  Map<String, List<int>> get _groups {
    final map = <String, List<int>>{};
    for (var i = 0; i < _labs.length; i++) {
      map.putIfAbsent(_labs[i].name, () => <int>[]).add(i);
    }
    return map;
  }

  /// 当前所有不同的实验室值（去掉空值），按出现顺序。
  List<String> get _places {
    final seen = <String>{};
    final out = <String>[];
    for (final l in _labs) {
      if (l.place.isNotEmpty && seen.add(l.place)) out.add(l.place);
    }
    return out;
  }

  int _placeCount(String place) => _labs.where((l) => l.place == place).length;

  void _applyClassroom(String from, String to) {
    final value = to.trim();
    if (value.isEmpty) return;
    setState(() {
      _labs = [
        for (final l in _labs)
          if (l.place == from)
            SyglLab(
              name: l.name,
              code: l.code,
              place: value,
              teacher: l.teacher,
              time: l.time,
              weekday: l.weekday,
              startSlot: l.startSlot,
              endSlot: l.endSlot,
              weeks: l.weeks,
              source: l.source,
            )
          else
            l,
      ];
    });
  }

  Future<void> _editClassroom(String from) async {
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) =>
          _ClassroomEditDialog(from: from, count: _placeCount(from)),
    );
    if (value != null) _applyClassroom(from, value);
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
    final places = _places;
    final allCourses = groups.length;
    final pickedCourses = _picked.length;
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
                    fontSize: AppTheme.fontTitle,
                    fontWeight: FontWeight.w600)),
          ),
          Text('$pickedCourses / $allCourses 门',
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
              Text('已按课程合并。勾选要导入的实验；实验室就是课表里的教室，可统一改名。',
                  style: TextStyle(
                      fontSize: AppTheme.fontSmall,
                      color: context.textSecondary)),
              if (places.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text('统一更改教室',
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall,
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary)),
                const SizedBox(height: 6),
                Text('点一个实验室，把它在所有实验里一次性改成真实教室。',
                    style: TextStyle(
                        fontSize: AppTheme.fontCaption,
                        color: context.textTertiary)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (final p in places) _placeChip(context, p)],
                ),
                const SizedBox(height: 14),
                Divider(height: 1, color: context.borderColor),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('实验课程',
                      style: TextStyle(
                          fontSize: AppTheme.fontSmall,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary)),
                  const Spacer(),
                  TextButton(
                    onPressed: () =>
                        setState(() => _picked = {for (final l in _labs) l.name}),
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
              style: TextStyle(fontSize: AppTheme.fontBody, color: Colors.grey)),
        ),
        FilledButton(
          onPressed: pickedCourses == 0
              ? null
              : () {
                  final picked = <SyglLab>[];
                  for (var i = 0; i < _labs.length; i++) {
                    if (_picked.contains(_labs[i].name)) picked.add(_labs[i]);
                  }
                  Navigator.of(context).pop(picked);
                },
          child: const Text('导入'),
        ),
      ],
    );
  }

  Widget _placeChip(BuildContext context, String place) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        onTap: () => _editClassroom(place),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: context.subtleFill,
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            border: Border.all(color: context.borderColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.edit_rounded, size: 13, color: AppTheme.primaryColor),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(place,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall,
                        color: context.textPrimary)),
              ),
              const SizedBox(width: 4),
              Text('${_placeCount(place)} 条',
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: context.textTertiary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _courseCard(BuildContext context, MapEntry<String, List<int>> entry) {
    final on = _picked.contains(entry.key);
    final labs = [for (final i in entry.value) _labs[i]];
    final placeSet = <String>{
      for (final l in labs) if (l.place.isNotEmpty) l.place,
    };
    final teacherSet = <String>{
      for (final l in labs) if (l.teacher.isNotEmpty) l.teacher,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
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
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
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
                      Text(entry.key,
                          style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              fontWeight: FontWeight.w600,
                              color: context.textPrimary)),
                      const SizedBox(height: 4),
                      Text('${labs.length} 次实验 · ${_sessionLine(labs.first)}',
                          style: TextStyle(
                              fontSize: AppTheme.fontCaption,
                              color: context.textSecondary)),
                      if (placeSet.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text('教室：${placeSet.join('、')}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: AppTheme.fontCaption,
                                  color: context.textTertiary)),
                        ),
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
          const Expanded(
            child: Text('统一更改教室',
                style: TextStyle(
                    fontSize: AppTheme.fontTitle,
                    fontWeight: FontWeight.w600)),
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
          Text('把「${widget.from}」在 ${widget.count} 条实验里全部改成：',
              style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  color: context.textSecondary)),
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
              style: TextStyle(fontSize: AppTheme.fontBody, color: Colors.grey)),
        ),
        FilledButton(
          onPressed: () {
            final v = _ctrl.text.trim();
            if (v.isEmpty) return;
            Navigator.of(context).pop(v);
          },
          child: const Text('应用到全部'),
        ),
      ],
    );
  }
}