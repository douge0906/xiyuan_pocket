import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/course_provider.dart';
import '../../services/api_service.dart';
import '../../services/campus/empty_classroom_fetcher.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';
import '../../widgets/loading_overlay.dart';
import '../../widgets/empty_state_art.dart';
import '../../widgets/state_views.dart';

/// 空教室查询：四项必填（周次 / 星期 / 节次 / 楼号），数据来自正方教务。
///
/// 学期、校区由服务层从真实教务页面上下文自动携带，页面不新增额外必填项。
class EmptyClassroomPage extends ConsumerStatefulWidget {
  const EmptyClassroomPage({super.key});

  @override
  ConsumerState<EmptyClassroomPage> createState() => _EmptyClassroomPageState();
}

class _EmptyClassroomPageState extends ConsumerState<EmptyClassroomPage> {
  static const List<String> _weekdayLabels = [
    '周一',
    '周二',
    '周三',
    '周四',
    '周五',
    '周六',
    '周日',
  ];

  bool _optionsLoading = false;
  EmptyClassroomOptions? _options;
  String? _optionsError;

  final Set<int> _weeks = {};
  final Set<int> _weekdays = {};
  final Set<int> _slots = {};
  String? _buildingValue = '';

  bool _querying = false;
  int _seconds = 0;
  Timer? _timer;
  int _requestSeq = 0;

  List<Map<String, dynamic>> _rooms = [];
  int _total = 0;
  DateTime? _updatedAt;
  String? _queryError;
  bool _hasQueried = false;

  static const List<({int index, String period, String time})>
      _fallbackSections = [
    (index: 1, period: '上午', time: '08:00-08:45'),
    (index: 2, period: '上午', time: '08:55-09:40'),
    (index: 3, period: '上午', time: '10:10-10:55'),
    (index: 4, period: '上午', time: '11:05-11:50'),
    (index: 5, period: '下午', time: '13:45-14:30'),
    (index: 6, period: '下午', time: '14:40-15:25'),
    (index: 7, period: '下午', time: '15:55-16:40'),
    (index: 8, period: '下午', time: '16:50-17:35'),
    (index: 9, period: '晚上', time: '18:45-19:30'),
    (index: 10, period: '晚上', time: '19:40-20:25'),
    (index: 11, period: '晚上', time: '20:35-21:20'),
  ];

