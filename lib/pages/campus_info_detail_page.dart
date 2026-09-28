import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/campus_info_service.dart';
import '../theme/app_theme.dart';
import '../widgets/markdown_body.dart';

/// 校园资讯详情页（v2.4.0）。
///
/// ⚠️ 为什么用**整页**而不是底部弹层：
///   之前用 `showModalBottomSheet`（上滑式），与「学校公告详情」的观感不一致，
///   用户反馈「上滑式丑陋」。现统一为整页 push —— 长正文阅读体验也更好，
///   且顶部有返回键、可下滑滚动，符合信息类页面的习惯。
class CampusInfoDetailPage extends StatefulWidget {
  final String columnId;
  final String columnName;
  final CampusInfoItem item;

  const CampusInfoDetailPage({
    super.key,
    required this.columnId,
    required this.columnName,
    required this.item,
  });

  @override
  State<CampusInfoDetailPage> createState() => _CampusInfoDetailPageState();
}

class _CampusInfoDetailPageState extends State<CampusInfoDetailPage> {
  CampusInfoDetail? _detail;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await CampusInfoService.fetchDetail(
        widget.columnId, widget.item.id);
    if (!mounted) return;
    setState(() {
      _detail = d;
      _loading = false;
    });
  }

  Future<void> _openOriginal() async {
    final uri = Uri.tryParse(widget.item.url);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开该链接')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final content = _detail?.content ?? '';
    final attachments = _detail?.attachments ?? const [];

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF121212) : AppTheme.backgroundColor,
      appBar: AppBar(
        backgroundColor:
            isDark ? const Color(0xFF121212) : AppTheme.backgroundColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(widget.columnName,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: '查看原文',
            onPressed: _openOriginal,
            icon: const Icon(Icons.open_in_browser, size: 20),
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
                  // 标题
                  Text(
                    widget.item.title,
                    style: TextStyle(
                      fontSize: 20,
                      height: 1.4,
                      fontWeight: FontWeight.bold,
                      color: context.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  // 元信息：日期（+ 作者，若有）
                  Row(
                    children: [
                      Icon(Icons.schedule_rounded,
                          size: 13,
                          color: isDark
                              ? Colors.grey.shade600
                              : Colors.grey.shade400),
                      const SizedBox(width: 4),
                      Text(
                        widget.item.date,
                        style: TextStyle(
                            fontSize: 12.5,
                            color: isDark
                                ? Colors.grey.shade600
                                : Colors.grey.shade400),
                      ),
                      if ((_detail?.author ?? '').isNotEmpty) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _detail!.author,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12.5,
                                color: isDark
                                    ? Colors.grey.shade600
                                    : Colors.grey.shade400),
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
                    Text(
                      '正文未获取到。\n可点右上角「查看原文」在浏览器中打开。',
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.7,
                        color: isDark
                            ? Colors.grey.shade500
                            : Colors.grey.shade500,
                      ),
                    ),
                  // 附件
                  if (attachments.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text('附件',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: context.textPrimary)),
                    const SizedBox(height: 10),
                    ...attachments.map((a) => _attachmentRow(a, isDark)),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _attachmentRow(Map<String, dynamic> a, bool isDark) {
    final name = (a['name'] ?? a['url'] ?? '').toString();
    final url = (a['url'] ?? '').toString();
    return InkWell(
      onTap: () async {
        final uri = Uri.tryParse(url);
        if (uri != null) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(Icons.attach_file, size: 16, color: AppTheme.primaryColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                style: TextStyle(fontSize: 13.5, color: AppTheme.primaryColor),
              ),
            ),
            Icon(Icons.download_rounded,
                size: 16,
                color: isDark ? Colors.grey.shade600 : Colors.grey.shade400),
          ],
        ),
      ),
    );
  }
}