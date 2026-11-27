import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/service_group.dart';
import '../models/tool_model.dart';
import '../theme/app_theme.dart';

/// 服务页的「新功能」叠层卡片。
///
/// 2026-11-27 用户第 2 条要求重做，相比 11-26 的第一版：
/// 1. 卡片变小、几张牌有明显折叠层次，底下有小圆点表示还剩几张；
/// 2. **向左滑 = 启用，向右滑 = 不启用（丢弃）**，另外给两个淡按钮兜底；
/// 3. 处理结果直接落到「服务设置页」的启用/隐藏状态上 —— 这里滑一下，
///    设置页里那个开关就跟着变，不再是一个只看不动的介绍页；
/// 4. 弹哪几张由「这条服务有没有被处理过」决定（见 toolbox_page 的
///    `_maybeShowIntro`），以后加新服务不用再手改展示清单。
///
/// 为什么不用 showDialog：灰层、牌堆、格子高亮要同时动，放进 Navigator
/// 就拿不到页面坐标，也压不住底下的 TabBar 动画。
class ServiceIntroOverlay extends StatefulWidget {
  const ServiceIntroOverlay({
    super.key,
    required this.tools,
    required this.onDecided,
    required this.onFinished,
  });

  /// 还没被处理过的服务，第一张在最上面。
  final List<ToolModel> tools;

  /// 用户对某一条做了决定：`enabled` 为 true 表示启用（保留），false 表示不启用。
  final void Function(ToolModel tool, bool enabled) onDecided;

  /// 全部处理完（或被划完）。
  final VoidCallback onFinished;

  @override
  State<ServiceIntroOverlay> createState() => _ServiceIntroOverlayState();
}

