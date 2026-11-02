import 'package:flutter/material.dart';

import '../services/control_service.dart';
import '../theme/app_theme.dart';

/// 居中的意见反馈框：内容必填，联系方式选填。
Future<void> showFeedbackDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _FeedbackDialog(),
  );
}

class _FeedbackDialog extends StatefulWidget {
  const _FeedbackDialog();

  @override
  State<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<_FeedbackDialog> {
  final TextEditingController _content = TextEditingController();
  final TextEditingController _contact = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _content.dispose();
    _contact.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _content.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '请先写点内容');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final ok = await ControlService.submitFeedback(
      text,
      contact: _contact.text,
    );
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _sending = false;
        _error = '提交失败，请检查网络后重试';
      });
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('反馈已提交，谢谢')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('意见反馈'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _content,
              maxLines: 6,
              maxLength: 2000,
              decoration: const InputDecoration(
                hintText: '遇到什么问题，或希望增加什么功能？',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _contact,
              maxLength: 120,
              decoration: const InputDecoration(
                hintText: '联系方式（选填，便于回复）',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _error!,
                  style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: _sending ? null : _submit,
          child: _sending
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('提交'),
        ),
      ],
    );
  }
}
