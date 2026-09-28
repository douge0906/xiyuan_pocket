import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// 轻量 Markdown 渲染器（零第三方依赖）。
/// 支持：段落、# 标题、**加粗**、[链接](url)、![图片](url)、- 列表、| 表格 |。
/// 专为学校公告详情场景设计：正文为 HTML 转换后的 Markdown。
class MarkdownBody extends StatefulWidget {
  final String data;
  final double fontSize;
  final double height;
  final Color textColor;
  final Color linkColor;

  const MarkdownBody({
    super.key,
    required this.data,
    this.fontSize = 15.5,
    this.height = 1.85,
    required this.textColor,
    required this.linkColor,
  });

  @override
  State<MarkdownBody> createState() => _MarkdownBodyState();
}

class _MarkdownBodyState extends State<MarkdownBody> {
  final List<TapGestureRecognizer> _linkRecognizers = [];

  @override
  void dispose() {
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    _linkRecognizers.clear();

    final lines = widget.data.split('\n');
    final widgets = <Widget>[];
    int i = 0;

    while (i < lines.length) {
      final line = lines[i].trimRight();

      if (line.trim().isEmpty) {
        i++;
        continue;
      }

      // 表格块：连续以 | 开头的行
      if (line.trim().startsWith('|')) {
        final tableLines = <String>[];
        while (i < lines.length && lines[i].trim().startsWith('|')) {
          tableLines.add(lines[i].trim());
          i++;
        }
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: _buildTable(tableLines),
        ));
        continue;
      }

      // 标题
      if (line.trimLeft().startsWith('#')) {
        widgets.add(_buildHeading(line.trimLeft()));
        i++;
        continue;
      }

      // 列表项（连续的 - 行合并为一组）
      if (line.trimLeft().startsWith('- ')) {
        final items = <String>[];
        while (i < lines.length && lines[i].trimLeft().startsWith('- ')) {
          items.add(lines[i].trimLeft().substring(2));
          i++;
        }
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: items
                .map((it) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 3, right: 8),
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: widget.textColor.withOpacity(0.55),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text.rich(
                              _parseInline(it),
                              style: TextStyle(
                                fontSize: widget.fontSize,
                                height: widget.height,
                                color: widget.textColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ))
                .toList(),
          ),
        ));
        continue;
      }

      // 图片独立行（![...](...) 单独成行时大图展示）
      final imgOnly = RegExp(r'^!\[[^\]]*\]\(([^)]+)\)$').firstMatch(line.trim());
      if (imgOnly != null) {
        widgets.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              imgOnly.group(1)!,
              width: double.infinity,
              fit: BoxFit.contain,
              loadingBuilder: (_, child, progress) => progress == null
                  ? child
                  : Container(
                      height: 140,
                      alignment: Alignment.center,
                      color: Colors.grey.shade100,
                      child:
                          const CircularProgressIndicator(strokeWidth: 2),
                    ),
              errorBuilder: (_, __, ___) => Container(
                height: 100,
                alignment: Alignment.center,
                color: Colors.grey.shade100,
                child:
                    const Icon(Icons.broken_image, color: Colors.grey),
              ),
            ),
          ),
        ));
        i++;
        continue;
      }

      // 普通段落
      widgets.add(Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text.rich(
          _parseInline(line),
          style: TextStyle(
            fontSize: widget.fontSize,
            height: widget.height,
            color: widget.textColor,
          ),
        ),
      ));
      i++;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  Widget _buildHeading(String line) {
    int level = 0;
    while (level < line.length && line[level] == '#') {
      level++;
    }
    final text = line.substring(level).trim();
    final sizes = {1: 21.0, 2: 19.0, 3: 17.5, 4: 16.5, 5: 16.0, 6: 15.5};
    final size = sizes[level] ?? 16.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text.rich(
        _parseInline(text),
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.bold,
          height: 1.5,
          color: widget.textColor,
        ),
      ),
    );
  }

  /// 解析内联元素：**加粗**、[文字](url)、![alt](url)
  TextSpan _parseInline(String text) {
    final spans = <InlineSpan>[];
    // 统一匹配图片、链接、加粗
    final pattern = RegExp(
      r'!\[([^\]]*)\]\(([^)]+)\)|\[([^\]]+)\]\(([^)]+)\)|\*\*(.+?)\*\*',
    );
    int start = 0;
    for (final m in pattern.allMatches(text)) {
      if (m.start > start) {
        spans.add(TextSpan(text: text.substring(start, m.start)));
      }
      if (m.group(1) != null || m.group(2) != null) {
        // 图片内联：降级为链接（图片行已在块级处理）
        final url = m.group(2)!;
        spans.add(TextSpan(
          text: '[查看图片]',
          style: TextStyle(
            color: widget.linkColor,
            fontWeight: FontWeight.w600,
          ),
          recognizer: TapGestureRecognizer()..onTap = () => _openLink(url),
        ));
      } else if (m.group(3) != null) {
        // 链接
        final label = m.group(3)!;
        final url = m.group(4)!;
        final rec = TapGestureRecognizer()..onTap = () => _openLink(url);
        _linkRecognizers.add(rec);
        spans.add(TextSpan(
          text: label,
          style: TextStyle(
            color: widget.linkColor,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.underline,
          ),
          recognizer: rec,
        ));
      } else if (m.group(5) != null) {
        // 加粗
        spans.add(TextSpan(
          text: m.group(5)!,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ));
      }
      start = m.end;
    }
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start)));
    }
    return TextSpan(children: spans.isEmpty ? [TextSpan(text: text)] : spans);
  }

  Widget _buildTable(List<String> tableLines) {
    // 去掉分隔行 |---|---|
    final rows = tableLines
        .where((l) => !RegExp(r'^\|[\s:|-]+\|$').hasMatch(l))
        .map((l) => l
            .split('|')
            .map((c) => c.trim())
            .toList())
        .where((cells) => cells.isNotEmpty)
        .toList();
    if (rows.isEmpty) return const SizedBox.shrink();

    // 归一化列数
    final colCount = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    for (final r in rows) {
      while (r.length < colCount) {
        r.add('');
      }
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows.asMap().entries.map((entry) {
          final idx = entry.key;
          final row = entry.value;
          final isHeader = idx == 0;
          return Container(
            decoration: BoxDecoration(
              color: isHeader
                  ? widget.textColor.withOpacity(0.06)
                  : (idx.isEven ? widget.textColor.withOpacity(0.03) : null),
              border: Border(
                bottom: BorderSide(
                  color: widget.textColor.withOpacity(0.12),
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: row.map((cell) {
                return Container(
                  constraints: const BoxConstraints(minWidth: 64, maxWidth: 220),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  child: Text.rich(
                    _parseInline(cell),
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      fontWeight: isHeader ? FontWeight.bold : FontWeight.normal,
                      color: widget.textColor,
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        }).toList(),
      ),
    );
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
}
