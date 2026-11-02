import 'package:flutter/material.dart';

import '../services/ui_prefs.dart';

/// 首页空状态的轻手绘勾选插画。
class EmptyTodoArt extends StatefulWidget {
  const EmptyTodoArt({super.key, required this.color, this.size = 92});

  final Color color;
  final double size;

  @override
  State<EmptyTodoArt> createState() => _EmptyTodoArtState();
}

class _EmptyTodoArtState extends State<EmptyTodoArt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    if (!UiPrefs.motionOff) _ctrl.repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, child) {
          // 极轻微的呼吸（±3% 缩放 + 2% 位移），几乎察觉不到，但画面「活」了。
          final t = Curves.easeInOut.transform(_ctrl.value);
          return Transform.translate(
            offset: Offset(0, -2 * t),
            child: Transform.scale(scale: 1 + 0.03 * t, child: child),
          );
        },
        child: CustomPaint(painter: _EmptyTodoPainter(widget.color)),
      ),
    );
  }
}

class _EmptyTodoPainter extends CustomPainter {
  _EmptyTodoPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(
      c,
      size.width * .46,
      Paint()..color = color.withValues(alpha: .10),
    );
    final ink = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final check = Path()
      ..moveTo(size.width * .28, size.height * .52)
      ..lineTo(size.width * .44, size.height * .68)
      ..lineTo(size.width * .73, size.height * .35);
    canvas.drawPath(check, ink);
    final spark = Paint()
      ..color = color.withValues(alpha: .55)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(size.width * .79, size.height * .22),
        Offset(size.width * .86, size.height * .16), spark);
    canvas.drawLine(Offset(size.width * .84, size.height * .30),
        Offset(size.width * .92, size.height * .28), spark);
    canvas.drawLine(Offset(size.width * .18, size.height * .72),
        Offset(size.width * .11, size.height * .80), spark);
  }

  @override
  bool shouldRepaint(covariant _EmptyTodoPainter oldDelegate) =>
      oldDelegate.color != color;
}
