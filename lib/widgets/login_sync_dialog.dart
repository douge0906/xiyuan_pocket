import 'dart:async';

import 'package:flutter/material.dart';

import '../services/login_sync_progress.dart';
import '../theme/app_theme.dart';

/// 登录成功后的「自动同步」进度对话框（v1.0.9，2026-11-28 重做外观）。
///
/// 用户原话（v1.0.9）：「由于首次登录会触发各项自动功能，课程表突然弹出显得突兀，
/// 遂设计一个进度条提示 登录成功 自动同步成绩 中.... 同步成功。
/// 自动同步...中 ...同步成功 一行一个功能」
///
/// 2026-11-28 同学的反馈：「点击登录后弹出的那个页面速度过快，没有加载动画，
/// 并且过丑」。所以这一版只改两件事，不改任何同步语义：
/// · **慢下来**：一进来至少留 1.7 秒给用户看清「正在做什么」，全部完成后
///   再停 1.6 秒才自动关（原来 700 毫秒就关了，跟闪一下没区别）；
/// · **好看一点**：成功图标做成实心圆徽，步骤行改成一张张浅色卡片，
///   正在跑的那一步有转圈，完成的那一步的勾是「长出来」的；
/// · 顺手修一个老坑：自动关窗前先确认这个对话框真的是栈顶，
///   否则会把调用方随后弹出的其它对话框一起关掉。
class LoginSyncDialog extends StatefulWidget {
  const LoginSyncDialog({super.key});

  /// 一进来至少显示这么久，再快也要让用户看清标题。
  static const Duration minVisible = Duration(milliseconds: 1700);

  /// 全部完成后停留多久再自动关。
  static const Duration lingerAfterDone = Duration(milliseconds: 1600);

  /// 弹出并等待关闭。**不等待同步结束** —— 同步由调用方在后台跑完。
  static Future<void> show(BuildContext context) {
    LoginSyncProgress.reset();
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const LoginSyncDialog(),
    );
  }

  @override
  State<LoginSyncDialog> createState() => _LoginSyncDialogState();
}

class _LoginSyncDialogState extends State<LoginSyncDialog> {
  Timer? _autoClose;
  late final DateTime _shownAt;

  @override
  void initState() {
    super.initState();
    _shownAt = DateTime.now();
    LoginSyncProgress.notifier.addListener(_onChanged);
  }

  @override
  void dispose() {
    _autoClose?.cancel();
    LoginSyncProgress.notifier.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    final items = LoginSyncProgress.notifier.value;
    final finished = items.every((e) =>
        e.status != LoginSyncStatus.pending &&
        e.status != LoginSyncStatus.running);
    if (!finished) {
      _autoClose?.cancel();
      _autoClose = null;
      return;
    }
    if (_autoClose != null) return;
    // 剩下的「最短可见时间」+ 完成后的停留时间。
    final elapsed = DateTime.now().difference(_shownAt);
    var remain = LoginSyncDialog.lingerAfterDone;
    if (elapsed < LoginSyncDialog.minVisible) {
      remain += LoginSyncDialog.minVisible - elapsed;
    }
    _autoClose = Timer(remain, _closeIfOnTop);
  }

