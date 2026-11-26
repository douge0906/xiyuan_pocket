import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/campus/cprint_models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';
import 'resource_viewer_page.dart';

/// 扫描件详情。
///
/// 设计稿（§6 / `cprint_scan_02_detail.png`）上半屏是纸张预览、下半屏是
/// 「字段映射」——把 `szDisplayName` / `dwStatus & 256` 这种原始字段名
/// 直接印给用户看。那是给开发看的对照图，落地改成人话：
///
/// * 预览只对 PDF / 图片有意义，其它类型直接给「用其他应用打开」。
/// * 元信息只留用户关心的四项：提交时间、大小、类型、是否过期。
///   内部字段名（`dwJobId` 之类）不展示 —— 用户拿它没用。
class CprintScanDetailPage extends StatelessWidget {
  const CprintScanDetailPage({
    super.key,
    required this.item,
    required this.localPath,
    required this.onDownload,
    required this.onShare,
    required this.onDeleteLocal,
    required this.onDeleteRemote,
  });

  final CprintScanItem item;
  final String? localPath;
  final Future<void> Function() onDownload;
  final Future<void> Function() onShare;
  final Future<void> Function() onDeleteLocal;
  final Future<void> Function() onDeleteRemote;

  @override
  Widget build(BuildContext context) {
    final type = item.docType;
    final expired = item.isExpired;
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: Text(
          item.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: AppTheme.fontTitle,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _preview(context, type),
          const SizedBox(height: 14),
          AppCard(
            radius: AppTheme.radiusLg,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Column(
              children: [
                _row(context, '提交时间', _fmtDate()),
                _divider(context),
                _row(context, '文件大小', item.sizeLabel),
                _divider(context),
                _row(context, '文件类型',
                    type.classType == 'other' ? '其它' : type.type.toUpperCase()),
                _divider(context),
                _row(
                  context,
                  '状态',
                  expired ? '已过期，不可下载' : (localPath == null ? '未下载' : '已下载到本机'),
                  valueColor: expired ? context.warningColor : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (expired)
            _notice(context, '该文件已过期，不可下载。需要的话请重新去打印店扫一份。')
          else ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  await onDownload();
                },
                icon: const Icon(Icons.file_download_outlined, size: 18),
                label: Text(localPath == null ? '保存到手机' : '重新保存'),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await onShare();
                    },
                    icon: const Icon(Icons.ios_share_rounded, size: 18),
                    label: const Text('分享'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await onDeleteRemote();
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: context.dangerColor,
                      side: BorderSide(
                          color: context.dangerColor.withValues(alpha: .45)),
                    ),
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    label: const Text('从账号删除'),
                  ),
                ),
              ],
            ),
            if (localPath != null) ...[
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: () async {
                    await onDeleteLocal();
                  },
                  child: Text(
                    '删除本机文件（不影响账号里的）',
                    style: TextStyle(
                      fontSize: AppTheme.fontSmall,
                      color: context.textTertiary,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _preview(BuildContext context, CprintDocType type) {
    final path = localPath;
    if (path != null && type.classType == 'pdf') {
      return SizedBox(
        height: 320,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          child: ResourceViewerPage(title: item.displayName, filePath: path),
        ),
      );
    }
    if (path != null && type.classType == 'img') {
      return SizedBox(
        height: 320,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          child: InteractiveViewer(
            child: Image.file(File(path), fit: BoxFit.contain),
          ),
        ),
      );
    }
    return AppCard(
      radius: AppTheme.radiusLg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 26),
      child: Column(
        children: [
          Icon(
            type.classType == 'pdf'
                ? Icons.picture_as_pdf_outlined
                : Icons.insert_drive_file_outlined,
            size: 40,
            color: context.textTertiary,
          ),
          const SizedBox(height: 10),
          Text(
            localPath == null
                ? '下载后可以直接在 App 里看'
                : '这种格式 App 里看不了，用「分享」发给别的应用打开',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTheme.fontSmall,
              height: 1.5,
              color: context.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _notice(BuildContext context, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.warningColor.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: context.warningColor.withValues(alpha: .35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded,
              size: 16, color: context.warningColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                height: 1.5,
                color: context.warningColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value,
      {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                color: context.textTertiary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w500,
                color: valueColor ?? context.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(BuildContext context) => Container(
        height: 1,
        color: context.borderColor.withValues(alpha: .55),
      );

  String _fmtDate() {
    final at = item.submittedAt;
    if (at == null) return item.submitDate.isEmpty ? '未知' : item.submitDate;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
  }
}
