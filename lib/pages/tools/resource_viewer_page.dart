import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';

import '../../theme/app_theme.dart';

/// App 内 PDF 阅读：本地缓存文件 + 翻页/缩放。
class ResourceViewerPage extends StatefulWidget {
  const ResourceViewerPage({
    super.key,
    required this.title,
    required this.filePath,
  });

  final String title;
  final String filePath;

  @override
  State<ResourceViewerPage> createState() => _ResourceViewerPageState();
}

class _ResourceViewerPageState extends State<ResourceViewerPage> {
  int _pages = 0;
  int _current = 1;
  bool _ready = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF121212) : const Color(0xFFECEEF2),
      appBar: AppBar(
        title: Text(widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: AppTheme.fontTitle, fontWeight: FontWeight.bold)),
        backgroundColor: context.cardColor,
        elevation: 0,
        actions: [
          if (_ready && _pages > 0)
            Center(
              child: Text('$_current / $_pages',
                  style: TextStyle(
                      fontSize: AppTheme.fontSmall, color: context.textSecondary)),
            ),
          const SizedBox(width: 14),
        ],
      ),
      body: Platform.isAndroid || Platform.isIOS
          ? Stack(
              children: [
                PDFView(
                  filePath: widget.filePath,
                  enableSwipe: true,
                  swipeHorizontal: true,
                  autoSpacing: true,
                  pageFling: true,
                  backgroundColor: isDark
                      ? const Color(0xFF121212)
                      : const Color(0xFFECEEF2),
                  onRender: (pages) {
                    if (!mounted) return;
                    setState(() {
                      _pages = pages ?? 0;
                      _ready = true;
                    });
                  },
                  onPageChanged: (page, total) {
                    if (!mounted) return;
                    setState(() => _current = (page ?? 0) + 1);
                  },
                  onError: (error) {
                    if (!mounted) return;
                    // 异常原文只进日志，页面上给人话（2026-11-01 修：
                    // 之前直接 Text(_error!) 渲染，用户看到一屏英文堆栈）。
                    debugPrint('[ResourceViewer] PDF 打开失败: $error');
                    setState(() => _error = 'PDF 打开失败，请改用下载后查看');
                  },
                ),
                if (!_ready && _error == null)
                  const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(strokeWidth: 2.5),
                        SizedBox(height: 12),
                        Text('正在打开 PDF…',
                            style: TextStyle(
                                fontSize: AppTheme.fontSmall, color: Colors.grey)),
                      ],
                    ),
                  ),
                if (_error != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(_error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: AppTheme.fontSmall, color: context.textSecondary)),
                    ),
                  ),
              ],
            )
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text('当前平台不支持 App 内 PDF 阅读，请使用下载功能',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall, color: context.textSecondary)),
              ),
            ),
    );
  }
}
