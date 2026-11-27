import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// 一次性引导气泡。
///
/// 2026-11-27 第 9 条：课表导入、课表设置导出、消息「＋」三处各来一张。
/// 三条共同要求是「有确认按钮，点别处则抖动卡片」——所以它不是 Dialog：
/// Dialog 点外面默认就关掉了，这里必须改成「点空白 → 抖一下，只有点『知道了』才走」。
///
/// 用法：作为 `Stack` 的最后一个孩子放进页面 body，`top` 给气泡上沿，
/// 上方的箭头会指向那个位置上面的按钮。
class CoachTipOverlay extends StatefulWidget {
  const CoachTipOverlay({
    super.key,
    required this.title,
    required this.message,
    required this.top,
    required this.onDismissed,
    this.arrowRightInset = 26,
    this.width = 264,
  });

  final String title;
  final String message;

  /// 气泡上沿（相对 Stack 顶部）。箭头画在它上面，指向更上面的按钮。
  final double top;

  /// 箭头中心距右边缘的距离 —— 要和它指向的那个按钮的水平位置对齐。
  final double arrowRightInset;

  final double width;

  /// 用户点了「知道了」。调用方负责落盘 + 收起。
  final VoidCallback onDismissed;

  @override
  State<CoachTipOverlay> createState() => _CoachTipOverlayState();
}

class _CoachTipOverlayState extends State<CoachTipOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  void _shakeIt() {
    HapticFeedback.mediumImpact();
    _shake.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Positioned.fill(
      child: Stack(
        children: [
          // 透明的整屏挡板：只负责接住「点别处」。不拦截就不会抖动。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _shakeIt,
            ),
          ),
          Positioned(
            top: widget.top,
            right: 14,
            child: AnimatedBuilder(
              animation: _shake,
              builder: (context, child) {
                final p = _shake.value;
                final dx = math.sin(p * math.pi * 6) * 9 * (1 - p);
                return Transform.translate(offset: Offset(dx, 0), child: child);
              },
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: widget.width,
                    padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                      border: Border.all(color: context.borderColor),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.14),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.lightbulb_outline_rounded,
                                size: 16, color: AppTheme.primaryColor),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                widget.title,
                                style: TextStyle(
                                  fontSize: AppTheme.fontBody,
                                  fontWeight: FontWeight.w600,
                                  color: context.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.message,
                          style: TextStyle(
                            fontSize: AppTheme.fontSmall,
                            height: 1.55,
                            color: context.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                            onPressed: widget.onDismissed,
                            style: FilledButton.styleFrom(
                              backgroundColor: AppTheme.primaryColor,
                              foregroundColor: Colors.white,
                              minimumSize: const Size(0, 32),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 18),
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(999),
                              ),
                              textStyle: const TextStyle(
                                fontSize: AppTheme.fontSmall,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            child: const Text('知道了'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 小三角：一个 45° 旋转的小方块，压住卡片上沿。
                  Positioned(
                    top: -5,
                    right: widget.arrowRightInset,
                    child: Transform.rotate(
                      angle: math.pi / 4,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                          border: Border(
                            top: BorderSide(color: context.borderColor),
                            left: BorderSide(color: context.borderColor),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
