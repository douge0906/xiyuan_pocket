import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// 法务文本展示页：读取 assets/legal 下的 Markdown 文本。
class LegalDocPage extends StatefulWidget {
  const LegalDocPage({
    super.key,
    required this.title,
    required this.assetPath,
  });

  final String title;
  final String assetPath;

  @override
  State<LegalDocPage> createState() => _LegalDocPageState();
}

class _LegalDocPageState extends State<LegalDocPage> {
  String _text = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final text = await rootBundle.loadString(widget.assetPath);
    if (mounted) setState(() => _text = text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: Text(widget.title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: _text.isEmpty
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
              child: SelectableText(
                _text,
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  height: 1.65,
                  color: context.textPrimary,
                ),
              ),
            ),
    );
  }
}
