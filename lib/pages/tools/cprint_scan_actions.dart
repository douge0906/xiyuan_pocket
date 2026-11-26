import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../services/campus/cprint_models.dart';
import '../../services/campus/cprint_scan_downloader.dart';
import '../../services/cancel_token.dart';
import '../../theme/app_theme.dart';

/// 带进度弹窗下载一份扫描件。返回本地路径；用户取消或失败返回 null。
///
/// 抽成公共函数是因为列表页和详情页都要用，两处各写一遍必然长出两套
/// 不一致的进度条和两套错误文案。
Future<String?> downloadCprintWithProgress(
  BuildContext context,
  CprintScanItem item,
) async {
  final nav = Navigator.of(context, rootNavigator: true);
  final progress = ValueNotifier<double>(0);
  final cancelToken = CancelToken();
  var open = true;

  void closeDialog() {
    if (!open) return;
    open = false;
    nav.pop();
  }

  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CprintProgressDialog(
      name: item.displayName,
      progress: progress,
      onCancel: () {
        cancelToken.cancel();
        closeDialog();
      },
    ),
  ));

  try {
    return await CprintScanDownloader.download(
      item,
      cancelToken: cancelToken,
      onProgress: (received, total) {
        if (cancelToken.isCancelled) return;
        progress.value = total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
      },
    );
  } finally {
    closeDialog();
    progress.dispose();
  }
}

class _CprintProgressDialog extends StatelessWidget {
  const _CprintProgressDialog({
    required this.name,
    required this.progress,
    required this.onCancel,
  });

  final String name;
  final ValueListenable<double> progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: context.cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          side: BorderSide(color: context.borderColor),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                '正在下载',
                style: TextStyle(
                  fontSize: AppTheme.fontTitle,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary,
                ),
              ),
            ),
            // R8：弹层右上角必须有 ×。进度框不能点外部关，这里的 ×
            // 与底部「取消」是同一个动作 —— 给习惯了点右上角的人一个出口。
            IconButton(
              tooltip: '取消下载',
              onPressed: onCancel,
              icon: Icon(Icons.close_rounded,
                  size: 20, color: context.textTertiary),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                color: context.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (_, v, __) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: v <= 0 ? null : v,
                      minHeight: 6,
                      backgroundColor: context.subtleFill,
                      valueColor:
                          AlwaysStoppedAnimation(AppTheme.primaryColor),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    v <= 0 ? '正在连接…' : '${(v * 100).round()}%',
                    style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: context.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: onCancel,
            child: Text(
              '取消',
              style: TextStyle(color: context.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

