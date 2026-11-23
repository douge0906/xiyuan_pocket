import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 自定义时间选择器：替换系统 `showTimePicker`。
///
/// ## 为什么不用系统的 `showTimePicker`
/// 系统那个是 Material 3 的表盘/输入切换，配色、圆角、字号全都不跟 App 主题
/// 走，浅色和深色下都跟旁边的输入框格格不入。2026-11-23 之前，考试添加页的
/// 「开始时间 / 结束时间」是全 App 仅剩的两个系统选择器（日期那个同批换成了
/// [showCourseDatePicker]）。
///
/// ## 为什么长成这样（**照抄 `semester_picker.dart`，不要另创一套**）
/// 这个 App 里滚轮选择器本来就有唯一一种写法：`semester_picker.dart`
/// （学期选择）与 `add_todo_dialog.dart` 的内嵌时钟（待办时间）都是
/// `CupertinoPicker` + `ShaderMask` 上下渐隐 + `useMagnifier 1.04` +
/// `selectionOverlay: SizedBox.shrink()`（不画分隔线）。
///
/// 第一版这里写的是 `ListWheelScrollView` + 自绘主题色高亮框 + 30px 大字预览，
/// 视觉上成了全 App 第三种选择器语言 —— 用户一眼就看出来了（2026-11-23
/// 「app有日期和时间选择器」）。所以整份按学期选择器重写：
/// 同一个 `Dialog` 外壳、同一条标题分隔线、同一对「取消 / 确定」按钮。
///
/// 用户另外明确要求过「**选择类弹窗统一用白色**」，因此这里固定
/// `Colors.white`，**不跟随深色模式**（与 `semester_picker.dart` 一致）。
Future<TimeOfDay?> showCourseTimePicker({
  required BuildContext context,
  required TimeOfDay initialTime,
  String? helpText,
}) {
  return showDialog<TimeOfDay?>(
    context: context,
    builder: (_) => _CourseTimePickerDialog(
      initialTime: initialTime,
      helpText: helpText,
    ),
  );
}

class _CourseTimePickerDialog extends StatefulWidget {
  final TimeOfDay initialTime;
  final String? helpText;

  const _CourseTimePickerDialog({
    required this.initialTime,
    this.helpText,
  });

  @override
  State<_CourseTimePickerDialog> createState() =>
      _CourseTimePickerDialogState();
}

class _CourseTimePickerDialogState extends State<_CourseTimePickerDialog> {
  /// 滚轮每项高度。与 `semester_picker.dart` 的 `itemExtent: 40` 对齐。
  static const double _itemExtent = 40;

  /// 滚轮区高度。200 = 一行 40 × 5 行，上下各露半行提示「可以上下转」。
  static const double _wheelHeight = 200;

  late int _hour;
  late int _minute;
  late FixedExtentScrollController _hourCtrl;
  late FixedExtentScrollController _minuteCtrl;

  @override
  void initState() {
    super.initState();
    _hour = widget.initialTime.hour.clamp(0, 23);
    _minute = widget.initialTime.minute.clamp(0, 59);
    _hourCtrl = FixedExtentScrollController(initialItem: _hour);
    _minuteCtrl = FixedExtentScrollController(initialItem: _minute);
  }

  @override
  void dispose() {
    _hourCtrl.dispose();
    _minuteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 与 semester_picker.dart 完全一致的三色：正文 / 次要 / 分隔线。
    // 这里刻意不读 Theme 的深色值 —— 选择类弹窗固定纯白。
    const ink = Color(0xFF1F1F1F);
    const sub = Color(0xFF9CA3AF);
    const border = Color(0xFFE8E8EE);

    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: const BorderSide(color: border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题行：标签 + 右上角关闭（R8：盒子右上角必须有 ×）
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.helpText ?? '选择时间',
                      style: const TextStyle(
                        fontSize: AppTheme.fontBody,
                        fontWeight: FontWeight.w600,
                        color: ink,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 20, color: sub),
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: border),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _wheel(
                    controller: _hourCtrl,
                    count: 24,
                    semanticLabel: '小时',
                    onPicked: (v) => setState(() => _hour = v),
                    ink: ink,
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      ':',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: ink,
                      ),
                    ),
                  ),
                  _wheel(
                    controller: _minuteCtrl,
                    count: 60,
                    semanticLabel: '分钟',
                    onPicked: (v) => setState(() => _minute = v),
                    ink: ink,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        '取消',
                        style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context)
                          .pop(TimeOfDay(hour: _hour, minute: _minute)),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primaryColor,
                        minimumSize: const Size(0, 44),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMd),
                        ),
                      ),
                      child: const Text(
                        '确定',
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
          ],
        ),
      ),
    );
  }

  /// 单个滚轮 —— 与 `semester_picker.dart` 的滚轮逐项对齐：
  /// `CupertinoPicker` + `itemExtent 40` + `useMagnifier 1.04`
  /// + 不画 `selectionOverlay`（外框已有 1px 边框，再画线就是双线）。
  ///
  /// 上下用 `ShaderMask` 渐隐，让边缘数字淡出，而不是硬切边。
  Widget _wheel({
    required FixedExtentScrollController controller,
    required int count,
    required String semanticLabel,
    required ValueChanged<int> onPicked,
    required Color ink,
  }) {
    return SizedBox(
      width: 76,
      height: _wheelHeight,
      child: Semantics(
        label: semanticLabel,
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
            stops: [0.0, 0.18, 0.82, 1.0],
          ).createShader(rect),
          blendMode: BlendMode.dstIn,
          child: CupertinoPicker(
            scrollController: controller,
            itemExtent: _itemExtent,
            useMagnifier: true,
            magnification: 1.04,
            selectionOverlay: const SizedBox.shrink(),
            onSelectedItemChanged: onPicked,
            children: [
              for (int i = 0; i < count; i++)
                Center(
                  child: Text(
                    i.toString().padLeft(2, '0'),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: ink,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