  /// 只关自己。之前直接 `nav.pop()`，会把调用方随后弹出的对话框（比如
  /// 宿舍号选择框）一起关掉。
  void _closeIfOnTop() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.cardColor,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(color: AppTheme.cardStrokeColor(context.isDark)),
      ),
      contentPadding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
      content: ValueListenableBuilder<List<LoginSyncItem>>(
        valueListenable: LoginSyncProgress.notifier,
        builder: (context, items, _) {
          final total = items.length;
          final done = items
              .where((e) => e.status == LoginSyncStatus.done)
              .length;
          final finished = items.every((e) =>
              e.status != LoginSyncStatus.pending &&
              e.status != LoginSyncStatus.running);
          return TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.94, end: 1),
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            builder: (context, scale, child) => Transform.scale(
              scale: scale,
              child: Opacity(opacity: scale.clamp(0.0, 1.0), child: child),
            ),
            child: SizedBox(
              width: (MediaQuery.of(context).size.width - 140)
                  .clamp(240.0, 320.0)
                  .toDouble(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(context, finished: finished, done: done, total: total),
                  const SizedBox(height: 16),
                  _progress(context, done: done, total: total),
                  const SizedBox(height: 16),
                  // 步骤数会随功能增长（现在是 7 步），备注也可能长到一行半
                  // （「教务未配置培养方案」）。给行区域一个上限、超出就滚。
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 258),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < items.length; i++) ...[
                            if (i > 0) const SizedBox(height: 7),
                            _row(context, items[i]),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: finished
                        ? FilledButton(
                            onPressed: _closeIfOnTop,
                            style: FilledButton.styleFrom(
                              backgroundColor: AppTheme.primaryColor,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(AppTheme.radiusMd),
                              ),
                            ),
                            child: const Text('完成',
                                style: TextStyle(
                                    fontSize: AppTheme.fontBody,
                                    fontWeight: FontWeight.w600)),
                          )
                        : TextButton(
                            onPressed: _closeIfOnTop,
                            child: Text(
                              '让它在后台继续',
                              style: TextStyle(
                                fontSize: AppTheme.fontSmall,
                                color: context.textTertiary,
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context,
      {required bool finished, required int done, required int total}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 圆徽里的勾：从 0.6 弹到 1，闭环比单摆一个图标更像「刚刚成功」。
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.6, end: 1),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutBack,
          builder: (context, v, child) => Transform.scale(scale: v, child: child),
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(
              finished ? Icons.check_rounded : Icons.sync_rounded,
              size: 22,
              color: AppTheme.primaryColor,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 1),
              Text(
                '登录成功',
                style: TextStyle(
                  fontSize: AppTheme.fontTitle,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                  color: context.textPrimary,
                ),
              ),
              const SizedBox(height: 5),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                child: Text(
                  finished ? '都放好了，可以开始用了' : '正在把课表、成绩、一卡通放到手机上',
                  key: ValueKey(finished),
                  style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    height: 1.4,
                    color: context.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '$done/$total',
            style: TextStyle(
              fontSize: AppTheme.fontSmall,
              fontWeight: FontWeight.w600,
              color: finished ? AppTheme.primaryColor : context.textTertiary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _progress(BuildContext context, {required int done, required int total}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: total == 0 ? 0 : done / total),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        builder: (context, value, _) => LinearProgressIndicator(
          value: value,
          minHeight: 6,
          backgroundColor: context.subtleFill,
          valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryColor),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, LoginSyncItem item) {
    late final Widget leading;
    late final Color tint;
    late final String status;
    switch (item.status) {
      case LoginSyncStatus.pending:
        leading = Icon(Icons.circle_outlined,
            size: 15, color: context.textTertiary.withValues(alpha: 0.55));
        tint = context.textTertiary;
        status = '等待中';
      case LoginSyncStatus.running:
        leading = SizedBox(
          width: 15,
          height: 15,
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryColor),
          ),
        );
        tint = AppTheme.primaryColor;
        status = '${item.step.action}中…';
      case LoginSyncStatus.done:
        // 勾「长出来」：TweenAnimationBuilder 只在状态变化时重放。
        leading = TweenAnimationBuilder<double>(
          key: ValueKey('done-${item.step.name}'),
          tween: Tween<double>(begin: 0, end: 1),
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutBack,
          builder: (context, v, child) =>
              Transform.scale(scale: v.clamp(0.0, 1.2), child: child),
          child: Icon(Icons.check_circle_rounded,
              size: 15, color: context.successColor),
        );
        tint = context.successColor;
        status = '好了';
      case LoginSyncStatus.failed:
        leading = Icon(Icons.remove_circle_outline_rounded,
            size: 15, color: context.textTertiary);
        tint = context.textTertiary;
        status = item.note ?? '跳过';
    }
    final active = item.status == LoginSyncStatus.running ||
        item.status == LoginSyncStatus.done;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      decoration: BoxDecoration(
        color: active
            ? context.subtleFill
            : context.subtleFill.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm + 2),
      ),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item.step.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active ? context.textPrimary : context.textTertiary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 116),
            child: Text(
              item.note == null || item.status != LoginSyncStatus.done
                  ? status
                  : '${item.note}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: AppTheme.fontCaption,
                color: tint,
                fontWeight: item.status == LoginSyncStatus.done
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
