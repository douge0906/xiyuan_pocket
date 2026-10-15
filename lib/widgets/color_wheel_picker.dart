import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 色盘选择器（v1.6.3，仿掌上徐工）：色相环绕圈 + 饱和度径向渐变 + 明度滑杆。
///
/// 拖动圆盘任意位置即可取任意颜色：**角度 = 色相，离圆心距离 = 饱和度**，
/// 明度由下方滑杆控制。用于设置页「主题色 / 背景色」的自定义取色。
Future<Color?> showColorWheelPicker(
  BuildContext context, {
  required Color initial,
  required String title,
}) {
  return showDialog<Color>(
    context: context,
    builder: (_) => _ColorWheelDialog(initial: initial, title: title),
  );
}

class _ColorWheelDialog extends StatefulWidget {
  const _ColorWheelDialog({required this.initial, required this.title});

  final Color initial;
  final String title;

  @override
  State<_ColorWheelDialog> createState() => _ColorWheelDialogState();
}

class _ColorWheelDialogState extends State<_ColorWheelDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);

  static const double _wheelSize = 216;

  void _updateFromPosition(Offset pos, Size size) {
    final center = size.center(Offset.zero);
    final delta = pos - center;
    final radius = size.shortestSide / 2;
    final saturation = (delta.distance / radius).clamp(0.0, 1.0);
    final hue = (math.atan2(delta.dy, delta.dx) * 180 / math.pi + 360) % 360;
    setState(() {
      _hsv = _hsv.withHue(hue).withSaturation(saturation);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg)),
      title: Text(widget.title,
          style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: SizedBox.square(
              dimension: _wheelSize,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = constraints.biggest;
                  return GestureDetector(
                    onPanDown: (d) => _updateFromPosition(d.localPosition, size),
                    onPanUpdate: (d) =>
                        _updateFromPosition(d.localPosition, size),
                    onTapDown: (d) => _updateFromPosition(d.localPosition, size),
                    child: CustomPaint(
                      painter: _ColorWheelPainter(hsv: _hsv),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 18),
          // 明度
          Row(
            children: [
              const SizedBox(
                width: 28,
                child: Text('明度',
                    style: TextStyle(fontSize: 12.5, color: Colors.grey)),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    activeTrackColor: _hsv.toColor(),
                    inactiveTrackColor: context.borderColor,
                    thumbColor: _hsv.toColor(),
                    overlayColor: _hsv.toColor().withOpacity(0.12),
                    thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7, elevation: 0),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 13),
                  ),
                  child: Slider(
                    value: _hsv.value.clamp(0.15, 1.0),
                    min: 0.15,
                    max: 1.0,
                    onChanged: (v) => setState(() => _hsv = _hsv.withValue(v)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // 预览
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _hsv.toColor(),
                  shape: BoxShape.circle,
                  border: Border.all(color: context.borderColor),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '#${_hsv.toColor().value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
                  style: TextStyle(
                      fontSize: 13.5,
                      color: context.textSecondary,
                      letterSpacing: 0.5),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(color: Colors.grey)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _hsv.toColor()),
          style: FilledButton.styleFrom(backgroundColor: AppTheme.primaryColor),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 色相环 + 饱和度径向渐变 + 当前色指示器。
class _ColorWheelPainter extends CustomPainter {
  const _ColorWheelPainter({required this.hsv});

  final HSVColor hsv;

  static const List<Color> _hueColors = [
    Color(0xFFFF0000),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFF00FFFF),
    Color(0xFF0000FF),
    Color(0xFFFF00FF),
    Color(0xFFFF0000),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;

    // ① 色相环（角度即色相）
    final huePaint = Paint()
      ..shader = const SweepGradient(
        colors: _hueColors,
        startAngle: 0,
        endAngle: math.pi * 2,
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, huePaint);

    // ② 饱和度：中心白 → 边缘透明
    final satPaint = Paint()
      ..shader = RadialGradient(
        colors: [Colors.white, Colors.white.withOpacity(0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, satPaint);

    // ③ 当前色指示器
    final angle = hsv.hue * math.pi / 180;
    final dist = hsv.saturation * radius;
    final pos = center + Offset(math.cos(angle) * dist, math.sin(angle) * dist);
    canvas.drawCircle(pos, 10, Paint()..color = Colors.white);
    canvas.drawCircle(pos, 7.5, Paint()..color = hsv.toColor());
    canvas.drawCircle(
      pos,
      10,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.black.withOpacity(0.25),
    );
  }

  @override
  bool shouldRepaint(covariant _ColorWheelPainter oldDelegate) =>
      oldDelegate.hsv != hsv;
}
