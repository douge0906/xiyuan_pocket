import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 首页周次条：上面星期，下面日期；选中块用滑动指示器。
/// 支持点按、按住横向拖动；拖到左右边缘自动切上一周/下一周。
class HomeWeekStrip extends StatefulWidget {
  const HomeWeekStrip({
    super.key,
    required this.selected,
    required this.onSelected,
    this.onPreviousWeek,
    this.onNextWeek,
  });

  final DateTime selected;
  final ValueChanged<DateTime> onSelected;
  final VoidCallback? onPreviousWeek;
  final VoidCallback? onNextWeek;

  @override
  State<HomeWeekStrip> createState() => _HomeWeekStripState();
}

class _HomeWeekStripState extends State<HomeWeekStrip> {
  static const _weekLabels = ['一', '二', '三', '四', '五', '六', '日'];
  static const double _arrowW = 20;
  bool _edgeTriggered = false;

  /// 拖动过程中记录当前指到的星期，避免同一格反复触发 onSelected
  /// （每像素都发一次 → 父级反复重载数据 → 滑动卡顿）。
  int? _dragIndex;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = DateTime(
        widget.selected.year, widget.selected.month, widget.selected.day);
    final monday = base.subtract(Duration(days: base.weekday - 1));
    final index = base.weekday - 1;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final ink = isDark ? const Color(0xFFF3F4F6) : const Color(0xFF111827);
    final sub = Theme.of(context).textTheme.bodySmall?.color ??
        const Color(0xFF9CA3AF);

    return LayoutBuilder(
      builder: (_, box) {
        final cell = (box.maxWidth - _arrowW * 2) / 7;
        void pick(double dx, {bool fromDrag = false}) {
          if (dx < _arrowW && !_edgeTriggered) {
            _edgeTriggered = true;
            widget.onPreviousWeek?.call();
            return;
          }
          if (dx > box.maxWidth - _arrowW && !_edgeTriggered) {
            _edgeTriggered = true;
            widget.onNextWeek?.call();
            return;
          }
          final local = dx - _arrowW;
          final i = (local / cell).floor().clamp(0, 6);
          if (fromDrag) {
            if (_dragIndex == i) return;
            _dragIndex = i;
          }
          widget.onSelected(monday.add(Duration(days: i)));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 点击在**抬起**时提交：按下即切会让「按住拖动」的第一格被误判成点击。
          onTapUp: (d) => pick(d.localPosition.dx),
          onHorizontalDragStart: (d) {
            _edgeTriggered = false;
            _dragIndex = null;
            pick(d.localPosition.dx, fromDrag: true);
          },
          onHorizontalDragUpdate: (d) =>
              pick(d.localPosition.dx, fromDrag: true),
          onHorizontalDragEnd: (_) {
            _edgeTriggered = false;
            _dragIndex = null;
          },
          onHorizontalDragCancel: () {
            _edgeTriggered = false;
            _dragIndex = null;
          },
          child: SizedBox(
            height: 52,
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 230),
                  curve: Curves.easeOutCubic,
                  left: _arrowW + index * cell + 3,
                  top: 2,
                  width: cell - 6,
                  height: 48,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: ink,
                      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? .18 : .12),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: _arrowW,
                  right: _arrowW,
                  top: 0,
                  bottom: 0,
                  child: Row(
                    children: List.generate(7, (i) {
                      final day = monday.add(Duration(days: i));
                      final active = i == index;
                      final isToday = day == today;
                      return Expanded(
                        child: SizedBox(
                          height: 52,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _weekLabels[i],
                                style: TextStyle(
                                  fontSize: AppTheme.fontCaption,
                                  fontWeight: FontWeight.w600,
                                  color: active
                                      ? (isDark
                                          ? const Color(0xFF111827)
                                          : Colors.white70)
                                      : sub,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${day.day}',
                                style: TextStyle(
                                  fontSize: AppTheme.fontTitle,
                                  fontWeight: active
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  height: 1.05,
                                  color: active
                                      ? (isDark
                                          ? const Color(0xFF111827)
                                          : Colors.white)
                                      : (isDark
                                          ? const Color(0xFFE5E7EB)
                                          : const Color(0xFF374151)),
                                ),
                              ),
                              if (isToday)
                                Container(
                                  width: 3,
                                  height: 3,
                                  margin: const EdgeInsets.only(top: 3),
                                  decoration: BoxDecoration(
                                    color: active
                                        ? (isDark
                                            ? const Color(0xFF111827)
                                            : Colors.white)
                                        : const Color(0xFF3B82F6),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ),
                ),
                _arrow(
                  left: true,
                  enabled: widget.onPreviousWeek != null,
                  color: sub,
                ),
                _arrow(
                  left: false,
                  enabled: widget.onNextWeek != null,
                  color: sub,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _arrow({
    required bool left,
    required bool enabled,
    required Color color,
  }) {
    // 点击交给父级 GestureDetector 统一处理：点在左右 20dp 内就切周，
    // 避免箭头和日期各触发一次、跳两周。
    return Positioned(
      left: left ? 0 : null,
      right: left ? null : 0,
      top: 0,
      bottom: 0,
      width: _arrowW,
      child: IgnorePointer(
        child: Icon(
          left ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
          size: 17,
          color: color.withValues(alpha: enabled ? .45 : .15),
        ),
      ),
    );
  }
}
