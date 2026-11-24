import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/resource_download_service.dart';
import '../../theme/app_theme.dart';
import 'resource_text_preview_page.dart';
import 'resource_viewer_page.dart';

/// 我的下载：列出本机已保存的资源，支持打开/分享与删除。
class MyResourceDownloadsPage extends StatefulWidget {
  const MyResourceDownloadsPage({super.key});

  @override
  State<MyResourceDownloadsPage> createState() =>
      _MyResourceDownloadsPageState();
}

class _MyResourceDownloadsPageState extends State<MyResourceDownloadsPage> {
  bool _loading = true;
  List<DownloadedResource> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await ResourceDownloadService.listDownloads();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _open(DownloadedResource item) async {
    if (!await File(item.path).exists()) {
      await _load();
      return;
    }
    if (item.name.toLowerCase().endsWith('.pdf')) {
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ResourceViewerPage(
          title: item.name,
          filePath: item.path,
        ),
      ));
      return;
    }
    if (item.name.toLowerCase().endsWith('.docx')) {
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ResourceTextPreviewPage(
          title: item.name,
          fileId: item.fileId,
          // 本地兜底：正文是服务端抽的，断网或者服务端没抽出来时，
          // 这个文件明明就在本机，得给一个直接打开的出口。
          onDownload: () => _share(item),
          downloadLabel: '用其他应用打开本地文件',
        ),
      ));
      return;
    }
    await _share(item);
  }

  Future<void> _share(DownloadedResource item) async {
    final file = File(item.path);
    if (!await file.exists()) return;
    await Share.shareXFiles([XFile(item.path)], text: item.name);
  }

  Future<void> _redownload(DownloadedResource item) async {
    if (item.fileId <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这条旧下载缺少文件编号，请到资源中心重新下载')),
      );
      return;
    }
    try {
      await ResourceDownloadService.saveToDocuments(
        item.entry,
        item.courseName,
        force: true,
      );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已重新下载')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    }
  }

  Future<void> _delete(DownloadedResource item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          side: BorderSide(color: context.borderColor),
        ),
        title: Row(
          children: [
            const Expanded(child: Text('删除本地文件？')),
            IconButton(
              tooltip: '关闭',
              onPressed: () => Navigator.pop(ctx, false),
              icon: Icon(Icons.close_rounded,
                  size: 20, color: context.textTertiary),
            ),
          ],
        ),
        content: Text(item.name,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ResourceDownloadService.deleteDownload(item);
    } catch (e) {
      // 文件被占用 / 无权限 / 清单写盘失败都会走到这里。以前这条路径没有任何
      // 出口：条目还在列表里，用户不知道自己点的那一下到底有没有生效。
      messenger.showSnackBar(SnackBar(
          content:
              Text('删除失败：${e.toString().replaceFirst('Exception: ', '')}')));
      return;
    }
    await _load();
    messenger.showSnackBar(const SnackBar(content: Text('已删除本地文件')));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Scaffold(
      backgroundColor: isDark ? context.scaffoldColor : Colors.white,
      appBar: AppBar(
        title: const Text('我的下载',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: context.cardColor,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
          : _items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder_open_rounded,
                          size: 44, color: context.textTertiary),
                      const SizedBox(height: 10),
                      Text('还没有下载到本机的资源',
                          style: TextStyle(
                              fontSize: AppTheme.fontSmall,
                              color: context.textTertiary)),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, index) {
                      final item = _items[index];
                      return Material(
                        color: context.surfaceColor,
                        borderRadius: AppTheme.radiusMdAll,
                        child: InkWell(
                          borderRadius: AppTheme.radiusMdAll,
                          onTap: () => _open(item),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              borderRadius: AppTheme.radiusMdAll,
                              border: Border.all(color: context.borderColor),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.description_outlined,
                                    size: 20,
                                    color: context.textSecondary),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(item.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: AppTheme.fontBody)),
                                      const SizedBox(height: 3),
                                      Text(
                                        '${item.courseName} · '
                                        '${_fmtSize(item.size)} · '
                                        '${item.savedAt.replaceFirst('T', ' ').split('.').first}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: AppTheme.fontCaption,
                                            color: context.textTertiary),
                                      ),
                                    ],
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  onSelected: (value) {
                                    if (value == 'share') _share(item);
                                    if (value == 'redownload') _redownload(item);
                                    if (value == 'delete') _delete(item);
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                        value: 'share',
                                        child: Text('分享 / 用其他应用打开')),
                                    PopupMenuItem(
                                        value: 'redownload',
                                        child: Text('重新下载')),
                                    PopupMenuItem(
                                        value: 'delete',
                                        child: Text('删除本地文件')),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }

  String _fmtSize(int bytes) {
    if (bytes <= 0) return '0 KB';
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}
