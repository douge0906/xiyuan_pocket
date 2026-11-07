import 'package:flutter/material.dart';

/// 统一按压反馈：按下时轻微缩小，松手回弹。
///
/// 项目里所有「可点卡片 / 按钮」都用它，视觉与手感保持一致。
///
/// 🔴 2026-11-03（1.0.9）：**振动不再由这里负责**。
///   原来 `haptic: true` 会在按下时调 `HapticFeedback.selectionClick()`，
///   而同一个 App 里还有 `InkWell`（走 `Feedback.forTap`）、`TextButton`、
///   `IconButton` 等一大票控件各走各的，于是「有的地方震、有的地方不震」，
///   且三档强度在 Flutter 侧根本拉不开（都落到系统 LONG_PRESS 常量）。
///   现在全部点击统一由 [TapHapticsScope]（`lib/widgets/tap_haptics.dart`）
///   在指针层接管，强度走原生 `Vibrator`，见 `lib/services/haptics.dart`。
///   若这里再震一次就会「点一下震两下」，所以本组件的震动路径已删除。
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.985,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _pressed ? widget.scale : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
