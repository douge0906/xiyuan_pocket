import 'package:flutter/widgets.dart';

import '../services/haptics.dart';

/// 全局「点一下就震」（2026-11-03，1.0.9）。
///
/// 🔴 为什么不在每个可点控件里逐个加：
///   全仓可点控件是 `InkWell` 60 处 + `TextButton` 60 处 + `IconButton` 45 处
///   + `GestureDetector` 37 处 + `ElevatedButton` 18 处 + `FilledButton` 8 处
///   + `ListTile` 8 处 —— 逐个改既改不全，也一定会漏掉以后新加的。
///   用户要的是「所有点击都震」，那就只能从**指针层**统一接。
///
/// 做法：在 MaterialApp 的 `builder` 里把整棵树包一层 [Listener]，
///   记录每次按下的时间与位置，松手时判定「这是不是一次点击」：
///   · 按住时间 ≤ [maxTapMs]（320ms）；
///   · 位移 ≤ [maxMovePx]（12 逻辑像素）。
///   两条都满足才算点击，于是**滑动列表、拖拽、长按拖动都不会误震**。
///
/// 为什么在「松手」时震而不是「按下」时：按下那一刻还分不清用户是要点
/// 还是要滑，只有松手时才知道。代价是震动比视觉按下晚几十毫秒，可以接受；
/// 反过来如果在按下时就震，用户每次开始滑动列表都会被震一下，那才是灾难。
class TapHapticsScope extends StatefulWidget {
  const TapHapticsScope({super.key, required this.child});

  final Widget child;

  /// 超过这个时长就不算「点击」（长按 / 拖拽）。
  static const int maxTapMs = 320;

  /// 超过这个位移就不算「点击」（滑动）。
  static const double maxMovePx = 12;

  @override
  State<TapHapticsScope> createState() => _TapHapticsScopeState();
}

class _TapHapticsScopeState extends State<TapHapticsScope> {
  final Map<int, _PointerDown> _downs = <int, _PointerDown>{};

  @override
  Widget build(BuildContext context) {
    return Listener(
      // translucent：只监听，不吃掉事件，子树的点击/滚动一律不受影响。
      behavior: HitTestBehavior.translucent,
      onPointerDown: (PointerDownEvent e) {
        _downs[e.pointer] = _PointerDown(e.position, DateTime.now());
      },
      onPointerUp: (PointerUpEvent e) {
        final down = _downs.remove(e.pointer);
        if (down == null) return;
        final ms = DateTime.now().difference(down.time).inMilliseconds;
        if (ms > TapHapticsScope.maxTapMs) return;
        if ((e.position - down.position).distance >
            TapHapticsScope.maxMovePx) {
          return;
        }
        Haptics.tap();
      },
      onPointerCancel: (PointerCancelEvent e) => _downs.remove(e.pointer),
      child: widget.child,
    );
  }
}

class _PointerDown {
  const _PointerDown(this.position, this.time);

  final Offset position;
  final DateTime time;
}
