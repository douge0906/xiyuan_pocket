import 'dart:async';

import 'package:flutter/material.dart';

import '../services/login_sync_progress.dart';
import '../theme/app_theme.dart';

/// 登录成功后的「自动同步」进度对话框（v1.0.9）。
///
/// 用户原话：「由于首次登录会触发各项自动功能，课程表突然弹出显得突兀，
/// 遂设计一个进度条提示 登录成功 自动同步成绩 中.... 同步成功。
/// 自动同步...中 ...同步成功 一行一个功能」
///
/// 行为：
/// · 弹出时先 [LoginSyncProgress.reset]，再交给调用方去跑同步；
/// · 每行 = 图标 + 功能名 + 右侧状态（同步中… / 同步成功 / 同步失败）；
/// · 顶部有一条总进度（完成数 / 总数）；
/// · 全部结束自动关闭（留 700ms 让用户看见最后一行变绿），
///   用户也可以随时点「完成」提前关掉 —— **关掉不会中断同步**。
class LoginSyncDialog extends StatefulWidget {
  const LoginSyncDialog({super.key});

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

  @override
  void initState() {
    super.initState();
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
    final finished = items.every((e) => e.status != LoginSyncStatus.pending &&
        e.status != LoginSyncStatus.running);
    if (!finished) {
      _autoClose?.cancel();
      _autoClose = null;
      return;
    }
    if (_autoClose != null) return;
    _autoClose = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      final nav = Navigator.of(context);
      if (nav.canPop()) nav.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(color: AppTheme.cardStrokeColor(context.isDark)),
      ),
      contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      content: ValueListenableBuilder<List<LoginSyncItem>>(
        valueListenable: LoginSyncProgress.notifier,
        builder: (context, items, _) {
          final total = items.length;
          final done = items
              .where((e) => e.status == LoginSyncStatus.done)
              .length;
          final finished = items.every(
              (e) => e.status != LoginSyncStatus.pending &&
                  e.status != LoginSyncStatus.running);
          return SizedBox(
            width: (MediaQuery.of(context).size.width - 120).clamp(0.0, 320.0).toDouble(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.verified_rounded,
                        size: 20, color: context.successColor),
                    const SizedBox(width: 8),
                    Text(
                      '登录成功',
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle,
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  finished ? '同步完成' : '正在同步你的数据…',
                  style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    color: context.textTertiary,
                  ),
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: total == 0 ? null : done / total,
                    minHeight: 5,
                    backgroundColor: context.subtleFill,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(AppTheme.primaryColor),
                  ),
                ),
                const SizedBox(height: 16),
                // 步骤数会随功能增长（现在是 7 步：课表 / 成绩 / 考试 /
                // 教材 / 一卡通 / 学业 / 电费），备注也可能长到一行半
                // （「教务未配置培养方案」）。固定高度在矮屏 + 大字号下会
                // overflow，所以给行区域一个上限、超出就滚。
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < items.length; i++) ...[
                          if (i > 0) const SizedBox(height: 10),
                          _row(context, items[i]),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(
                      finished ? '完成' : '后台继续',
                      style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primaryColor,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _row(BuildContext context, LoginSyncItem item) {
    late final IconData icon;
    late final Color color;
    late final String text;
    switch (item.status) {
      case LoginSyncStatus.pending:
        icon = Icons.circle_outlined;
        color = context.textTertiary;
        text = '等待中';
      case LoginSyncStatus.running:
        icon = Icons.sync_rounded;
        color = AppTheme.primaryColor;
        text = '${item.step.action}中…';
      case LoginSyncStatus.done:
        icon = Icons.check_circle_rounded;
        color = context.successColor;
        text = '同步成功';
      case LoginSyncStatus.failed:
        icon = Icons.remove_circle_outline_rounded;
        color = context.textTertiary;
        text = item.note ?? '同步失败';
    }
    return Row(
      children: [
        // running 的状态图标用旋转的小圈，比静态图标更像「正在跑」。
        if (item.status == LoginSyncStatus.running)
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          )
        else
          Icon(icon, size: 14, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            item.step.title,
            style: TextStyle(
              fontSize: AppTheme.fontBody,
              color: context.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(fontSize: AppTheme.fontSmall, color: color),
        ),
      ],
    );
  }
}
