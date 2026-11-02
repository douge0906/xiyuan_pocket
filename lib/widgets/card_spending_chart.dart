import 'package:flutter/material.dart';

import '../services/dorm_service.dart';
import '../theme/app_theme.dart';

/// 一卡通「每日消费」趋势（最近 7 天，柱状）。
///
/// 数据来自已加载的交易明细（分页），聚合口径：**只算支出**，按自然日求和。
/// 明细不够两天时整块不显示 —— 宁可不画，也不画一张只有一根柱子的"趋势"。
class CardSpendingChart extends StatelessWidget {
  const CardSpendingChart({super.key, required this.items});

  final List<CardTxn> items;

  /// 从平台时间串里取日期（兼容 `2026-10-26 12:34` 与 `20261026...` 两种写法）。
  static DateTime? _dayOf(String raw) {
    final m = RegExp(r'(\d{4})-?(\d{2})-?(\d{2})').firstMatch(raw);
    if (m == null) return null;
    return DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    );
  }

  /// 最近 [days] 天每天支出（元），按日期升序。
  List<({DateTime day, double spent})> _daily(int days) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final buckets = <DateTime, double>{};
    for (var i = days - 1; i >= 0; i--) {
      buckets[today.subtract(Duration(days: i))] = 0;
    }
    for (final t in items) {
      if (t.isIncome) continue; // 只统计消费
      final d = _dayOf(t.time);
      if (d == null) continue;
      final key = DateTime(d.year, d.month, d.day);
      if (!buckets.containsKey(key)) continue; // 超出窗口
      buckets[key] = buckets[key]! + t.amountYuan;
    }
    final list = buckets.entries
        .map((e) => (day: e.key, spent: e.value))
        .toList()
      ..sort((a, b) => a.day.compareTo(b.day));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final data = _daily(7);
    final spentDays = data.where((e) => e.spent > 0).length;
    // 至少两天有消费才画，否则说明不了趋势
    if (spentDays < 2) return const SizedBox.shrink();

    final total = data.fold<double>(0, (a, e) => a + e.spent);
    final maxV = data.map((e) => e.spent).reduce((a, b) => a > b ? a : b);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('消费趋势',
                  style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary)),
              const Spacer(),
              Text('近 7 天 共 ¥${total.toStringAsFixed(2)}',
                  style:
                      TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 76,
            width: double.infinity,
            child: CustomPaint(
              painter: _SpendingBarPainter(
                values: [for (final e in data) e.spent],
                barColor: AppTheme.primaryColor,
                emptyColor: context.borderColor,
                labelColor: context.textTertiary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(_md(data.first.day),
                  style:
                      TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary)),
              const Spacer(),
              Text('峰值 ¥${maxV.toStringAsFixed(2)}',
                  style:
                      TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary)),
              const Spacer(),
              Text(_md(data.last.day),
                  style:
                      TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary)),
            ],
          ),
        ],
      ),
    );
  }

  static String _md(DateTime d) => '${d.month}/${d.day}';
}

/// 柱状图：无网格、无坐标轴，只有柱子和极淡的基线（简约）。
class _SpendingBarPainter extends CustomPainter {
  _SpendingBarPainter({
    required this.values,
    required this.barColor,
    required this.emptyColor,
    required this.labelColor,
  });

  final List<double> values;
  final Color barColor;
  final Color emptyColor;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final slot = size.width / values.length;
    final barW = slot * 0.46;
    final baseY = size.height - 1;

    // 基线：一条 1px 极淡的线，给柱子一个落脚点
    canvas.drawLine(
      Offset(0, baseY),
      Offset(size.width, baseY),
      Paint()
        ..color = emptyColor
        ..strokeWidth = 1,
    );

    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      final cx = slot * i + slot / 2;
      if (v <= 0) {
        // 没消费：一个 2px 小圆点，比空着更能说明"这天是 0"
        canvas.drawCircle(
          Offset(cx, baseY - 1),
          1,
          Paint()..color = emptyColor,
        );
        continue;
      }
      final h = maxV <= 0 ? 0.0 : (v / maxV) * (size.height - 14);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - barW / 2, baseY - h, barW, h),
        const Radius.circular(2.5),
      );
      canvas.drawRRect(rect, Paint()..color = barColor);

      // 柱顶金额：≥10 取整、其余留一位小数；柱子太矮时不画，免得糊成一团
      // 金额尽量完整显示：字号压到 8，超宽时去掉小数位再试
      var label = v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
      var tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(fontSize: 8, color: labelColor, height: 1),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      if (tp.width > slot - 1 && v >= 10) {
        label = v.toStringAsFixed(0);
      } else if (tp.width > slot - 1) {
        label = v.toStringAsFixed(1);
      }
      tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(fontSize: 8, color: labelColor, height: 1),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, baseY - h - tp.height - 3));
    }
  }

  @override
  bool shouldRepaint(covariant _SpendingBarPainter old) =>
      old.values != values ||
      old.barColor != barColor ||
      old.emptyColor != emptyColor ||
      old.labelColor != labelColor;
}
