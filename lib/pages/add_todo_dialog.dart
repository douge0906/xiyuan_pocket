import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/todo.dart';
import '../theme/app_theme.dart';
import 'date_pick_dialog.dart';

/// 新增待办弹窗（2026-10-17 第二版）。
///
/// **强制居中盒子**：用户点名的 UI 铁律 —— 表单/弹窗一律用 Dialog，
/// 禁止上滑式底部弹窗；右上角必须能点 × 关闭。
///
/// 第二版改动（用户要求）：
///   · **去掉「类型」选择**；
///   · 时间改成**上下滚轮**（时 / 分），不再用系统时钟盘；
///   · 内容加提示「可省略，填了可以直接点任务查看」。
class AddTodoDialog extends StatefulWidget {
  const AddTodoDialog({super.key, this.initialDate});

  /// 从某一天进入时预填（可选）。
  final DateTime? initialDate;

  static Future<Todo?> show(BuildContext context, {DateTime? initialDate}) {
    return showDialog<Todo>(
      context: context,
      barrierDismissible: true,
      builder: (_) => AddTodoDialog(initialDate: initialDate),
    );
  }

  @override
  State<AddTodoDialog> createState() => _AddTodoDialogState();
}

class _AddTodoDialogState extends State<AddTodoDialog> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _descCtrl = TextEditingController();

  late DateTime _day;
  late int _hour;
  late int _minute;

  /// true 时盒子内容换成日期选择面板（同一个 Dialog 内切换，不叠第二层）。
  bool _pickingDate = false;

  /// 重复规则（2026-10-18）：null=不重复 / 'daily'=每天 / 'weekly'=每周几。
  String? _repeatType;

  /// 「每周几」选中的星期（1=周一 … 7=周日）。
  final Set<int> _weekdays = <int>{};
  String? _err;

  late FixedExtentScrollController _hourCtrl;
  late FixedExtentScrollController _minuteCtrl;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final base = widget.initialDate ?? now;
    _day = DateTime(base.year, base.month, base.day);
    _hour = now.hour;
    _minute = now.minute;
    _hourCtrl = FixedExtentScrollController(initialItem: _hour);
    _minuteCtrl = FixedExtentScrollController(initialItem: _minute);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _hourCtrl.dispose();
    _minuteCtrl.dispose();
    super.dispose();
  }

  // 2026-10-18：日期选择改为**在本弹窗内切换内容**，不再开第二层 Dialog
  //（两层叠加时下层白底会从上层四周透出一圈灰边）。
  void _pickDay() => setState(() => _pickingDate = true);

  DateTime get _pickFirst {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 30));
  }

  DateTime get _pickLast => DateTime.now().add(const Duration(days: 730));

  String get _dayLabel {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = _day.difference(today).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '明天';
    if (diff == -1) return '昨天';
    return '${_day.month}月${_day.day}日';
  }

  void _submit() {
    final title = _titleCtrl.value.text.trim();
    if (title.isEmpty) {
      setState(() => _err = '请填写待办名称');
      return;
    }
    // 选了「每周」但一天都没勾 → 拦一下，否则规则等于不生效。
    if (_repeatType == 'weekly' && _weekdays.isEmpty) {
      setState(() => _err = '请至少选择一个星期');
      return;
    }
    final desc = _descCtrl.value.text.trim();
    Navigator.of(context).pop(
      Todo(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        title: title,
        description: desc.isEmpty ? null : desc,
        date: _day,
        dueAt: DateTime(_day.year, _day.month, _day.day, _hour, _minute),
        repeatType: _repeatType,
        repeatDays: _weekdays.toList()..sort(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = context.surfaceColor;
    final border = isDark ? const Color(0xFF2C2C2C) : const Color(0xFFE5E7EB);
    final hint = isDark ? const Color(0xFF8B8B8B) : const Color(0xFF9CA3AF);
    final labelColor = isDark ? const Color(0xFFA1A1AA) : const Color(0xFF6B7280);

    InputDecoration deco(String hintText) => InputDecoration(
          hintText: hintText,
          hintStyle: TextStyle(fontSize: 14, color: hint),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: AppTheme.primaryColor),
          ),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        );

    // 滚轮：两位数字
    Widget wheelColumn({
      required FixedExtentScrollController ctrl,
      required int count,
      required ValueChanged<int> onChanged,
    }) {
      return SizedBox(
        width: 62,
        // 2026-10-18 第二轮：高度仍接近一行，但**上下各露出一点相邻数字**，
        // 作为「这里可以上下转」的提示；边缘用渐变遮罩淡出，避免硬切边。
        // 54 = 当前行 34 + 上下各 10px 的邻居露头。
        height: 58,
        child: ShaderMask(
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.white,
              Colors.white,
              Colors.transparent,
            ],
            // 淡出区间收窄：让上下邻居露出足够多，能看出「还有数字可以转」。
            stops: [0.0, 0.16, 0.84, 1.0],
          ).createShader(rect),
          blendMode: BlendMode.dstIn,
          child: CupertinoPicker(
            scrollController: ctrl,
            itemExtent: 34,
            // 放大倍数压到最小，否则当前值会被上下裁边。
            useMagnifier: true,
            magnification: 1.04,
            // 仍不画上下分隔线：外层 Container 已有 1px 边框。
            selectionOverlay: const SizedBox.shrink(),
            onSelectedItemChanged: onChanged,
            children: [
              for (int i = 0; i < count; i++)
                Center(
                  child: Text(
                    i.toString().padLeft(2, '0'),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w500),
                  ),
                ),
            ],
          ),
        ),
      );
    }

  /// 重复方式的小胶囊（不重复 / 每天 / 每周）。
  Widget repeatChip(String label, bool active, VoidCallback onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lineColor =
        isDark ? const Color(0xFF2C2C2C) : const Color(0xFFE5E7EB);
    final txtColor =
        isDark ? const Color(0xFFEDEDED) : const Color(0xFF374151);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppTheme.primaryColor : Colors.transparent,
          border: Border.all(color: active ? AppTheme.primaryColor : lineColor),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            color: active ? Colors.white : txtColor,
          ),
        ),
      ),
    );
  }

  /// 「每周几」的横向圆点（周一到周日，可多选）。
  Widget weekdayDot(int weekday) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lineColor =
        isDark ? const Color(0xFF2C2C2C) : const Color(0xFFE5E7EB);
    final txtColor =
        isDark ? const Color(0xFFEDEDED) : const Color(0xFF6B7280);
    final active = _weekdays.contains(weekday);
    return GestureDetector(
      onTap: () => setState(() {
        if (!_weekdays.remove(weekday)) _weekdays.add(weekday);
      }),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? AppTheme.primaryColor : Colors.transparent,
          shape: BoxShape.circle,
          border: Border.all(color: active ? AppTheme.primaryColor : lineColor),
        ),
        child: Text(
          const ['一', '二', '三', '四', '五', '六', '日'][weekday - 1],
          style: TextStyle(
            fontSize: 12.5,
            color: active ? Colors.white : txtColor,
          ),
        ),
      ),
    );
  }

    // 日期选择态：同一个盒子里换成月历面板（标题、圆角、边框保持一致）。
    if (_pickingDate) {
      return AlertDialog(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        ),
        contentPadding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
        content: SizedBox(
          width: 330,
          child: DatePickPanel(
            initial: _day,
            first: _pickFirst,
            last: _pickLast,
            onCancel: () => setState(() => _pickingDate = false),
            onConfirm: (picked) {
              setState(() {
                _day = DateTime(picked.year, picked.month, picked.day);
                _pickingDate = false;
              });
            },
          ),
        ),
      );
    }

    return AlertDialog(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 14, 8, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      title: Row(
        children: [
          const Text('新增待办',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const Spacer(),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: '关闭',
          ),
        ],
      ),
      content: SizedBox(
        width: 330,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _titleCtrl,
                autofocus: true,
                style: const TextStyle(fontSize: 15),
                decoration: deco('待办名称（如：交高数作业）'),
              ),
              const SizedBox(height: 12),

              // 日期
              GestureDetector(
                onTap: _pickDay,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: border),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Text(_dayLabel, style: const TextStyle(fontSize: 14)),
                      const Spacer(),
                      Text('选择日期',
                          style: TextStyle(fontSize: 11.5, color: hint)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // 时间：上下滚轮（时 / 分）
              Container(
                padding: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: border),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    wheelColumn(
                      ctrl: _hourCtrl,
                      count: 24,
                      onChanged: (v) => setState(() => _hour = v),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(':',
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: labelColor)),
                    ),
                    wheelColumn(
                      ctrl: _minuteCtrl,
                      count: 60,
                      onChanged: (v) => setState(() => _minute = v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // 重复（2026-10-18 用户要求：三种情况由点击决定展开）
              //   不重复 / 每天 / 每周 → 点「每周」才展开周一到周日的横向选择。
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  border: Border.all(color: border),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('重复',
                            style:
                                TextStyle(fontSize: 13, color: labelColor)),
                        const SizedBox(width: 10),
                        repeatChip('不重复', _repeatType == null,
                            () => setState(() => _repeatType = null)),
                        const SizedBox(width: 8),
                        repeatChip('每天', _repeatType == 'daily',
                            () => setState(() => _repeatType = 'daily')),
                        const SizedBox(width: 8),
                        repeatChip('每周', _repeatType == 'weekly', () {
                          setState(() {
                            _repeatType = 'weekly';
                            // 首次点「每周」默认勾上当前这一天，避免空选。
                            if (_weekdays.isEmpty) {
                              _weekdays.add(_day.weekday);
                            }
                          });
                        }),
                      ],
                    ),
                    if (_repeatType == 'weekly') ...[
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          for (var i = 1; i <= 7; i++) weekdayDot(i),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),

              TextField(
                controller: _descCtrl,
                maxLines: 3,
                style: const TextStyle(fontSize: 14),
                decoration: deco('内容（可省略，填了可以直接点任务查看）'),
              ),
              if (_err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_err!,
                      style: const TextStyle(
                          fontSize: 12.5, color: Color(0xFFB91C1C))),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消', style: TextStyle(fontSize: 14, color: labelColor)),
        ),
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryColor,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          ),
          child: const Text('保存',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
