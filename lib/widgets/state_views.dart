import 'package:flutter/material.dart';

import 'empty_state_art.dart';
import '../theme/app_theme.dart';

/// 统一的「空状态」与「错误状态」（2026-10-20 建立，2026-10-30 升级为手绘）。
///
/// 背景：这两个状态原来在 9 个地方各写一份，字号/图标/间距都漂了
/// （新版首页是图标 + 两行字，旧首页是 13px 小字；成绩页和考试页是逐字节复制）。
/// 现在只在这里维护一套视觉。
///
/// 2026-10-30：图标换成**手绘线条插画**（[EmptyArt]），
/// 空状态不再是冷冰冰的 Material 图标，而是一枚会轻轻呼吸的手绘小图。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.hint,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.padding = const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
    this.artVariant = EmptyArtVariant.box,
  });

  final String message;
  final String? hint;
  final IconData icon;

  /// 手绘插画变体（默认「空纸箱」）。
  final EmptyArtVariant artVariant;

  final Widget? action;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = Theme.of(context).colorScheme.onSurface;
    final artColor = isDark ? const Color(0xFF7A7A7A) : const Color(0xFFB4BAC4);
    return Center(
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            EmptyArt(variant: artVariant, color: artColor, size: 84),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w600,
                color: base.withValues(alpha: 0.6),
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  height: 1.6,
                  color: base.withValues(alpha: 0.4),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = Theme.of(context).colorScheme.onSurface;
    final artColor = isDark ? const Color(0xFF7A7A7A) : const Color(0xFFB4BAC4);
    return Center(
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 错误态用「断网云 + 斜线」的手绘图。
            EmptyArt(variant: EmptyArtVariant.offline, color: artColor, size: 84),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                height: 1.6,
                color: base.withValues(alpha: 0.6),
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
