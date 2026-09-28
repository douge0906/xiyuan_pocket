import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/todo.dart';
import '../../theme/app_theme.dart';

// 首页的两个独立展示组件（v1.0.0 从 home_page.dart 剥离）。
//
// 这两个类原本就是自洽的独立 widget —— 依赖只经构造函数传入，
// 无任何页面状态耦合，因此是**纯搬迁 + 私有名改公开名**（渲染逻辑逐行未改）。

class HomeClockWidget extends StatefulWidget {
  final bool isDark;
  const HomeClockWidget({super.key, required this.isDark});

  @override
  State<HomeClockWidget> createState() => HomeClockWidgetState();
}

class HomeClockWidgetState extends State<HomeClockWidget> {
  late DateTime _now;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final time = '${_pad(_now.hour)}:${_pad(_now.minute)}:${_pad(_now.second)}';
    return Row(
      children: [
        Icon(Icons.schedule_rounded, size: 18, color: context.textTertiary),
        const SizedBox(width: 6),
        Text(
          time,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: widget.isDark ? Colors.white70 : const Color(0xFF1F2937),
            letterSpacing: 1.5,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class TodoTimelineItem extends StatelessWidget {
  final Todo todo;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  const TodoTimelineItem({
    super.key,
    required this.todo,
    required this.isFirst,
    required this.isLast,
    required this.onToggle,
    required this.onDelete,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final time = todo.reminderTime != null
        ? '${todo.reminderTime!.hour.toString().padLeft(2, '0')}:${todo.reminderTime!.minute.toString().padLeft(2, '0')}'
        : '全天';

    final isHighlighted = !todo.completed && todo.reminderTime != null &&
        todo.reminderTime!.isAfter(DateTime.now());

    final card = GestureDetector(
      onTap: onToggle,
      onLongPress: onEdit,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isHighlighted
              ? const Color(0xFF1F2937)
              : (todo.completed
                  ? (isDark ? const Color(0xFF161616) : const Color(0xFFF3F4F6))
                  : (context.surfaceColor)),
          borderRadius: BorderRadius.circular(20),
          boxShadow: AppTheme.cardShadow,
          // v2.4.3：补灰线边框，与「服务」页卡片观感一致
          // （原来首页卡片只有阴影、服务页有细灰线，切页时"分量"不同）。
          // 高亮态本身就是深色实块，不加线以免显脏。
          border: isHighlighted
              ? null
              : Border.all(color: context.borderColor, width: 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    time,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: isHighlighted ? Colors.white70 : (context.textTertiary),
                    ),
                  ),
                  const SizedBox(height: 4),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 300),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isHighlighted ? Colors.white : (context.textPrimary),
                      decoration: todo.completed ? TextDecoration.lineThrough : TextDecoration.none,
                    ),
                    child: Text(todo.title),
                  ),
                  if (todo.description?.isNotEmpty ?? false)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 300),
                        style: TextStyle(
                          fontSize: 12.5,
                          color: isHighlighted ? Colors.white70 : (context.textSecondary),
                          decoration: todo.completed ? TextDecoration.lineThrough : TextDecoration.none,
                        ),
                        child: Text(todo.description!),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
// v2.1.0 勾选框重设计：未完成 → 描边圆环（空心，暗示待勾选）；
            // 完成 → 实心圆 + 白勾；高亮项用主题色描边。切换带弹性放大动画。
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              transitionBuilder: (child, anim) {
                final scale = Tween<double>(begin: 0.6, end: 1.0).animate(
                    CurvedAnimation(parent: anim, curve: Curves.easeOutBack));
                return ScaleTransition(scale: scale, child: child);
              },
              child: Container(
                key: ValueKey(todo.completed),
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: todo.completed ? const Color(0xFF10B981) : Colors.transparent,
                  shape: BoxShape.circle,
                  border: todo.completed
                      ? null
                      : Border.all(
                          color: isHighlighted
                              ? AppTheme.primaryColor
                              : (isDark ? Colors.grey.shade600 : const Color(0xFFD1D5DB)),
                          width: isHighlighted ? 2 : 1.6,
                        ),
                ),
                child: todo.completed
                    ? const Icon(Icons.check_rounded, color: Colors.white, size: 17)
                    : null,
              ),
            ),
          ],
        ),
      ),
    );

    final row = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 40,
            child: Column(
              children: [
                if (!isFirst)
                  Expanded(
                    child: Container(width: 2, color: context.borderColor),
                  )
                else
                  const Expanded(child: SizedBox()),
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: todo.completed ? const Color(0xFF10B981) : (isHighlighted ? AppTheme.primaryColor : (isDark ? Colors.grey.shade600 : Colors.grey.shade400)),
                    shape: BoxShape.circle,
                    border: Border.all(color: isDark ? const Color(0xFF121212) : Colors.white, width: 2),
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(width: 2, color: context.borderColor),
                  )
                else
                  const Expanded(child: SizedBox()),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: card),
        ],
      ),
    );

    // 整行滑动删除：左滑露出全宽圆角红色面板 + 「删除」文字，滑动流畅统一。
    // 删除由父级同步从列表移除，避免残留组件报错。
    return Dismissible(
      key: Key(todo.id),
      direction: DismissDirection.endToStart,
      movementDuration: const Duration(milliseconds: 240),
      resizeDuration: const Duration(milliseconds: 240),
      background: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFEF4444),
            borderRadius: BorderRadius.circular(20),
          ),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 24),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.delete_outline_rounded, color: Colors.white, size: 24),
              SizedBox(width: 6),
              Text('删除', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
      onDismissed: (_) => onDelete(),
      child: row,
    );
  }
}
