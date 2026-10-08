import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/message.dart';
import '../../theme/app_theme.dart';
import '../../widgets/markdown_body.dart';

/// 详情加载器。由调用方注入（通常是 `MessageRepository.loadDetail`），
/// 这样详情页不必认识仓库、也不必认识任何一种抓取器。
typedef MessageDetailLoader = Future<MessageDetail?> Function(Message message);

/// 消息详情页 —— **所有消息源共用的一页**。
///
/// 重构前有两个几乎一样的详情页（`SchoolNoticeDetailPage`、
/// `CampusInfoDetailPage`），各写各的排版与加载：一个带「复制全文」、
/// 另一个带右上角「查看原文」；正文取不到时的提示也不一样。
/// 现在合并成这一页，两个源的条目点进来看到的是同一个页面。
///
/// 【失败与空分开】[MessageDetailLoader] 返回 `null` = 抓取失败
/// （不是「没有正文」）。失败时页面顶部给一行提示并保留列表里已有的
/// 标题/日期，绝不留白。
class MessageDetailPage extends StatefulWidget {
  final Message message;

  /// 来源名（如「教务处」），用作 AppBar 标题。
  final String sourceName;

  final MessageDetailLoader loader;

  const MessageDetailPage({
    super.key,
    required this.message,
    required this.sourceName,
    required this.loader,
  });

  @override
  State<MessageDetailPage> createState() => _MessageDetailPageState();
}

class _MessageDetailPageState extends State<MessageDetailPage> {
  MessageDetail? _detail;

  /// 抓取失败（`loadDetail` 返回 null 或抛异常）。
  bool _failed = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    MessageDetail? d;
    var failed = false;
    try {
      d = await widget.loader(widget.message);
      failed = d == null;
    } catch (_) {
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _detail = d;
      _failed = failed;
      _loading = false;
    });
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开该链接')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mainText = context.textPrimary;
    final subText = isDark ? Colors.grey.shade600 : Colors.grey.shade400;

    // 标题/日期/链接都以**列表项**为准：详情抓失败时它们照样在，
    // 用户不会看到一个空白页。详情抓到了就用详情里的更新值。
    final title = _detail?.title.isNotEmpty == true
        ? _detail!.title
        : widget.message.title;
    final date = _detail?.date.isNotEmpty == true
        ? _detail!.date
        : widget.message.date;
    final url = _detail?.url.isNotEmpty == true
        ? _detail!.url
        : widget.message.url;
    final author = (_detail?.author ?? '').trim();
    final content = (_detail?.content ?? '').trim();
    final attachments = _detail?.attachments ?? const [];

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : AppTheme.backgroundColor,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF121212) : AppTheme.backgroundColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(widget.sourceName,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: '复制全文',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: '$title\n\n$content'));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制全文')),
              );
            },
            icon: const Icon(Icons.copy_rounded, size: 19),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 20,
                      height: 1.4,
                      fontWeight: FontWeight.bold,
                      color: mainText,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.schedule_rounded, size: 13, color: subText),
                      const SizedBox(width: 4),
                      Text(
                        date.isNotEmpty ? date : '日期未知',
                        style: TextStyle(fontSize: 12.5, color: subText),
                      ),
                      if (author.isNotEmpty) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            author,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12.5, color: subText),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 14),
                  Divider(height: 1, color: context.borderColor),
                  const SizedBox(height: 18),

                  // 正文
                  if (content.isNotEmpty)
                    MarkdownBody(
                      data: content,
                      textColor: isDark
                          ? Colors.grey.shade200
                          : const Color(0xFF374151),
                      linkColor: AppTheme.primaryColor,
                    )
                  else
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _failed
                              ? '正文获取失败，请稍后重试或查看原文。'
                              : '正文未获取到。\n可点下方「查看原文」在浏览器中打开。',
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.7,
                            color: Colors.grey.shade500,
                          ),
                        ),
                        if (_failed) ...[
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: _load,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('重新加载'),
                          ),
                        ],
                      ],
                    ),

                  // 附件
                  if (attachments.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text('附件',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: mainText)),
                    const SizedBox(height: 10),
                    ...attachments.map((a) => _attachmentRow(a, isDark)),
                  ],

                  // 查看原文
                  if (url.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => _openLink(url),
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: const Text('查看原文'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  /// 附件行（圆角卡片 + 1px 灰线，与全局卡片语言一致）。
  Widget _attachmentRow(Map<String, dynamic> a, bool isDark) {
    final name = (a['name'] ?? a['url'] ?? '附件').toString();
    final url = (a['url'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: url.isNotEmpty ? () => _openLink(url) : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: context.borderColor),
            ),
            child: Row(
              children: [
                Icon(Icons.attachment_rounded,
                    size: 20, color: Colors.grey.shade500),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark
                          ? Colors.grey.shade200
                          : const Color(0xFF374151),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(Icons.open_in_new_rounded,
                    size: 18, color: Colors.grey.shade500),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
