import 'package:flutter/material.dart';

import '../services/ui_prefs.dart';
import '../theme/app_theme.dart';

/// 空状态手绘插画（按场景定制）。
///
/// 每一幅都是**手绘线条**小图 + 一点呼吸动效，并且**按场景自身的属性绘制**：
/// 消息是信封、成绩是成绩单、教材是翻开的书、余额是钱包……
/// 不用「一个通用纸箱」糊弄所有场景 —— 那正是「业余感」的来源。
///
/// 统一视觉规范（所有变体共用，改这里即可整体调整）：
///   · 底色晕圈：主色 9% 透明度
///   · 主描边：[ink]，线宽 3.0，圆头圆角
///   · 次描边：[soft]（主色 50%），线宽 2.2
enum EmptyArtVariant {
  /// 通用「暂无数据」：空纸箱 + 一条横线。
  box,

  /// 消息列表为空：一只合上的信封。
  inbox,

  /// 还没订阅任何栏目：一张待添加的订阅卡片（带加号）。
  subscribe,

  /// 搜索无结果：放大镜 + 一圈涟漪。
  search,

  /// 断网 / 加载失败：断掉的云 + 一道斜线。
  offline,

  /// 无考试安排：空日历格。
  calendar,

  /// 无成绩：一张带上升折线的成绩单。
  report,

  /// 无教材：一本翻开的书。
  book,

  /// 无金额 / 无交易记录：一只钱包。
  wallet,
}

/// 空状态手绘图（带轻微呼吸动效）。
class EmptyArt extends StatefulWidget {
  const EmptyArt({
    super.key,
    required this.variant,
    required this.color,
    this.size = 96,
  });

  final EmptyArtVariant variant;
  final Color color;
  final double size;

  @override
  State<EmptyArt> createState() => _EmptyArtState();
}

class _EmptyArtState extends State<EmptyArt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
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
          // 极轻微呼吸：±3% 缩放 + 2% 位移，几乎察觉不到但画面「活」着。
          final t = Curves.easeInOut.transform(_ctrl.value);
          return Transform.translate(
            offset: Offset(0, -2 * t),
            child: Transform.scale(scale: 1 + 0.03 * t, child: child),
          );
        },
        child: CustomPaint(
          painter: _EmptyArtPainter(widget.variant, widget.color),
        ),
      ),
    );
  }
}

class _EmptyArtPainter extends CustomPainter {
  _EmptyArtPainter(this.variant, this.color);

  final EmptyArtVariant variant;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // 底色晕圈（所有变体统一）
    canvas.drawCircle(
      Offset(w / 2, h / 2),
      w * .44,
      Paint()..color = color.withValues(alpha: .09),
    );

    final ink = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final soft = Paint()
      ..color = color.withValues(alpha: .5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (variant) {
      case EmptyArtVariant.box:
        _box(canvas, w, h, ink, soft);
      case EmptyArtVariant.inbox:
        _inbox(canvas, w, h, ink, soft);
      case EmptyArtVariant.subscribe:
        _subscribe(canvas, w, h, ink, soft);
      case EmptyArtVariant.search:
        _search(canvas, w, h, ink, soft);
      case EmptyArtVariant.offline:
        _offline(canvas, w, h, ink, soft);
      case EmptyArtVariant.calendar:
        _calendar(canvas, w, h, ink, soft);
      case EmptyArtVariant.report:
        _report(canvas, w, h, ink, soft);
      case EmptyArtVariant.book:
        _book(canvas, w, h, ink, soft);
      case EmptyArtVariant.wallet:
        _wallet(canvas, w, h, ink, soft);
    }
  }

  /// 通用空纸箱：箱体 + 翻开的盖 + 箱内一条横线。
  void _box(Canvas c, double w, double h, Paint ink, Paint soft) {
    final path = Path()
      ..moveTo(w * .26, h * .40)
      ..lineTo(w * .74, h * .40)
      ..lineTo(w * .70, h * .74)
      ..quadraticBezierTo(w * .50, h * .79, w * .30, h * .74)
      ..close();
    c.drawPath(path, ink);

    final lid = Path()
      ..moveTo(w * .22, h * .40)
      ..quadraticBezierTo(w * .50, h * .20, w * .78, h * .40);
    c.drawPath(lid, ink);

    c.drawLine(
        Offset(w * .38, h * .55), Offset(w * .62, h * .55), soft);
  }