class _ServiceIntroOverlayState extends State<ServiceIntroOverlay>
    with TickerProviderStateMixin {
  // 三套动画各自独立：进场、飞出、点击别处抖动。
  // ⚠️ 必须是 TickerProviderStateMixin（多 ticker），Single 那个会直接抛。
  late final AnimationController _enter;
  late final AnimationController _fly;
  late final AnimationController _shake;

  Offset _drag = Offset.zero;
  ToolModel? _flying;
  int _flyDir = -1; // -1 向左（启用） / 1 向右（不启用）

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    )..forward();
    _fly = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _fly.addStatusListener((s) {
      if (s != AnimationStatus.completed) return;
      final tool = _flying;
      _flying = null;
      _drag = Offset.zero;
      _fly.reset();
      if (tool == null) return;
      widget.onDecided(tool, _flyDir < 0);
      if (!mounted) return;
      _enter.forward(from: 0);
    });
  }

  @override
  void didUpdateWidget(covariant ServiceIntroOverlay old) {
    super.didUpdateWidget(old);
    // 父级把某张牌去掉之后，牌堆要重新弹一下，否则看起来像卡住了。
    if (widget.tools.length != old.tools.length && widget.tools.isNotEmpty) {
      _enter.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _fly.dispose();
    _shake.dispose();
    super.dispose();
  }

  void _decide(bool enabled) {
    if (_flying != null || widget.tools.isEmpty) return;
    setState(() {
      _flying = widget.tools.first;
      _flyDir = enabled ? -1 : 1;
    });
    _fly.forward(from: 0);
  }

  void _shakeIt() {
    if (_flying != null) return;
    HapticFeedback.mediumImpact();
    _shake.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    if (widget.tools.isEmpty) {
      // 全部处理完，交给父级收尾（下一帧再动 setState，避免 build 期间改状态）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onFinished();
      });
      return const SizedBox.shrink();
    }

    final total = widget.tools.length;
    final shown = math.min(total, 3);

    return Positioned.fill(
      child: Stack(
        children: [
          // 灰层：点它就抖一下卡片，不关闭 —— 用户要么做决定，要么点「知道了」。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _shakeIt,
              child: AnimatedBuilder(
                animation: _enter,
                builder: (_, __) => ColoredBox(
                  color: Colors.black.withValues(alpha: 0.34 * _enter.value),
                ),
              ),
            ),
          ),
          Center(
            child: AnimatedBuilder(
              animation: Listenable.merge([_enter, _fly, _shake]),
              builder: (context, _) {
                final t = Curves.easeOutCubic.transform(_enter.value);
                return Transform.scale(
                  scale: 0.92 + 0.08 * t,
                  child: Opacity(opacity: t.clamp(0.0, 1.0), child: _body(context, isDark, shown, total)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, bool isDark, int shown, int total) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 300,
          height: 330,
          child: Stack(
            alignment: Alignment.center,
            children: [
              for (var i = shown; i >= 1; i--) _slot(i - 1, isDark),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _dots(total),
        const SizedBox(height: 18),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ghostButton(
              label: '不启用',
              onTap: () => _decide(false),
              isDark: isDark,
            ),
            const SizedBox(width: 14),
            _ghostButton(
              label: '启用',
              onTap: () => _decide(true),
              isDark: isDark,
              strong: true,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '点空白处可以让卡片停一下',
          style: TextStyle(
            fontSize: AppTheme.fontCaption,
            color: Colors.white.withValues(alpha: 0.62),
          ),
        ),
      ],
    );
  }

  /// 一张牌的位置。`i == 0` 是最上面那张（可拖动）。
  Widget _slot(int i, bool isDark) {
    final top = i == 0;
    final scale = 1 - i * 0.055;
    final offsetY = i * 13.0;
    final dx = top ? _drag.dx : 0.0;
    final dy = top ? _drag.dy : 0.0;
    var rotate = top ? (_drag.dx / 1400).clamp(-0.12, 0.12) : 0.0;

    // 抖动：左右各摆三次，幅度随进度衰减。
    var shakeX = 0.0;
    if (_shake.isAnimating) {
      final p = _shake.value;
      shakeX = math.sin(p * math.pi * 6) * 10 * (1 - p);
    }

    // 飞出：朝手势方向滑走并淡出。
    var flyX = 0.0;
    var opacity = 1.0;
    if (top && _flying != null) {
      final f = Curves.easeInCubic.transform(_fly.value);
      flyX = _flyDir * 420 * f;
      opacity = 1 - f;
      rotate = rotate + _flyDir * 0.16 * f;
    }

    final card = _card(widget.tools[i], isDark, top);
    return Transform.translate(
      offset: Offset(dx + flyX + shakeX, dy + offsetY),
      child: Transform.rotate(
        angle: rotate,
        child: Transform.scale(
          scale: scale,
          child: Opacity(opacity: opacity, child: card),
        ),
      ),
    );
  }

  Widget _card(ToolModel tool, bool isDark, bool top) {
    // 拖动方向决定提示色：向左 = 启用（墨黑），向右 = 不启用（警示黄）。
    final enabling = _drag.dx < -24;
    final dropping = _drag.dx > 24;
    final accent = dropping ? const Color(0xFFB45309) : AppTheme.primaryColor;

    final card = Container(
      width: 262,
      height: 300,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(
          color: dropping
              ? const Color(0xFFB45309).withValues(alpha: 0.35)
              : (isDark ? Colors.white12 : const Color(0xFFEDEDF0)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.42 : 0.16),
            blurRadius: 26,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: tool.color.withValues(alpha: isDark ? 0.22 : 0.10),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: Icon(tool.icon, size: 22, color: tool.color),
              ),
              const Spacer(),
              Text(
                dropping ? '不启用' : (enabling ? '启用' : '新功能'),
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  fontWeight: FontWeight.w600,
                  color: accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            tool.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              height: 1.25,
              color: context.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            ServiceGroup.titleOf(tool.group),
            style: TextStyle(
              fontSize: AppTheme.fontCaption,
              color: context.textTertiary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _descOf(tool),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppTheme.fontSmall,
              height: 1.45,
              color: context.textSecondary,
            ),
          ),
          const Spacer(),
          Row(
            children: [
              Icon(Icons.swipe_rounded, size: 14, color: context.textTertiary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '向左滑动启用 · 向右滑动不启用',
                  style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    color: context.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (!top) return IgnorePointer(child: card);

    return GestureDetector(
      onPanUpdate: (d) => setState(() => _drag += d.delta),
      onPanEnd: (_) {
        final dx = _drag.dx;
        if (dx.abs() > 96) {
          _decide(dx < 0);
        } else {
          setState(() => _drag = Offset.zero);
        }
      },
      child: card,
    );
  }

  /// 卡片上的一句话说明。优先用分组说明，其次按「要不要联网」给个中性描述。
  String _descOf(ToolModel tool) {
    final hint = ServiceGroup.hintOf(tool.group);
    if (tool.id == 'cprint_scan') {
      return '图书馆那台打印机，手机上就能传文件、看扫描件。';
    }
    if (tool.id == 'chaoxing_sync') {
      return '把学习通的作业和考试拉进来，别漏交。';
    }
    if (tool.id == 'timetable_library') {
      return '同学的课表可以直接导入，不用一门门加。';
    }
    return hint ?? (tool.needsNetwork ? '联网后可以用。' : '不需要联网。');
  }

  Widget _dots(int total) {
    const at = 0;
    final count = total.clamp(1, 6);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == at ? 16 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: i == at ? 0.92 : 0.34),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        if (total > 6) ...[
          const SizedBox(width: 8),
          Text(
            '共 $total 个',
            style: TextStyle(
              fontSize: AppTheme.fontCaption,
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
        ],
      ],
    );
  }

  Widget _ghostButton({
    required String label,
    required VoidCallback onTap,
    required bool isDark,
    bool strong = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 9),
        decoration: BoxDecoration(
          color: strong
              ? Colors.white.withValues(alpha: 0.92)
              : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: Colors.white.withValues(alpha: strong ? 0.0 : 0.28),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppTheme.fontSmall,
            fontWeight: FontWeight.w600,
            color: strong ? AppTheme.primaryColor : Colors.white,
          ),
        ),
      ),
    );
  }
}
