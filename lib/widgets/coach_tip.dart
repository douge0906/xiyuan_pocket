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
/// 两种朝向：
/// - 默认（`arrowDown == false`）：气泡在目标**下方**，箭头在卡片上沿、朝上指。
///   用法：`Stack` 最后一个孩子，`top` 给气泡上沿。
/// - `arrowDown == true`：气泡在目标**上方**，箭头在卡片下沿、朝下指。
///   用法：`bottom` 给气泡下沿到 Stack 底部的距离。
///
/// 2026-11-28：第二种朝向是给「未登录时的友情提醒」加的 —— 那张卡要悬在
/// 「新生需要进行统一认证登录账户激活」这一行**上方**并朝下指着它，
/// 而不是插进页面流里（插进去就跟着页面一起滚，看起来不像引导）。
class CoachTipOverlay extends StatefulWidget {
  const CoachTipOverlay({
    super.key,
    required this.title,
    required this.message,
    required this.onDismissed,
    this.top,
    this.bottom,
    this.arrowRightInset = 26,
    this.width = 264,
    this.arrowDown = false,
  }) : assert(top != null || bottom != null, 'top 和 bottom 至少要给一个');

  final String title;
  final String message;

  /// 气泡上沿（相对 Stack 顶部）。用于箭头朝上的情形。
  final double? top;

  /// 气泡下沿到 Stack 底部的距离。用于箭头朝下（`arrowDown`）的情形。
  final double? bottom;

  /// 箭头中心距右边缘的距离 —— 要和它指向的目标水平位置对齐。
  final double arrowRightInset;

  final double width;

  /// true = 气泡在上、箭头朝下指；false = 气泡在下、箭头朝上指。
  final bool arrowDown;

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
    final bubble = AnimatedBuilder(
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
                      padding: const EdgeInsets.symmetric(horizontal: 18),
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
          // 小三角：一个 45° 旋转的小方块，压住卡片边缘。
          Positioned(
            top: widget.arrowDown ? null : -5,
            bottom: widget.arrowDown ? -5 : null,
            right: widget.arrowRightInset,
            child: Transform.rotate(
              angle: math.pi / 4,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                  border: widget.arrowDown
                      ? Border(
                          right: BorderSide(color: context.borderColor),
                          bottom: BorderSide(color: context.borderColor),
                        )
                      : Border(
                          top: BorderSide(color: context.borderColor),
                          left: BorderSide(color: context.borderColor),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

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
          if (widget.arrowDown)
            Positioned(
              right: 14,
              bottom: widget.bottom!,
              child: bubble,
            )
          else
            Positioned(
              top: widget.top!,
              right: 14,
              child: bubble,
            ),
        ],
      ),
    );
  }
}