  /// 消息：一只合上的信封（封口 V 形 + 信纸下沿）。
  void _inbox(Canvas c, double w, double h, Paint ink, Paint soft) {
    final body = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * .20, h * .34, w * .80, h * .68),
      Radius.circular(w * .06),
    );
    c.drawRRect(body, ink);

    // 封口：从左上角折到中间，再折回右上角。
    final flap = Path()
      ..moveTo(w * .21, h * .37)
      ..lineTo(w * .50, h * .54)
      ..lineTo(w * .79, h * .37);
    c.drawPath(flap, ink);

    // 信纸下沿（从信封底部微微露出）。
    final sheet = Path()
      ..moveTo(w * .32, h * .62)
      ..quadraticBezierTo(w * .50, h * .58, w * .68, h * .62);
    c.drawPath(sheet, soft);
  }

  /// 未订阅：一张待添加的订阅卡片 + 中间一个加号。
  void _subscribe(Canvas c, double w, double h, Paint ink, Paint soft) {
    final card = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * .22, h * .28, w * .78, h * .72),
      Radius.circular(w * .07),
    );
    c.drawRRect(card, ink);

    // 加号（订阅 = 添加一个源）。
    final cx = w * .50;
    final cy = h * .47;
    final arm = w * .10;
    c.drawLine(Offset(cx - arm, cy), Offset(cx + arm, cy), ink);
    c.drawLine(Offset(cx, cy - arm), Offset(cx, cy + arm), ink);

    // 卡片底部的说明线。
    c.drawLine(
        Offset(w * .36, h * .63), Offset(w * .64, h * .63), soft);
  }

  /// 放大镜：镜圈 + 把手 + 一道涟漪。
  void _search(Canvas c, double w, double h, Paint ink, Paint soft) {
    c.drawCircle(Offset(w * .44, h * .44), w * .20, ink);
    c.drawLine(
        Offset(w * .58, h * .58), Offset(w * .74, h * .74), ink);
    c.drawArc(
      Rect.fromCircle(center: Offset(w * .44, h * .44), radius: w * .29),
      -0.6,
      1.5,
      false,
      soft,
    );
  }

  /// 断网：云 + 一道斜线。
  void _offline(Canvas c, double w, double h, Paint ink, Paint soft) {
    final cloud = Path()
      ..moveTo(w * .28, h * .58)
      ..quadraticBezierTo(w * .22, h * .44, w * .36, h * .44)
      ..quadraticBezierTo(w * .40, h * .30, w * .56, h * .36)
      ..quadraticBezierTo(w * .70, h * .38, w * .70, h * .52)
      ..quadraticBezierTo(w * .80, h * .54, w * .76, h * .62)
      ..close();
    c.drawPath(cloud, ink);
    c.drawLine(Offset(w * .24, h * .74), Offset(w * .76, h * .30), soft);
  }

  /// 空日历：外框 + 两个挂耳 + 几个点。
  void _calendar(Canvas c, double w, double h, Paint ink, Paint soft) {
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * .26, h * .30, w * .74, h * .74),
      Radius.circular(w * .06),
    );
    c.drawRRect(rect, ink);
    c.drawLine(Offset(w * .26, h * .44), Offset(w * .74, h * .44), ink);
    c.drawLine(Offset(w * .38, h * .22), Offset(w * .38, h * .36), ink);
    c.drawLine(Offset(w * .62, h * .22), Offset(w * .62, h * .36), ink);
    for (final p in [
      Offset(w * .38, h * .56),
      Offset(w * .50, h * .56),
      Offset(w * .62, h * .56),
      Offset(w * .38, h * .66),
    ]) {
      c.drawCircle(p, 2.2, soft);
    }
  }

  /// 成绩单：一张纸（左上折角）+ 一条上升的折线 + 端点。
  void _report(Canvas c, double w, double h, Paint ink, Paint soft) {
    final sheet = Path()
      ..moveTo(w * .28, h * .22)
      ..lineTo(w * .60, h * .22)
      ..lineTo(w * .74, h * .36)
      ..lineTo(w * .74, h * .78)
      ..lineTo(w * .28, h * .78)
      ..close();
    c.drawPath(sheet, ink);

    // 右上折角。
    final fold = Path()
      ..moveTo(w * .60, h * .22)
      ..lineTo(w * .60, h * .36)
      ..lineTo(w * .74, h * .36);
    c.drawPath(fold, soft);

    // 成绩曲线：从左下升到右上。
    final line = Path()
      ..moveTo(w * .36, h * .64)
      ..lineTo(w * .46, h * .54)
      ..lineTo(w * .54, h * .59)
      ..lineTo(w * .66, h * .44);
    c.drawPath(line, ink);
    c.drawCircle(Offset(w * .66, h * .44), 2.6, ink);
  }

  /// 教材：一本翻开的书（两页 + 书脊 + 页面横线）。
  void _book(Canvas c, double w, double h, Paint ink, Paint soft) {
    final left = Path()
      ..moveTo(w * .50, h * .34)
      ..quadraticBezierTo(w * .36, h * .26, w * .18, h * .32)
      ..lineTo(w * .18, h * .68)
      ..quadraticBezierTo(w * .36, h * .62, w * .50, h * .70)
      ..close();
    final right = Path()
      ..moveTo(w * .50, h * .34)
      ..quadraticBezierTo(w * .64, h * .26, w * .82, h * .32)
      ..lineTo(w * .82, h * .68)
      ..quadraticBezierTo(w * .64, h * .62, w * .50, h * .70)
      ..close();
    c.drawPath(left, ink);
    c.drawPath(right, ink);

    // 书脊。
    c.drawLine(Offset(w * .50, h * .34), Offset(w * .50, h * .70), ink);

    // 两页的正文横线。
    c.drawLine(Offset(w * .26, h * .44), Offset(w * .43, h * .42), soft);
    c.drawLine(Offset(w * .26, h * .53), Offset(w * .43, h * .51), soft);
    c.drawLine(Offset(w * .57, h * .42), Offset(w * .74, h * .44), soft);
    c.drawLine(Offset(w * .57, h * .51), Offset(w * .74, h * .53), soft);
  }

  /// 钱包：袋身 + 翻盖 + 一枚硬币。
  void _wallet(Canvas c, double w, double h, Paint ink, Paint soft) {
    final body = RRect.fromRectAndRadius(
      Rect.fromLTRB(w * .26, h * .34, w * .74, h * .70),
      Radius.circular(w * .08),
    );
    c.drawRRect(body, ink);
    c.drawArc(
      Rect.fromLTWH(w * .26, h * .34, w * .48, h * .36),
      -1.6,
      2.2,
      false,
      ink,
    );
    c.drawCircle(Offset(w * .64, h * .52), w * .05, soft);
  }

  @override
  bool shouldRepaint(covariant _EmptyArtPainter old) =>
      old.variant != variant || old.color != color;
}

/// 空状态容器：手绘图 + 主文案 + 副文案 + 可选动作。
///
/// 全 App 的空状态都走它，保证「空」的观感一致。
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.variant,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  final EmptyArtVariant variant;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 紧凑模式：用于卡片内部（插画更小、间距更紧）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // 插画用次级文字色：够淡（不抢正文），但要看得清。
    final artColor = context.textTertiary;

    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 24,
          vertical: compact ? 16 : 28,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            EmptyArt(
              variant: variant,
              color: artColor,
              size: compact ? 64 : 96,
            ),
            SizedBox(height: compact ? 10 : 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w600,
                color: context.textSecondary,
              ),
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  height: 1.5,
                  color: context.textTertiary,
                ),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.textSecondary,
                  side: BorderSide(color: context.borderColor),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  minimumSize: const Size(0, 36),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm)),
                ),
                child: Text(actionLabel!,
                    style: const TextStyle(fontSize: AppTheme.fontSmall)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
