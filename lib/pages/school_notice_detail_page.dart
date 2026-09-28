import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/school_notice.dart';
import '../services/school_notice_service.dart';
import '../widgets/markdown_body.dart';
import '../theme/app_theme.dart';

/// 学校公告详情页（独立系统，页面模式）：
/// 标题 / 发布日期 / 作者 / Markdown 正文 / 附件 / 查看原文。
class SchoolNoticeDetailPage extends StatefulWidget {
  final SchoolNotice notice;

  const SchoolNoticeDetailPage({super.key, required this.notice});

  @override
  State<SchoolNoticeDetailPage> createState() => _SchoolNoticeDetailPageState();
}

class _SchoolNoticeDetailPageState extends State<SchoolNoticeDetailPage> {
  Map<String, dynamic>? _detail;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    // 先看本地缓存，秒开；再联网刷新正文
    final cached =
        await SchoolNoticeService.loadCachedDetail(widget.notice.id);
    if (cached != null && mounted) {
      setState(() {
        _detail = cached;
        _loading = false;
      });
    }
    try {
      final detail = await SchoolNoticeService.fetchDetail(widget.notice.id);
      if (mounted) {
        setState(() {
          _detail = detail;
          _loading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // 无缓存也无网络：只显示列表里已有的信息
        _detail ??= {
          'title': widget.notice.title,
          'date': widget.notice.date,
          'content': '',
          'url': widget.notice.url,
          'attachments': const [],
        };
      });
    }
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
    final subText = Colors.grey.shade500;

    final detail = _detail;
    final title = (detail?['title'] ?? widget.notice.title).toString();
    final date = ((detail?['date'] ?? widget.notice.date).toString()).isNotEmpty
        ? (detail?['date'] ?? widget.notice.date).toString()
        : '';
    final author = ((detail?['author'] ?? '').toString()).trim();
    final content = (detail?['content'] ?? '').toString().trim();
    final url = ((detail?['url'] ?? widget.notice.url).toString()).trim();
    final attachments = ((detail?['attachments'] as List<dynamic>?) ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : const Color(0xFFF8F9FC),
      appBar: AppBar(
        title: Text(
          '公告详情',
          style: TextStyle(fontWeight: FontWeight.bold, color: mainText),
        ),
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: mainText),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.copy_rounded, color: mainText),
            tooltip: '复制全文',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: '$title\n\n$content'));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制全文')),
              );
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      height: 1.4,
                      color: mainText,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 发布日期 + 作者
                  Row(
                    children: [
                      if (date.isNotEmpty)
                        Text(
                          date,
                          style: TextStyle(fontSize: 12.5, color: subText),
                        ),
                      const Spacer(),
                      if (author.isNotEmpty)
                        Flexible(
                          child: Text(
                            author,
                            style: TextStyle(fontSize: 12.5, color: subText),
                            textAlign: TextAlign.right,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Divider(
                    height: 1,
                    thickness: 0.5,
                    color: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
                  ),
                  const SizedBox(height: 16),
                  // Markdown 正文
                  if (content.isNotEmpty)
                    MarkdownBody(
                      data: content,
                      textColor: isDark
                          ? Colors.grey.shade200
                          : const Color(0xFF374151),
                      linkColor: const Color(0xFF0EA5E9),
                    ),
                  if (content.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '正文获取失败，请尝试查看原文。',
                        style: TextStyle(
                            fontSize: 14, color: Colors.grey.shade500),
                      ),
                    ),
                  // 附件
                  if (attachments.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text(
                      '附件',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: mainText,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...attachments.map((a) {
                      final name = (a['name'] as String? ?? '附件').toString();
                      final aUrl = (a['url'] as String? ?? '').toString();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Material(
                          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: aUrl.isNotEmpty ? () => _openLink(aUrl) : null,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 14),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isDark
                                      ? Colors.grey.shade800
                                      : const Color(0xFFE5E7EB),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.attachment_rounded,
                                    size: 20,
                                    color: Colors.grey.shade500,
                                  ),
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
                                  Icon(
                                    Icons.open_in_new_rounded,
                                    size: 18,
                                    color: Colors.grey.shade500,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
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
}