  @override
  void initState() {
    super.initState();
    final currentWeek = ref.read(courseProvider).currentWeek;
    _weeks.add(currentWeek >= 1 && currentWeek <= 19 ? currentWeek : 1);
    _weekdays.add(DateTime.now().weekday);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 选项只在用户真正点击查询后加载；进入页面不主动登录或拉取教务。
  Future<void> _ensureOptions({bool forceRefresh = false}) async {
    if (_optionsLoading) return;
    if (!forceRefresh && _options != null) return;
    setState(() {
      _optionsLoading = true;
      _optionsError = null;
    });
    try {
      final resp = await ApiService.fetchEmptyClassroomOptions(
        forceRefresh: forceRefresh,
      );
      final data = Map<String, dynamic>.from(resp['data'] as Map? ?? const {});
      final options = EmptyClassroomOptions.fromJson(data);
      if (!mounted) return;

      final currentWeek = ref.read(courseProvider).currentWeek;
      final week =
          currentWeek >= 1 && currentWeek <= options.weekMax ? currentWeek : 1;
      final maxSlot =
          options.sections.isEmpty ? 0 : options.sections.last.index;
      setState(() {
        _options = options;
        // 真实上限回来后，把选项加载前多选的周次/节次裁掉；否则会提交
        // 教务不存在的周次或节次，表现为“筛选条件明明选了却查不到”。
        _weeks.removeWhere((w) => w < 1 || w > options.weekMax);
        if (_weeks.isEmpty) _weeks.add(week);
        if (maxSlot > 0) {
          _slots.removeWhere((s) => s < 1 || s > maxSlot);
        }
        if (_weekdays.isEmpty) _weekdays.add(DateTime.now().weekday);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _optionsError = _friendlyError(e));
      }
    } finally {
      if (mounted) setState(() => _optionsLoading = false);
    }
  }

  Future<void> _retryOptions() async {
    await _ensureOptions(forceRefresh: true);
    if (mounted && _options != null) {
      _toast('楼号与节次已更新');
    }
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

  /// 让正在返回的旧查询失效；筛选项一变就必须调用，否则旧条件的结果
  /// 仍可能覆盖界面上的新条件。
  void _cancelPendingQuery() {
    _requestSeq++;
    _stopTimer();
    _querying = false;
  }

  void _resetResultFields() {
    _rooms = [];
    _total = 0;
    _updatedAt = null;
    _queryError = null;
    _hasQueried = false;
  }

  String? _validateMissing() {
    if (_weeks.isEmpty) return '请选择周次';
    if (_weekdays.isEmpty) return '请选择星期';
    if (_slots.isEmpty) return '请选择节次';
    if (_buildingValue == null) return '请选择楼号';
    return null;
  }

  Future<void> _query() async {
    final missing = _validateMissing();
    if (missing != null) {
      _toast(missing);
      return;
    }
    if (_querying) return;

    // 条件在发起查询时快照，避免 await 期间用户改筛选后提交错位参数。
    final qWeeks = _sorted(_weeks);
    final qWeekdays = _sorted(_weekdays);
    final qSlots = _sorted(_slots);
    final qBuilding = _buildingValue!;
    final seq = ++_requestSeq;
    setState(() {
      _querying = true;
      _queryError = null;
      _rooms = [];
      _total = 0;
      _updatedAt = null;
      _hasQueried = true;
    });
    _startTimer();

    try {
      await _ensureOptions();
      if (seq != _requestSeq || !mounted) return;
      final resp = await ApiService.fetchEmptyClassrooms(
        weeks: qWeeks,
        weekdays: qWeekdays,
        slots: qSlots,
        buildingValue: qBuilding,
        options: _options,
      );
      if (seq != _requestSeq || !mounted) return;
      final data = Map<String, dynamic>.from(resp['data'] as Map? ?? const {});
      final rawRooms = (data['rooms'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      setState(() {
        _rooms = rawRooms;
        _total = data['total'] is int ? data['total'] as int : rawRooms.length;
        _updatedAt = DateTime.now();
      });
    } catch (e) {
      if (seq != _requestSeq || !mounted) return;
      setState(() => _queryError = _friendlyError(e));
    } finally {
      if (seq == _requestSeq) {
        _stopTimer();
        if (mounted) setState(() => _querying = false);
      }
    }
  }

  Future<void> _retryQuery() => _query();

  Future<void> _refresh() => _query();

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _friendlyError(Object e) =>
      e.toString().replaceFirst('Exception: ', '').trim().isEmpty
          ? '查询失败，请稍后重试'
          : e.toString().replaceFirst('Exception: ', '').trim();

  List<int> _sorted(Set<int> values) => values.toList()..sort();

  String _weekSummary() {
    if (_weeks.isEmpty) return '请选择周次';
    final list = _sorted(_weeks);
    final consecutive =
        list.length > 1 && list.last - list.first == list.length - 1;
    return consecutive ? '第${list.first}-${list.last}周' : '第${list.join('、')}周';
  }

  String _weekdaySummary() {
    if (_weekdays.isEmpty) return '请选择星期';
    return _sorted(_weekdays).map((d) => _weekdayLabels[d - 1]).join('、');
  }

  String _slotSummary() {
    if (_slots.isEmpty) return '请选择节次';
    final list = _sorted(_slots);
    final consecutive =
        list.length > 1 && list.last - list.first == list.length - 1;
    return consecutive ? '第${list.first}-${list.last}节' : '第${list.join('、')}节';
  }

  String _buildingLabel(String? value) {
    if (_options == null) {
      return _optionsLoading ? '正在读取楼号…' : '全部（首次查询后可筛选）';
    }
    if (value == null) return '请选择楼号';
    if (value.isEmpty) return '全部';
    for (final b in _options?.buildings ?? const <EmptyClassroomBuilding>[]) {
      if (b.value == value) return b.label;
    }
    return value;
  }

  Future<void> _pickWeeks() async {
    final weekMax = _options?.weekMax ?? 19;
    final picked = await _openMultiPicker(
      title: '选择周次',
      initial: _weeks,
      items: [
        for (var i = 1; i <= weekMax; i++) (value: i, label: '第$i周', sub: null),
      ],
      quickLabel: '仅本周',
      onQuick: () => {ref.read(courseProvider).currentWeek},
    );
    if (picked == null || !mounted) return;
    _cancelPendingQuery();
    setState(() {
      _weeks
        ..clear()
        ..addAll(picked);
      _resetResultFields();
    });
  }

  Future<void> _pickWeekdays() async {
    final picked = await _openMultiPicker(
      title: '选择星期',
      initial: _weekdays,
      items: [
        for (var i = 1; i <= 7; i++)
          (value: i, label: _weekdayLabels[i - 1], sub: null),
      ],
      quickLabel: '今天',
      onQuick: () => {DateTime.now().weekday},
    );
    if (picked == null || !mounted) return;
    _cancelPendingQuery();
    setState(() {
      _weekdays
        ..clear()
        ..addAll(picked);
      _resetResultFields();
    });
  }

  List<EmptyClassroomSection> get _sections =>
      _options?.sections ??
      [
        for (final s in _fallbackSections)
          EmptyClassroomSection(index: s.index, period: s.period, time: s.time),
      ];

  Future<void> _pickSlots() async {
    final picked = await _openSectionPicker(
      initial: _slots,
      sections: _sections,
    );
    if (picked == null || !mounted) return;
    _cancelPendingQuery();
    setState(() {
      _slots
        ..clear()
        ..addAll(picked);
      _resetResultFields();
    });
  }

  Future<void> _pickBuilding() async {
    final options = _options;
    if (options == null) {
      _toast(_optionsLoading ? '正在读取楼号清单，请稍候' : '楼号清单尚未加载，当前按全部楼号查询');
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => _BuildingPickerDialog(
        buildings: options.buildings,
        initialValue: _buildingValue ?? '',
      ),
    );
    if (picked == null || !mounted) return;
    _cancelPendingQuery();
    setState(() {
      _buildingValue = picked;
      _resetResultFields();
    });
  }

  Future<Set<int>?> _openMultiPicker({
    required String title,
    required Set<int> initial,
    required List<({int value, String label, String? sub})> items,
    String? quickLabel,
    Set<int> Function()? onQuick,
  }) {
    return showDialog<Set<int>>(
      context: context,
      builder: (ctx) => _MultiPickerDialog(
        title: title,
        initial: initial,
        items: items,
        quickLabel: quickLabel,
        onQuick: onQuick,
      ),
    );
  }

  Future<Set<int>?> _openSectionPicker({
    required Set<int> initial,
    required List<EmptyClassroomSection> sections,
  }) {
    return showDialog<Set<int>>(
      context: context,
      builder: (ctx) => _SectionPickerDialog(
        initial: initial,
        sections: sections,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(title: const Text('空教室查询')),
      body: Stack(
        children: [
          _buildBody(),
          if (_querying)
            LoadingOverlay(seconds: _seconds, message: '正在查询空闲教室…'),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final options = _options;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: [
          AppCard(
            radius: AppTheme.radiusLg,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (options != null) ...[
                  Text(
                    '${options.semesterLabel} · ${options.campusLabel}',
                    style: TextStyle(
                      fontSize: AppTheme.fontSmall,
                      color: context.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_optionsLoading) ...[
                  Row(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.primaryColor,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '正在读取楼号与节次…',
                          style: TextStyle(
                            fontSize: AppTheme.fontSmall,
                            color: context.textTertiary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                if (_optionsError != null) ...[
                  Container(
                    padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                    decoration: BoxDecoration(
                      color: AppTheme.danger.withValues(alpha: 0.08),
                      borderRadius: AppTheme.radiusSmAll,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '楼号/节次读取失败：$_optionsError；仍可按全部楼号查询',
                            style: TextStyle(
                              fontSize: AppTheme.fontSmall,
                              color: AppTheme.danger,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _optionsLoading ? null : _retryOptions,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                _filterRow(
                  title: '周次',
                  summary: _weekSummary(),
                  onTap: _pickWeeks,
                ),
                _filterRow(
                  title: '星期',
                  summary: _weekdaySummary(),
                  onTap: _pickWeekdays,
                ),
                _filterRow(
                  title: '节次',
                  summary: _slotSummary(),
                  onTap: _pickSlots,
                ),
                _filterRow(
                  title: '楼号',
                  summary: _buildingLabel(_buildingValue),
                  onTap: _pickBuilding,
                  enabled: _options != null && !_optionsLoading,
                  loading: _optionsLoading,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: _querying ? null : _query,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      shape: RoundedRectangleBorder(
                        borderRadius: AppTheme.radiusMdAll,
                      ),
                    ),
                    child: const Text(
                      '查询空教室',
                      style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_queryError != null)
            ErrorState(message: _queryError!, onRetry: _retryQuery),
          if (_queryError == null && _rooms.isEmpty && !_querying)
            _buildPlaceholder(),
          if (_rooms.isNotEmpty) ...[
            _resultSummary(),
            const SizedBox(height: 12),
            ..._buildGroupedResults(),
          ],
          const SizedBox(height: 12),
          Text(
            '数据来自教务，临时调课或占用请以实际情况为准。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTheme.fontCaption,
              color: context.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final artColor = isDark ? const Color(0xFF7A7A7A) : const Color(0xFFB4BAC4);
    final title = _hasQueried ? '这个时段没有空闲教室' : '选择条件后查询空闲教室';

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            EmptyArt(
              variant: EmptyArtVariant.classroom,
              color: artColor,
              size: 96,
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTheme.fontTitle,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
                height: 1.5,
                color: artColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterRow({
    required String title,
    required String summary,
    required VoidCallback onTap,
    bool enabled = true,
    bool loading = false,
  }) {
    final empty = summary.startsWith('请选择') ||
        summary.startsWith('全部（') ||
        summary == '正在读取楼号…';
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: AppTheme.radiusMdAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 56,
              child: Text(
                title,
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  fontWeight: FontWeight.w500,
                  color: context.textPrimary,
                ),
              ),
            ),
            Expanded(
              child: Text(
                summary,
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  color: enabled
                      ? (empty ? context.textTertiary : context.textSecondary)
                      : context.textTertiary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (loading)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.primaryColor,
                ),
              )
            else
              Icon(Icons.chevron_right_rounded,
                  size: 20, color: context.textTertiary),
          ],
        ),
      ),
    );
  }

  Widget _resultSummary() {
    final updated = _updatedAt;
    final time = updated == null
        ? ''
        : '${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}';
    final limited = _rooms.length < _total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '共 $_total 间',
              style: TextStyle(
                fontSize: AppTheme.fontTitle,
                fontWeight: FontWeight.w600,
                color: context.textPrimary,
              ),
            ),
            const Spacer(),
            if (time.isNotEmpty)
              Text(
                '更新于 $time',
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  color: context.textTertiary,
                ),
              ),
          ],
        ),
        if (limited) ...[
          const SizedBox(height: 4),
          Text(
            '当前显示 ${_rooms.length} 间，还有 ${_total - _rooms.length} 间未展示；请缩小周次/节次/楼号条件后重试。',
            style: TextStyle(
              fontSize: AppTheme.fontSmall,
              color: context.textTertiary,
            ),
          ),
        ],
      ],
    );
  }

  List<Widget> _buildGroupedResults() {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final room in _rooms) {
      final building = '${room['building'] ?? room['buildingCode'] ?? '其他'}';
      grouped.putIfAbsent(building, () => []).add(room);
    }

    return [
      for (final entry in grouped.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: AppCard(
            radius: AppTheme.radiusLg,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${entry.key}（${entry.value.length}）',
                  style: TextStyle(
                    fontSize: AppTheme.fontTitle,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                ),
                const SizedBox(height: 10),
                for (var i = 0; i < entry.value.length; i++) ...[
                  _roomCard(entry.value[i]),
                  if (i != entry.value.length - 1)
                    Divider(height: 1, color: context.borderColor),
                ],
              ],
            ),
          ),
        ),
    ];
  }

  Widget _roomCard(Map<String, dynamic> room) {
    final name = '${room['name'] ?? ''}';
    final code = '${room['code'] ?? ''}';
    final floor = '${room['floor'] ?? ''}';
    final category = '${room['category'] ?? ''}';
    final seats = room['seats'];
    final examSeats = room['examSeats'];
    final meta = <String>[
      if (code.isNotEmpty) code,
      if (floor.isNotEmpty) '$floor层',
      if (category.isNotEmpty) category,
      if (seats is int) '$seats座',
      if (examSeats is int) '考试座 $examSeats',
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name.isEmpty ? code : name,
            style: TextStyle(
              fontSize: AppTheme.fontBody,
              fontWeight: FontWeight.w600,
              color: context.textPrimary,
            ),
          ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              meta.join(' · '),
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                color: context.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MultiPickerDialog extends StatefulWidget {
  const _MultiPickerDialog({
    required this.title,
    required this.initial,
    required this.items,
    this.quickLabel,
    this.onQuick,
  });

  final String title;
  final Set<int> initial;
  final List<({int value, String label, String? sub})> items;
  final String? quickLabel;
  final Set<int> Function()? onQuick;

  @override
  State<_MultiPickerDialog> createState() => _MultiPickerDialogState();
}

class _MultiPickerDialogState extends State<_MultiPickerDialog> {
  late final Set<int> _draft = Set<int>.of(widget.initial);

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      shape: RoundedRectangleBorder(
        borderRadius: AppTheme.radiusLgAll,
        side: BorderSide(color: context.borderColor),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle,
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded,
                        size: 20, color: context.textTertiary),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final item in widget.items)
                      ChoiceChip(
                        label: Text(item.label),
                        selected: _draft.contains(item.value),
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setState(() {
                          if (!_draft.add(item.value)) {
                            _draft.remove(item.value);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  if (widget.quickLabel != null && widget.onQuick != null)
                    TextButton(
                      onPressed: () => setState(() => _draft
                        ..clear()
                        ..addAll(widget.onQuick!())),
                      child: Text(widget.quickLabel!),
                    ),
                  TextButton(
                    onPressed: () => setState(_draft.clear),
                    child: const Text('清空'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(_draft),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      minimumSize: const Size(0, 42),
                      shape: RoundedRectangleBorder(
                        borderRadius: AppTheme.radiusMdAll,
                      ),
                    ),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionPickerDialog extends StatefulWidget {
  const _SectionPickerDialog({
    required this.initial,
    required this.sections,
  });

  final Set<int> initial;
  final List<EmptyClassroomSection> sections;

  @override
  State<_SectionPickerDialog> createState() => _SectionPickerDialogState();
}

class _SectionPickerDialogState extends State<_SectionPickerDialog> {
  late final Set<int> _draft = Set<int>.of(widget.initial);

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<EmptyClassroomSection>>{};
    for (final s in widget.sections) {
      groups.putIfAbsent(s.period.isEmpty ? '节次' : s.period, () => []).add(s);
    }

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      shape: RoundedRectangleBorder(
        borderRadius: AppTheme.radiusLgAll,
        side: BorderSide(color: context.borderColor),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '选择节次',
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle,
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded,
                        size: 20, color: context.textTertiary),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final entry in groups.entries)
                    TextButton(
                      onPressed: () => setState(
                          () => _draft.addAll(entry.value.map((e) => e.index))),
                      child: Text('全选${entry.key}'),
                    ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in groups.entries) ...[
                      Text(
                        entry.key,
                        style: TextStyle(
                          fontSize: AppTheme.fontSmall,
                          color: context.textTertiary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final s in entry.value)
                            ChoiceChip(
                              label: Text('${s.label} ${s.time}'),
                              selected: _draft.contains(s.index),
                              showCheckmark: false,
                              visualDensity: VisualDensity.compact,
                              onSelected: (_) => setState(() {
                                if (!_draft.add(s.index)) {
                                  _draft.remove(s.index);
                                }
                              }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => setState(_draft.clear),
                    child: const Text('清空'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(_draft),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      minimumSize: const Size(0, 42),
                      shape: RoundedRectangleBorder(
                        borderRadius: AppTheme.radiusMdAll,
                      ),
                    ),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BuildingPickerDialog extends StatefulWidget {
  const _BuildingPickerDialog({
    required this.buildings,
    required this.initialValue,
  });

  final List<EmptyClassroomBuilding> buildings;
  final String initialValue;

  @override
  State<_BuildingPickerDialog> createState() => _BuildingPickerDialogState();
}

class _BuildingPickerDialogState extends State<_BuildingPickerDialog> {
  late String _value = widget.initialValue;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyword = _search.text.trim().toLowerCase();
    final filtered = widget.buildings.where((b) {
      if (keyword.isEmpty) return true;
      return b.label.toLowerCase().contains(keyword) ||
          b.value.toLowerCase().contains(keyword);
    }).toList();

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      shape: RoundedRectangleBorder(
        borderRadius: AppTheme.radiusLgAll,
        side: BorderSide(color: context.borderColor),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '选择楼号',
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle,
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded,
                        size: 20, color: context.textTertiary),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: '按名称或编码搜索',
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: AppTheme.radiusMdAll,
                  ),
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: filtered.length,
                itemBuilder: (ctx, i) {
                  final b = filtered[i];
                  return RadioListTile<String>(
                    title: Text(b.label),
                    value: b.value,
                    groupValue: _value,
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _value = v);
                      Navigator.of(context).pop(v);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
