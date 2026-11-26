import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/service_group.dart';
import '../models/tool_model.dart';
import '../theme/app_theme.dart';

/// 服务页的「新功能」叠层卡片。
///
/// 交互（用户 2026-11-26 提的形态）：
///   1. 首次进入服务页 → 背景压一层灰，屏幕中间浮起一叠卡片；
///   2. 卡片上写着这次新增的服务，往左一滑 → 卡片飞走，它对应的格子亮一下；
///   3. 全部滑完 → 灰层淡出，服务页恢复原样。
///
/// 刻意做成**叠层**而不是弹窗列表：卡片一张张减少的过程本身就是「还剩几个新东西」
/// 的进度感；滑动的动作比点「下一步」更像在翻东西，而不是在读完一份说明书。
///
/// 不用 `showDialog`：这里需要背景、卡片、下面格子的高亮同时动，放进 Navigator
/// 反而拿不到页面坐标系（高亮要落在真实格子上）。所以它是一个盖在页面上的
/// `Positioned.fill`，由页面自己插进 Stack。
class ServiceIntroOverlay extends StatefulWidget {
  const ServiceIntroOverlay({
    super.key,
    required this.tools,
    required this.onFinished,
    this.onCardDismissed,
  });

  /// 要介绍的「新」服务，顺序就是卡片从上到下的顺序（最多展示 3 张）。
  final List<ToolModel> tools;

  /// 全部滑完（或用户点了「知道了」）之后调用。
  final VoidCallback onFinished;

  /// 每滑掉一张回调一次 —— 页面用它让对应格子闪一下，做成「变成一条服务」的落点。
  final ValueChanged<ToolModel>? onCardDismissed;

  @override
  State<ServiceIntroOverlay> createState() => _ServiceIntroOverlayState();
}

class _ServiceIntroOverlayState extends State<ServiceIntroOverlay>
    with TickerProviderStateMixin {
  /// 入场：0 → 1（灰层 + 卡片一起用这条曲线）。
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );

  /// 滑出：当前卡片飞走的那 200ms。
  late final AnimationController _fly = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  int _index = 0;
  Offset _drag = Offset.zero;
  bool _closing = false;

  bool get _flying => _fly.isAnimating;

  @override
  void initState() {
    super.initState();
    _enter.forward();
    _fly.addStatusListener((s) {
      if (s != AnimationStatus.completed || !mounted) return;
      _fly.value = 0;
      setState(() {
        _index++;
        _drag = Offset.zero;
      });
      if (_index >= _shown.length) _close();
    });
  }

  @override
  void dispose() {
    _enter.dispose();
    _fly.dispose();
    super.dispose();
  }

  /// 最多 3 张 —— 再多就不是「眼前一亮」，是又一份要读的清单。
  List<ToolModel> get _shown =>
      widget.tools.length > 3 ? widget.tools.sublist(0, 3) : widget.tools;

  void _close() {
    if (_closing) return;
    _closing = true;
    _enter.reverse().whenComplete(() {
      if (mounted) widget.onFinished();
    });
  }

  void _dismissCurrent({required bool bySwipe}) {
    if (_flying || _index >= _shown.length) return;
    final tool = _shown[_index];
    widget.onCardDismissed?.call(tool);
    if (bySwipe) {
      _fly.forward();
    } else {
      // 「知道了」直接收：跳过飞行，整体淡出。
      _close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final shown = _shown;
    if (shown.isEmpty) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: Listenable.merge([_enter, _fly]),
      builder: (context, _) {
        final t = Curves.easeOutCubic.transform(_enter.value.clamp(0.0, 1.0));
        final flyT = Curves.easeInCubic.transform(_fly.value);
        return Stack(
          children: [
            // 灰层：不是纯黑遮罩，带一点点模糊感的深灰，压住但不闷。
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.42 * t),
                ),
              ),
            ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: Center(
                  child: _cards(context, shown, t, flyT, isDark),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _cards(
    BuildContext context,
    List<ToolModel> shown,
    double t,
    double flyT,
    bool isDark,
  ) {
    final remaining = shown.length - _index;
    if (remaining <= 0) return const SizedBox.shrink();

    return SizedBox(
      width: 320,
      height: 400,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 后面的两张：只露出一条边，越靠后越小越淡。
          for (int i = math.min(remaining, 3); i >= 1; i--)
            _slot(i - 1, remaining, t, isDark),
        ],
      ),
    );
  }

  /// i = 0 是最上面那张。
  Widget _slot(int i, int remaining, double t, bool isDark) {
    final shown = _shown;
    final idx = _index + i;
    if (idx >= shown.length) return const SizedBox.shrink();
    final tool = shown[idx];

    // 入场：从下方 24px、缩放 0.94 浮上来，后面的卡片再叠一点延迟。
    final local = (t - i * 0.08).clamp(0.0, 1.0);
    final baseScale = 1.0 - i * 0.05;
    final baseOffset = i * 14.0;

    double dragX = 0;
    double dragY = 0;
    double rotate = 0;
    double fly = 0;
    if (i == 0) {
      dragX = _drag.dx;
      dragY = _drag.dy * 0.15;
      rotate = (_drag.dx / 900).clamp(-0.22, 0.22);
      // 往左滑出的位移：卡片按当前拖动方向飞远。
      fly = _fly.value == 0 ? 0 : -1 * (1 - _fly.value);
      if (fly != 0) {
        dragX += fly * 420;
        rotate += fly * 0.4;
      }
    }

    final card = _card(context, tool, i == 0, isDark);
    return Transform.translate(
      offset: Offset(dragX, baseOffset * (1 - t) + (24 * (1 - local)) + dragY),
      child: Transform.rotate(
        angle: rotate,
        child: Transform.scale(
          scale: baseScale * (0.94 + 0.06 * local),
          child: Opacity(
            opacity: (local * (i == 0 ? 1 : 0.75)).clamp(0.0, 1.0),
            child: i == 0
                ? GestureDetector(
                    onPanUpdate: _flying
                        ? null
                        : (d) => setState(() => _drag += d.delta),
                    onPanEnd: _flying
                        ? null
                        : (_) {
                            if (_drag.dx.abs() > 110) {
                              _dismissCurrent(bySwipe: true);
                            } else {
                              setState(() => _drag = Offset.zero);
                            }
                          },
                    child: card,
                  )
                : card,
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, ToolModel tool, bool top, bool isDark) {
    final tint = tool.color;
    return Container(
      width: 300,
      height: 360,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161616) : Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: context.borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: isDark ? 0.22 : 0.10),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: Icon(tool.icon, size: 22, color: tint),
              ),
              const Spacer(),
              Text(
                '新功能',
                style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  fontWeight: FontWeight.w600,
                  color: tint,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            tool.name,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: context.textPrimary,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            ServiceGroup.hintOf(tool.group) ?? '刚加的功能，点开就能用。',
            style: TextStyle(
              fontSize: AppTheme.fontSmall,
              height: 1.6,
              color: context.textSecondary,
            ),
          ),
          const Spacer(),
          if (top)
            Row(
              children: [
                Icon(Icons.swipe_left_rounded,
                    size: 16, color: context.textTertiary),
                const SizedBox(width: 6),
                Text(
                  '向左滑动收起',
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: context.textTertiary),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
