import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/ui_prefs.dart';

/// 统一按压反馈：按下时轻微缩小 + 可选震动，松手回弹。
///
/// 项目里所有「可点卡片 / 按钮」都用它，视觉与手感保持一致。
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.985,
    this.haptic = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;

  /// 是否在按下时给一次轻震动（跟随「振动反馈」设置）。
  final bool haptic;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null && widget.onLongPress == null
          ? null
          : (_) {
              setState(() => _pressed = true);
              if (widget.haptic && UiPrefs.haptics) {
                HapticFeedback.selectionClick();
              }
            },
      onTapUp: widget.onTap == null && widget.onLongPress == null
          ? null
          : (_) => setState(() => _pressed = false),
      onTapCancel: widget.onTap == null && widget.onLongPress == null
          ? null
          : () => setState(() => _pressed = false),
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
