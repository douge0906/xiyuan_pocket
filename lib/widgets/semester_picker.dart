import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/academic_term.dart';
import '../theme/app_theme.dart';

/// 统一的学期选择器。
///
/// 2026-11-04（用户 m19892 #1）：原来的实现是一列长列表（`ListView` 逐行
/// `InkWell`），一学期一行、8 个学期塞满一屏还得滚 —— 用户要求改成
/// **和待办里一致的滚轮选择器**，并且标签缩短成 `26-27-1` 这种写法。
///
/// 样式沿用 `add_todo_dialog.dart` 里那套：`CupertinoPicker` +
/// `itemExtent 34` + `useMagnifier 1.04` + 上下 `ShaderMask` 渐隐，
/// 不画分隔线（外框已有 1px 边框）。**纯白底**，不跟随深色模式 ——
/// 用户明确要求过「选择类弹窗统一用白色」。
///
/// 返回：选中的下标；直接关闭返回 null。
Future<int?> showSemesterPicker(
  BuildContext context, {
  required List<String> labels,
  required int currentIndex,
  String title = '选择学期',
}) {
  if (labels.isEmpty) return Future<int?>.value();
  final safeIndex = currentIndex.clamp(0, labels.length - 1);

  return showDialog<int>(
    context: context,
    builder: (ctx) {
      const ink = Color(0xFF1F1F1F);
      const sub = Color(0xFF9CA3AF);
      const border = Color(0xFFE8E8EE);

      return _SemesterWheelDialog(
        labels: labels,
        initialIndex: safeIndex,
        title: title,
        ink: ink,
        sub: sub,
        border: border,
      );
    },
  );
}

class _SemesterWheelDialog extends StatefulWidget {
  const _SemesterWheelDialog({
    required this.labels,
    required this.initialIndex,
    required this.title,
    required this.ink,
    required this.sub,
    required this.border,
  });

  final List<String> labels;
  final int initialIndex;
  final String title;
  final Color ink;
  final Color sub;
  final Color border;

  @override
  State<_SemesterWheelDialog> createState() => _SemesterWheelDialogState();
}

class _SemesterWheelDialogState extends State<_SemesterWheelDialog> {
  late int _index = widget.initialIndex;
  late final FixedExtentScrollController _ctrl =
      FixedExtentScrollController(initialItem: widget.initialIndex);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(color: widget.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: FontWeight.w600,
                          color: widget.ink),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded,
                        size: 20, color: widget.sub),
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFE8E8EE)),
            // 滚轮：一行 40，上下各露半行，提示「可以上下转」。
            SizedBox(
              height: 200,
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
                  scrollController: _ctrl,
                  itemExtent: 40,
                  useMagnifier: true,
                  magnification: 1.04,
                  selectionOverlay: const SizedBox.shrink(),
                  onSelectedItemChanged: (i) => setState(() => _index = i),
                  children: [
                    for (final label in widget.labels)
                      Center(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w500,
                            color: widget.ink,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text('取消',
                          style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              color: Colors.grey.shade600)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(_index),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primaryColor,
                        minimumSize: const Size(0, 44),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMd),
                        ),
                      ),
                      child: const Text('确定',
                          style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              fontWeight: FontWeight.w600)),
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
}

/// 生成最近 [terms] 个学期的短标签（默认 8 个 = 4 学年）。
///
/// 2026-11-04（用户 m19892 #1）：格式从 `2025-2026 第1学期` 改成
/// **`25-26-1`** —— 用户原话给的样例就是这种写法，一排能看全四年，
/// 滚轮里也不再被折行。
///
/// 口径复用 [recentAcademicTerms]（1 月寒假属上一年第一学期），
/// 不许再写第二套 `month >= 8` 二分：那样 1 月会被算成第二学期。
List<String> recentSemesterLabels({int terms = 8}) {
  return recentAcademicTerms(terms).map(shortTermLabel).toList();
}

/// 单个学期的短标签：`25-26-1`。
///
/// `AcademicTerm.term` 的取值是 3（第一学期）/ 12（第二学期），
/// 统一折成 1 / 2，与用户给的样例一致。
String shortTermLabel(AcademicTerm t) {
  final a = (t.year % 100).toString().padLeft(2, '0');
  final b = ((t.year + 1) % 100).toString().padLeft(2, '0');
  final half = t.term == 3 ? 1 : 2;
  return '$a-$b-$half';
}
