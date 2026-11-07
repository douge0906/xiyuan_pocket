import 'package:flutter/material.dart';

import '../services/course_storage.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';

/// 手绘简约风格全局背景（实验性，2026-11-04）。
///
/// 设计约束（改之前先读）：
///  1. **不引入任何图片资源**，全部用 [CustomPainter] 现画 —— 一套底图就是
///     几 KB 代码，不占包体、不依赖网络、任意屏幕密度都清晰。
///  2. **只画线 / 点，从不填充底色**。底色始终由主题的
///     `scaffoldBackgroundColor` 决定，所以明暗切换、用户自定义背景色、
///     圆角、字体全部不受影响。
///  3. 线条是**低对比纹理**：浅色 `#000000` alpha 0.03~0.06，深色
///     `#FFFFFF` alpha 0.025~0.05，线宽 1.0~1.2。目标是「一打眼是纸，
///     看内容时完全忽略它」。
///
/// 🔴 为什么必须叠在**最上层**（见 [buildHandDrawnBackground] 与 main.dart）：
///    五个 Tab 的页面各自带不透明 `Scaffold` 底色，任何画在 Navigator
///    **下面**的纹理都会被整块盖住，一行都看不见。所以这里做成
///    「Navigator 之上 + IgnorePointer 的不拦截点击的纹理层」。
enum HandDrawnBackground {
  none('none', '不启用'),
  ruled('ruled', '横线笔记'),
  dots('dots', '点阵纸'),
  grid('grid', '方格本'),
  diagonal('diagonal', '斜纹纸');

  const HandDrawnBackground(this.id, this.label);

  /// 持久化用的稳定标识。**不要改**：改了老用户的选择会静默丢回 none。
  final String id;

  /// 设置页里显示的中文名。
  final String label;

  static HandDrawnBackground fromId(String? id) {
    for (final k in HandDrawnBackground.values) {
      if (k.id == id) return k;
    }
    return HandDrawnBackground.none;
  }

  /// 是否真的是一套手绘纸纹（[none] 为 false）。
  bool get isHandDrawn => this != HandDrawnBackground.none;
}

/// 运行期唯一真相源：当前选中的手绘背景。
///
/// 持久化在 [StorageService]（键 `hand_drawn_background_v1`），
/// 这里只负责「改完立刻全 App 生效」（设置页点一下不用重启）。
final ValueNotifier<HandDrawnBackground> handDrawnBackgroundNotifier =
    ValueNotifier<HandDrawnBackground>(HandDrawnBackground.none);

/// 启动时恢复（在 `main()` 的 `loadAppearance()` 里 await，保证首帧就是对的）。
Future<void> restoreHandDrawnBackground() async {
  final id = await StorageService.loadHandDrawnBackground();
  handDrawnBackgroundNotifier.value = HandDrawnBackground.fromId(id);
}

/// 用户切换：先改内存（立即生效），再落盘。
Future<void> changeHandDrawnBackground(HandDrawnBackground kind) async {
  handDrawnBackgroundNotifier.value = kind;
  await StorageService.saveHandDrawnBackground(kind.id);
}

/// 给整棵树套上手绘纸纹；[HandDrawnBackground.none] 时原样返回 [child]
/// （不额外插任何 Widget，零开销）。
Widget buildHandDrawnBackground(
  HandDrawnBackground kind, {
  required bool isDark,
  required Widget child,
}) {
  if (!kind.isHandDrawn) return child;
  return HandDrawnBackgroundLayer(kind: kind, isDark: isDark, child: child);
}

/// 纸纹层：叠在 [child] 之上，且**不拦任何点击**。
///
/// 这里自己监听背景相关的通知，判断「用户是否设了自定义背景」：
/// 设了背景图或自定义背景色时纸纹不生效 —— 两者都属于「整屏铺底」的
/// 强视觉，再叠一层纸纹只会互相打架、还白白多一层绘制。
class HandDrawnBackgroundLayer extends StatefulWidget {
  const HandDrawnBackgroundLayer({
    super.key,
    required this.kind,
    required this.isDark,
    required this.child,
  });

