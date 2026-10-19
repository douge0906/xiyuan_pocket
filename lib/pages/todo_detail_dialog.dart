import 'package:flutter/material.dart';

import '../models/todo.dart';
import '../theme/app_theme.dart';

/// 待办详情弹窗（2026-10-17）。
///
/// 用户要求：「点击任务可弹出新增时填写的内容」——
/// 所以这里原样展示新增时填的 **名称 / 时间 / 内容**，没有填的就不显示。
/// 居中盒子 + 右上角 ×（项目 UI 铁律）。
///
/// 返回动作字符串：`'toggle'` / `'delete'`；直接关闭返回 null。
class TodoDetailDialog extends StatelessWidget {
  const TodoDetailDialog({super.key, required this.todo});

  final Todo todo;

  static Future<String?> show(BuildContext context, Todo todo) {
    return showDialog<String>(
      context: context,
      builder: (_) => TodoDetailDialog(todo: todo),
    );
  }

  String get _whenLabel {
    final d = todo.date;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
    final dayLabel = switch (diff) {
      0 => '今天',
      1 => '明天',
      -1 => '昨天',
      _ => (diff < 0 ? '${-diff} 天前' : '${d.month}月${d.day}日'),
    };
    if (todo.dueAt == null) return dayLabel;
    final h = todo.dueAt!.hour.toString().padLeft(2, '0');
    final m = todo.dueAt!.minute.toString().padLeft(2, '0');
    return '$dayLabel $h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = context.surfaceColor;
    final faint = isDark ? const Color(0xFF8B8B8B) : const Color(0xFF9CA3AF);
    final labelColor = isDark ? const Color(0xFFA1A1AA) : const Color(0xFF6B7280);

    return AlertDialog(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 14, 8, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
      actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      title: Row(
        children: [
          Expanded(
            child: Text(
              todo.title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                decoration: todo.completed ? TextDecoration.lineThrough : null,
                color: todo.completed ? faint : null,
              ),
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: '关闭',
          ),
        ],
      ),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.schedule_rounded, size: 15, color: faint),
                const SizedBox(width: 7),
                Text(_whenLabel,
                    style: TextStyle(fontSize: 13.5, color: labelColor)),
                if (todo.completed) ...[
                  const SizedBox(width: 10),
                  Text('已完成',
                      style: TextStyle(fontSize: 12, color: faint)),
                ],
              ],
            ),
            if ((todo.description ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF1C1C1E)
                      : const Color(0xFFF7F8FA),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  todo.description!.trim(),
                  style: const TextStyle(fontSize: 13.5, height: 1.6),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop('delete'),
          child: const Text('删除',
              style: TextStyle(fontSize: 14, color: Color(0xFFB91C1C))),
        ),
        const Spacer(),
        TextButton(
          onPressed: () => Navigator.of(context).pop('toggle'),
          child: Text(
            todo.completed ? '标记未完成' : '标记完成',
            style: TextStyle(fontSize: 14, color: labelColor),
          ),
        ),
      ],
    );
  }
}
