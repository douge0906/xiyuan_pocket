import 'package:flutter/material.dart';

import '../services/countdown_store.dart';
import '../services/widget_sync_service.dart';
import '../theme/app_theme.dart';
import '../widgets/course_date_picker.dart';
import '../widgets/widget_appearance_editor.dart';

/// 倒数日（用户 m26008 需求 1）：**一个页面，两张卡片**。
///
/// 倒数日 1 / 倒数日 2 各自绑定固定 id 的一条数据，点卡片直接改标题与日期，
/// 确认后写盘并立即刷新桌面组件 —— 不再需要「先新增 → 再选条目 →
/// 再添加到桌面」那一串绕路。外观设置也收在同一页底部，真正一页搞定。
class CountdownPage extends StatefulWidget {
  const CountdownPage({super.key, this.initialSlot = -1, this.slot = -1});

  /// 兼容旧调用点（tool_navigator 传的是 initialSlot）。
  final int initialSlot;
  final int slot;

  @override
  State<CountdownPage> createState() => _CountdownPageState();
}

class _CountdownPageState extends State<CountdownPage> {
  final CountdownStore _store = CountdownStore.instance;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onChanged);
    _bootstrap();
  }

  @override
  void dispose() {
    _store.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _bootstrap() async {
    await _store.ensureLoaded();
    if (!mounted) return;
    setState(() => _loading = false);
    // 桌面组件点击带 slot：直接把对应那张卡片的编辑框打开。
    final s = widget.slot >= 0 ? widget.slot : widget.initialSlot;
    if (s == 0 || s == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _editSlot(s);
      });
    }
  }

  CountdownItem? _itemOf(int slot) {
    final id = CountdownStore.slotId(slot);
    for (final e in _store.items) {
      if (e.id == id) return e;
    }
    return null;
  }

  Future<void> _editSlot(int slot) async {
    final current = _itemOf(slot);
    final result = await showDialog<_SimpleEditResult>(
      context: context,
      builder: (ctx) => _SimpleCountdownDialog(initial: current, slot: slot),
    );
    if (result == null) return;
    final item = CountdownItem(
      id: CountdownStore.slotId(slot),
      title: result.title,
      date: result.date,
    );
    if (_itemOf(slot) != null) {
      await _store.update(item);
    } else {
      await _store.add(item);
    }
    // 确认后自动刷新：写盘 + 下发 + 让两个组件立即重渲染。
    await WidgetSyncService.syncCountdownWidget();
    await WidgetSyncService.renderNow();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('倒数日',
            style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                await _store.load();
                await WidgetSyncService.syncCountdownWidget();
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                children: [
                  Text('点卡片直接改标题和日期，保存后桌面组件立即更新。',
                      style: TextStyle(
                          fontSize: AppTheme.fontSmall,
                          color: context.textTertiary)),
                  const SizedBox(height: 14),
                  _slotCard(context, 0),
                  const SizedBox(height: 12),
                  _slotCard(context, 1),
                  const SizedBox(height: 20),
                  WidgetAppearanceEditor(
                    kind: 'countdown',
                    title: '组件外观',
                    onSync: WidgetSyncService.syncCountdownWidget,
                  ),
                ],
              ),
            ),
    );
  }

  Widget _slotCard(BuildContext context, int slot) {
    final item = _itemOf(slot);
    final now = DateTime.now();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        onTap: () => _editSlot(slot),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
          decoration: BoxDecoration(
            color: context.cardColor,
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            border: Border.all(color: AppTheme.cardStrokeColor(context.isDark)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: Icon(Icons.hourglass_bottom_rounded,
                    color: AppTheme.primaryColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('倒数日 ${slot + 1}',
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption,
                            color: context.textTertiary)),
                    const SizedBox(height: 3),
                    Text(item?.title ?? '未设置 · 点这里添加',
                        style: TextStyle(
                            fontSize: AppTheme.fontTitle,
                            fontWeight: FontWeight.w600,
                            color: item == null
                                ? context.textTertiary
                                : context.textPrimary)),
                    const SizedBox(height: 4),
                    Text(
                      item == null
                          ? '设置标题和日期'
                          : '${_dateText(item.date)} · ${item.label(now)}',
                      style: TextStyle(
                          fontSize: AppTheme.fontSmall,
                          color: context.textSecondary),
                    ),
                  ],
                ),
              ),
              if (item != null)
                Text(
                  item.isPast(now) ? '已过' : '${item.daysFrom(now)}',
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.primaryColor),
                ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded,
                  color: context.textTertiary, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  static String _dateText(DateTime d) =>
      '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
}

class _SimpleEditResult {
  const _SimpleEditResult(this.title, this.date);
  final String title;
  final DateTime date;
}

/// 极简编辑：只有标题和日期两项（用户 m26008：这才叫简化）。
class _SimpleCountdownDialog extends StatefulWidget {
  const _SimpleCountdownDialog({required this.initial, required this.slot});
  final CountdownItem? initial;
  final int slot;

  @override
  State<_SimpleCountdownDialog> createState() => _SimpleCountdownDialogState();
}

class _SimpleCountdownDialogState extends State<_SimpleCountdownDialog> {
  late final TextEditingController _title;
  late DateTime _date;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.initial?.title ?? '');
    _date = widget.initial?.date ?? DateTime.now();
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showCourseDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000, 1, 1),
      lastDate: DateTime(2100, 12, 31),
      helpText: '选择这一天',
    );
    if (picked != null) setState(() => _date = picked);
  }

  void _submit() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '请写一个标题');
      return;
    }
    Navigator.of(context).pop(_SimpleEditResult(title, _date));
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
      title: Row(
        children: [
          Expanded(
            child: Text('倒数日 ${widget.slot + 1}',
                style: const TextStyle(fontSize: AppTheme.fontTitle)),
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
          TextField(
            controller: _title,
            autofocus: true,
            maxLength: 20,
            decoration: InputDecoration(
              labelText: '标题',
              hintText: '例如：期末考试',
              errorText: _error,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              isDense: true,
            ),
            onChanged: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: 14),
          Text('日期',
              style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  color: context.textSecondary)),
          const SizedBox(height: 6),
          InkWell(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            onTap: _pickDate,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: context.subtleFill,
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                border: Border.all(color: context.borderColor),
              ),
              child: Row(
                children: [
                  Icon(Icons.event_rounded,
                      size: 18, color: AppTheme.primaryColor),
                  const SizedBox(width: 10),
                  Text(
                    '${_date.year} 年 ${_date.month} 月 ${_date.day} 日',
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        color: context.textPrimary),
                  ),
                  const Spacer(),
                  Icon(Icons.expand_more_rounded,
                      size: 18, color: context.textTertiary),
                ],
              ),
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
          onPressed: _submit,
          child: const Text('保存并刷新'),
        ),
      ],
    );
  }
}
