import 'package:flutter/material.dart';

/// 统一的「空状态」与「错误状态」（2026-10-20）。
///
/// 背景：这两个状态原来在 9 个地方各写一份，字号/图标/间距都漂了
/// （新版首页是图标 + 两行字，旧首页是 13px 小字；成绩页和考试页是逐字节复制）。
/// 现在只在这里维护一套视觉。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.hint,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.padding = const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
  });

  final String message;
  final String? hint;
  final IconData icon;
  final Widget? action;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.onSurface;
    return Center(
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: base.withOpacity(0.18)),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: base.withOpacity(0.6),
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: base.withOpacity(0.4),
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误 + 重试。与 [EmptyState] 同一套字号与间距，只有图标与按钮不同。
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    required this.onRetry,
    this.retryLabel = '重试',
    this.icon = Icons.cloud_off_rounded,
    this.padding = const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
  });

  final String message;
  final VoidCallback onRetry;
  final String retryLabel;
  final IconData icon;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.onSurface;
    return Center(
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: base.withOpacity(0.18)),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                color: base.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 14),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: Text(retryLabel),
            ),
          ],
        ),
      ),
    );
  }
}
