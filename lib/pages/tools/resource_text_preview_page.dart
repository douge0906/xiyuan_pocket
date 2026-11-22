import 'package:flutter/material.dart';

import '../../services/control_service.dart';
import '../../theme/app_theme.dart';

/// DOCX 在线文本预览：服务端只抽取正文文字，不渲染排版。
/// 预览失败（例如旧版 `.doc` 或损坏文件）时提供“下载后用 Word 打开”。
class ResourceTextPreviewPage extends StatefulWidget {
  const ResourceTextPreviewPage({
    super.key,
    required this.title,
    required this.fileId,
    this.onDownload,
    this.downloadLabel = '下载后用 Word 打开',
  });

  final String title;
  final int fileId;
  final Future<void> Function()? onDownload;

  /// [onDownload] 按钮的文案。默认是资源中心的「再下载一次」语境；
  /// 「我的下载」页传的是「用其他应用打开本地文件」，因为那里文件就在本机。
  final String downloadLabel;

  @override
  State<ResourceTextPreviewPage> createState() =>
      _ResourceTextPreviewPageState();
}

class _ResourceTextPreviewPageState extends State<ResourceTextPreviewPage> {
  bool _loading = true;
  String? _text;
  String? _error;
  bool _truncated = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await ControlService.fetchResourceTextPreview(
      fileId: widget.fileId,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _text = result.text;
      _truncated = result.truncated;
      _error = result.failure?.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Scaffold(
      backgroundColor: isDark ? context.scaffoldColor : Colors.white,
      appBar: AppBar(
        title: Text(widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: context.cardColor,
        elevation: 0,
        actions: [
          if (_text != null)
            IconButton(
              tooltip: '刷新预览',
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.description_outlined,
                            size: 42, color: context.textTertiary),
                        const SizedBox(height: 12),
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: AppTheme.fontSmall,
                                color: context.textSecondary)),
                        const SizedBox(height: 10),
                        if (widget.onDownload != null)
                          FilledButton.tonal(
                            onPressed: () => widget.onDownload!(),
                            child: Text(widget.downloadLabel),
                          ),
                        TextButton(onPressed: _load, child: const Text('重试')),
                      ],
                    ),
                  ),
                )
              : Scrollbar(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 36),
                    child: SelectableText(
                      _text!.isEmpty ? '文档正文为空' : _text!,
                      style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        height: 1.65,
                        color: context.textPrimary,
                      ),
                    ),
                  ),
                ),
      bottomNavigationBar: _truncated
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Text(
                  '文档较长，只展示前 20 万字符；完整内容请下载后查看。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: AppTheme.fontSmall,
                      color: context.textTertiary),
                ),
              ),
            )
          : null,
    );
  }
}
