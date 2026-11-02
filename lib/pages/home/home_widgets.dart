import 'package:flutter/material.dart';
import '../../models/todo.dart';
import '../../theme/app_theme.dart';
import '../../widgets/pressable.dart';

// 首页的两个独立展示组件（v1.0.0 从 home_page.dart 剥离）。
//
// 这两个类原本就是自洽的独立 widget —— 依赖只经构造函数传入，
// 无任何页面状态耦合，因此是**纯搬迁 + 私有名改公开名**（渲染逻辑逐行未改）。

class TodoTimelineItem extends StatelessWidget {
  final Todo todo;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final bool compact;

  /// 这条待办**所属的那一天**。
  ///
  /// 🔴 必须传：完成态是**按天归属**的（[Todo.completedDay]），
  ///    读裸 `todo.completed` 会把「另一天的完成」显示到今天。
  final DateTime date;

  const TodoTimelineItem({
    super.key,
    required this.todo,
    required this.date,
    required this.isFirst,
    required this.isLast,
    required this.onToggle,
    required this.onDelete,
    required this.onEdit,
    this.compact = false,
  });

  /// 这条待办在 [date] 这一天是否已完成（按天判定）。
  bool get _done => todo.isDoneOn(date);

  Widget _compactCard(
      BuildContext context, String time, Color priorityColor) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = todo.title.startsWith('【课程】')
        ? todo.title.substring('【课程】'.length)
        : todo.title;
    return Pressable(
      onTap: onToggle,
      onLongPress: onEdit,
      haptic: true,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          boxShadow: AppTheme.cardShadow,
          border: Border.all(color: context.borderColor),
        ),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 18,
              margin: const EdgeInsets.only(right: 9),
              decoration: BoxDecoration(
                color: priorityColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Text(time,
                style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    color: context.textTertiary,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  color: isDark
                      ? const Color(0xFFD4D4D8)
                      : const Color(0xFF3F3F46),
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.check_rounded,
                color: Color(0xFF10B981), size: 18),
          ],
        ),
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 🔴 时间来源：**reminderTime ?? dueAt**。
    //    原来只读 reminderTime → 用新版弹窗新增的待办（时间写在 dueAt）
    //    一律显示成「全天」，用户会以为「设了几点都没生效」。
    //    dueAt 是「这天的什么时候」，reminderTime 是「提醒时刻」，
    //    展示上用哪个都该显示同一个时刻，所以取「有提醒优先」。
    final shownTime = todo.reminderTime ?? todo.dueAt;
    final time = shownTime != null
        ? '${shownTime.hour.toString().padLeft(2, '0')}:${shownTime.minute.toString().padLeft(2, '0')}'
        : '全天';

    final now = DateTime.now();
    final isToday = todo.date.year == now.year &&
        todo.date.month == now.month &&
        todo.date.day == now.day;
    // 「即将到期」的判断用同一个时刻来源（与上方显示保持一致）。
    final isHighlighted = !_done && isToday && shownTime != null && shownTime.isAfter(now);
    final priorityColor = switch (todo.priority) {
      2 => const Color(0xFFDC2626),
      1 => const Color(0xFFF59E0B),
      _ => isDark ? const Color(0xFF4B5563) : const Color(0xFFD1D5DB),
    };

    final card = compact
        ? _compactCard(context, time, priorityColor)
        : Pressable(
            onTap: onToggle,
            onLongPress: onEdit,
            haptic: true,
            child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(minHeight: 74),
        decoration: BoxDecoration(
          color: isHighlighted
              ? AppTheme.textPrimaryLight
              : (_done
                  ? (isDark ? const Color(0xFF161616) : const Color(0xFFF3F4F6))
                  : (context.surfaceColor)),
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
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
            Container(
              width: 4,
              height: 38,
              margin: const EdgeInsets.only(right: 9, top: 2),
              decoration: BoxDecoration(
                color: priorityColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    time,
                    style: TextStyle(
                      fontSize: AppTheme.fontSmall,
                      fontWeight: FontWeight.w600,
                      // 等宽数字：09:00 → 10:00 宽度不变，列表不会左右抖。
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: isHighlighted ? Colors.white70 : (context.textTertiary),
                    ),
                  ),
                  const SizedBox(height: 4),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 300),
                    style: TextStyle(
                      fontSize: AppTheme.fontTitle,
                      fontWeight: FontWeight.bold,
                      color: isHighlighted ? Colors.white : (context.textPrimary),
                      decoration: TextDecoration.none,
                    ),
                    child: Text(todo.title),
                  ),
                  if (todo.description?.isNotEmpty ?? false)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 300),
                        style: TextStyle(
                          fontSize: AppTheme.fontSmall,
                          color: isHighlighted ? Colors.white70 : (context.textSecondary),
                          decoration: TextDecoration.none,
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
                key: ValueKey(_done),
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: _done ? const Color(0xFF10B981) : Colors.transparent,
                  shape: BoxShape.circle,
                  border: _done
                      ? null
                      : Border.all(
                          color: isHighlighted
                              ? AppTheme.primaryColor
                              : (isDark ? Colors.grey.shade600 : const Color(0xFFD1D5DB)),
                          width: isHighlighted ? 2 : 1.6,
                        ),
                ),
                child: _done
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
                    color: _done ? const Color(0xFF10B981) : (isHighlighted ? AppTheme.primaryColor : (isDark ? Colors.grey.shade600 : Colors.grey.shade400)),
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
      direction: DismissDirection.horizontal,
      movementDuration: const Duration(milliseconds: 240),
      // 列表的收起动画交给 HomeTodoList（AnimatedList），避免双重 resize。
      resizeDuration: null,
      // 右滑完成：先切换完成态，再让 HomeTodoList 把它移出未完成列表。
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          onToggle();
          return false;
        }
        return true;
      },
      background: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF10B981),
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          ),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 24),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_rounded, color: Colors.white, size: 24),
              SizedBox(width: 6),
              Text('完成',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
      secondaryBackground: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFEF4444),
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          ),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 24),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.delete_outline_rounded,
                  color: Colors.white, size: 24),
              SizedBox(width: 6),
              Text('删除',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
      onDismissed: (_) => onDelete(),
      child: row,
    );
  }
}