  final HandDrawnBackground kind;
  final bool isDark;
  final Widget child;

  @override
  State<HandDrawnBackgroundLayer> createState() =>
      _HandDrawnBackgroundLayerState();
}

class _HandDrawnBackgroundLayerState extends State<HandDrawnBackgroundLayer> {
  @override
  void initState() {
    super.initState();
    AppTheme.backgroundNotifier.addListener(_onChanged);
    AppTheme.backgroundDarkNotifier.addListener(_onChanged);
    // 背景图是异步读出来的（课表显示设置），读完才会通知，所以要跟着刷新。
    CourseStorage.bgRevision.addListener(_onChanged);
  }

  @override
  void dispose() {
    AppTheme.backgroundNotifier.removeListener(_onChanged);
    AppTheme.backgroundDarkNotifier.removeListener(_onChanged);
    CourseStorage.bgRevision.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 用户是否已经设了「会盖住整屏」的自定义背景。
  ///
  /// 🔴 2026-11-04（m19335 #5）修：这里原来还判 `CourseStorage.backgroundColorCache != null`，
  ///    而那是**课表页自己的纯色底** —— 课表「方案二」的默认 patch 会把 `backgroundColor`
  ///    写成 `0xFFE8F1FB`（见 `CourseStorage.loadDisplaySettings` 的 soft 迁移），
  ///    于是任何用户身上 `backgroundColorCache` 都非 null → 纸纹**永远** `visible = false`。
  ///    用户看到的「进 App 闪一下就没」正是：首帧缓存还没加载（判 null，画了一帧），
  ///    异步读完立刻翻成 true 把纸纹摘掉。
  ///
  /// 修复口径（用户原话「修复好后 只保留」）：**纸纹一旦选中就常驻**，
  /// 不与背景色 / 课表背景图互斥 —— 它画在 Stack 最上层，底色是什么都看得见。
  /// 所以现在这个 getter 只为兼容调用点保留，恒 false。
  bool get _hasCustomBackground => false;

  @override
  Widget build(BuildContext context) {
    final visible = widget.kind.isHandDrawn && !_hasCustomBackground;
    // 🔴 结构必须恒定：`child`（Navigator 及其下所有页面）**永远**在
    //    Stack 的第 0 个槽位，纸纹只是在第 1 个槽位出现 / 消失。
    //
    //    如果写成 `if (visible) return Stack(...); return widget.child;`，
    //    用户一选「不启用」或一设自定义背景色，child 就从 Stack 的槽 0
    //    变成根 —— Flutter 会 deactivate 整棵子树再重新 inflate。
    //    Navigator 带 GlobalKey 时同帧能 reparent 回来，但这是**赌**
    //    （本仓 app.dart 里 IndexedStack 那段注释记的正是同一个坑：
    //    结构一变成「有的套了一层、有的没套」，State 就被销毁重建）。
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        widget.child,
        // 纹理层：
        //  · IgnorePointer —— 纸纹绝不能吃掉滚动 / 点击；
        //  · RepaintBoundary —— 它只在 kind / isDark 变化时才重绘，
        //    单独成层后 App 自己滚动时不会带着整屏线重画。
        if (visible)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: HandDrawnBackgroundPainter(
                    kind: widget.kind,
                    isDark: widget.isDark,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 设置页弹窗里的 72 高缩略预览：用的是**同一个 painter**，
/// 所见即所得（不会出现「预览好看、用上去不一样」）。
class HandDrawnBackgroundPreview extends StatelessWidget {
  const HandDrawnBackgroundPreview({
    super.key,
    required this.kind,
    required this.isDark,
  });

  final HandDrawnBackground kind;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    // 预览底色固定「纸白 / 纸黑」：它代表纸张本身，不跟随卡片色，
    // 否则在深色卡片上看到一块灰底，反而看不出这套纸纹长什么样。
    return ColoredBox(
      color: isDark ? AppTheme.surfaceDark : AppTheme.backgroundColor,
      child: CustomPaint(
        painter: HandDrawnBackgroundPainter(kind: kind, isDark: isDark),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// 六套纸纹 + 一笔不画（[HandDrawnBackground.none]）的画笔。
///
/// 全程确定性绘制（不用 `Random()`，用固定种子的线性同余），
/// 所以同一套背景每次画出来完全一样，不会「切个页面纸纹就变了」。
class HandDrawnBackgroundPainter extends CustomPainter {
  HandDrawnBackgroundPainter({required this.kind, required this.isDark});

  final HandDrawnBackground kind;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (!kind.isHandDrawn || size.width <= 0 || size.height <= 0) return;
    switch (kind) {
      case HandDrawnBackground.none:
        return;
      case HandDrawnBackground.ruled:
        _paintRuled(canvas, size);
      case HandDrawnBackground.dots:
        _paintDots(canvas, size);
      case HandDrawnBackground.grid:
        _paintGrid(canvas, size);
      case HandDrawnBackground.diagonal:
        _paintDiagonal(canvas, size);
    }
  }

  /// 明暗两套 alpha（浅色 0.03~0.06 / 深色 0.025~0.05）。
  double _alpha(double light, double dark) => isDark ? dark : light;

  Paint _stroke(double alpha, {double width = 1.2, Color? color}) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..isAntiAlias = true
    ..color = (color ?? (isDark ? const Color(0xFFFFFFFF) : const Color(0xFF000000)))
        .withValues(alpha: alpha);

  // ---------------- 1. 横线笔记纸：淡蓝横线 + 左侧装订边 ----------------
  void _paintRuled(Canvas canvas, Size size) {
    final line = _stroke(
      _alpha(0.055, 0.04),
      width: 1.0,
      color: isDark ? const Color(0xFFBFDBFE) : const Color(0xFF3B82F6),
    );
    const gap = 28.0;
    for (double y = gap; y < size.height; y += gap) {
      // 两段极浅的贝塞尔 → 线不是尺子画出来的直线，有手绘的轻微起伏。
      final path = Path()..moveTo(0, y);
      path.quadraticBezierTo(size.width * 0.34, y + 1.1, size.width * 0.67, y - 0.5);
      path.quadraticBezierTo(size.width * 0.86, y + 0.9, size.width, y + 0.2);
      canvas.drawPath(path, line);
    }
    // 装订边：一道更淡的竖线，读起来才像「本子」而不是「表格」。
    final margin = _stroke(
      _alpha(0.03, 0.025),
      width: 1.0,
      color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFFF87171),
    );
    canvas.drawLine(const Offset(34, 0), Offset(34, size.height), margin);
  }

  // ---------------- 2. 点阵纸 ----------------
  void _paintDots(Canvas canvas, Size size) {
    final dot = _stroke(_alpha(0.06, 0.045), width: 2.0)
      ..style = PaintingStyle.fill;
    const gap = 26.0;
    for (double y = gap * 0.5; y < size.height; y += gap) {
      for (double x = gap * 0.5; x < size.width; x += gap) {
        canvas.drawCircle(Offset(x, y), 1.15, dot);
      }
    }
  }

  // ---------------- 3. 方格本 ----------------
  void _paintGrid(Canvas canvas, Size size) {
    final line = _stroke(_alpha(0.045, 0.035), width: 1.0);
    const gap = 26.0;
    for (double y = gap; y < size.height; y += gap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
    for (double x = gap; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
  }

  // ---------------- 4. 斜纹纸 ----------------
  void _paintDiagonal(Canvas canvas, Size size) {
    final line = _stroke(_alpha(0.03, 0.025), width: 1.0);
    const gap = 18.0;
    for (double x = -size.height; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, 0), Offset(x + size.height, size.height), line);
    }
  }

  /// 🔴 不要写成恒 `true`：纸纹是静态纹理，恒 true 会让它跟着每一帧
  /// （滚动、动画、键盘弹起）整屏重绘 4000+ 个点。
  @override
  bool shouldRepaint(covariant HandDrawnBackgroundPainter oldDelegate) =>
      oldDelegate.kind != kind || oldDelegate.isDark != isDark;
}
