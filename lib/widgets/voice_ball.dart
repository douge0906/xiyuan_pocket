import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// **语言球**：屏幕中央的语音输入浮层（2026-10-31）。
///
/// 长按首页「＋」→ 屏幕中央弹出这枚球 → 说话 → 球上实时显示
/// 「听到了什么」→ 识别完成后收起，转入最终确认面板。
///
/// 视觉：
///   · 一枚居中的圆球，表面有随音量起伏的波纹；
///   · 球下方实时显示识别中的文字；
///   · 点球或按返回键可随时取消。
///
/// 动效只动**球自己的装饰层**（波纹），**不动文字位置** ——
/// 文字位移会重栅格化导致闪烁。
class VoiceBallOverlay extends StatefulWidget {
  const VoiceBallOverlay({
    super.key,
    required this.controller,
    required this.onCancel,
  });

  /// 对外控制器：调用方持有它，用来实时更新识别文字与音量。
  final VoiceBallController controller;

  /// 用户取消（点球 / 返回键 / 点遮罩）。
  final VoidCallback onCancel;

  /// 显示成一个覆盖全屏的浮层。
  static Future<void> show(
    BuildContext context, {
    required VoiceBallController controller,
    required VoidCallback onCancel,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: .45),
      builder: (_) => VoiceBallOverlay(
        controller: controller,
        onCancel: onCancel,
      ),
    );
  }

  @override
  State<VoiceBallOverlay> createState() => _VoiceBallOverlayState();
}

class _VoiceBallOverlayState extends State<VoiceBallOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    widget.controller.attach(
      setText: _setText,
      setLevel: _setLevel,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _setText(String t) {
    if (!mounted) return;
    setState(() => _text = t);
  }

  void _setLevel(double v) {
    if (!mounted) return;
    setState(() => _level = v.clamp(0.0, 1.0));
  }

  String _text = '';
  double _level = 0;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: widget.onCancel,
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 球 + 波纹
              SizedBox(
                width: 168,
                height: 168,
                child: AnimatedBuilder(
                  animation: _ctrl,
                  builder: (context, child) {
                    final t = Curves.easeInOut.transform(_ctrl.value);
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        // 外圈波纹（随音量扩散）
                        CustomPaint(
                          size: const Size(168, 168),
                          painter: _RipplePainter(
                            phase: t,
                            level: _level,
                            color: Colors.white,
                          ),
                        ),
                        // 球体
                        Container(
                          width: 104,
                          height: 104,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                Colors.white.withValues(alpha: .28),
                                Colors.white.withValues(alpha: .10),
                              ],
                            ),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: .55),
                              width: 1.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.white.withValues(alpha: .18),
                                blurRadius: 28,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.mic_rounded,
                            size: 44,
                            color: Colors.white.withValues(alpha: .92),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 22),
              // 识别中的文字（位置固定，不做位移动画 → 不会闪烁）
              SizedBox(
                width: 280,
                child: Text(
                  _text.isEmpty ? '请说话…' : _text,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTheme.fontTitle,
                    height: 1.5,
                    color: Colors.white.withValues(alpha: _text.isEmpty ? .7 : 1),
                    fontWeight:
                        _text.isEmpty ? FontWeight.w400 : FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '点击任意处取消',
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  color: Colors.white.withValues(alpha: .55),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 语言球的对外控制器（由调用方持有）。
///
/// 调用方在弹出浮层**之前**创建它，浮层挂载后 `attach` 会被调用，
/// 此后调用方就能通过 [setText] / [setLevel] 实时更新球上的内容。
class VoiceBallController {
  void Function(String text)? _setText;
  void Function(double level)? _setLevel;

  /// 浮层挂载后由它注入实现。
  void attach({
    required void Function(String text) setText,
    required void Function(double level) setLevel,
  }) {
    _setText = setText;
    _setLevel = setLevel;
  }

  /// 更新识别中的文字。
  void setText(String text) => _setText?.call(text);

  /// 更新音量强度（0~1）。
  void setLevel(double level) => _setLevel?.call(level);
}

/// 波纹绘制：随音量扩散的同心圆环。
class _RipplePainter extends CustomPainter {
  _RipplePainter({
    required this.phase,
    required this.level,
    required this.color,
  });

  final double phase;
  final double level;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // 有声音时波纹更强；没声音时只留一圈微弱的呼吸。
    final strength = 0.18 + level * 0.5;
    for (var i = 0; i < 3; i++) {
      final p = (phase + i / 3) % 1.0;
      final radius = size.width * (0.26 + p * 0.22);
      final opacity = (1 - p) * strength;
      if (opacity <= 0.01) continue;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RipplePainter old) =>
      old.phase != phase || old.level != level || old.color != color;
}
