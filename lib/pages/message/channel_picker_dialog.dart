import 'package:flutter/material.dart';

import '../../services/message_source.dart';
import '../../theme/app_theme.dart';

/// 打开「订阅栏目」面板（居中弹窗）。
///
/// 返回值：新的订阅集合；用户点 ✕ / 背景关闭则返回 `null`（表示不改动）。
///
/// 🔴 **居中弹窗，不是底部弹层**。项目死律：`showModalBottomSheet` 一律不用
/// （此前资讯详情、频道面板都用过上滑弹层，用户反馈「上滑式丑陋」，
/// 现统一为居中弹窗 + 右上角 ✕）。
///
/// 【所有栏目一律平等】列表里**包含教务处** —— 它只是默认勾上，一样可以取消。
Future<Set<String>?> showChannelPickerDialog(
  BuildContext context, {
  required List<MessageChannel> channels,
  required Set<String> selected,
}) {
  return showDialog<Set<String>>(
    context: context,
    // 用不透明的 DialogStyle 背景：与项目其它弹窗一致
    builder: (_) => _ChannelPickerDialog(
      channels: channels,
      initial: selected,
    ),
  );
}

class _ChannelPickerDialog extends StatefulWidget {
  final List<MessageChannel> channels;
  final Set<String> initial;

  const _ChannelPickerDialog({required this.channels, required this.initial});

  @override
  State<_ChannelPickerDialog> createState() => _ChannelPickerDialogState();
}

class _ChannelPickerDialogState extends State<_ChannelPickerDialog> {
  late Set<String> _sel;

  @override
  void initState() {
    super.initState();
    _sel = Set<String>.from(widget.initial);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final maxH = MediaQuery.of(context).size.height * 0.72;

    return Dialog(
      backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 420, maxHeight: maxH),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题行 + 右上角关闭
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '订阅栏目',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: context.textPrimary,
                      ),
                    ),
                  ),
                  _closeButton(context, isDark),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '勾选后该栏目会出现在消息页顶部；取消勾选即隐藏。',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: isDark ? Colors.grey.shade500 : Colors.grey.shade500,
                ),
              ),
              const SizedBox(height: 8),
              // 一条一行
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: widget.channels.length,
                  itemBuilder: (ctx, i) {
                    final ch = widget.channels[i];
                    return _row(ch, isDark);
                  },
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(_sel),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text('完成'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _closeButton(BuildContext context, bool isDark) => InkWell(
        onTap: () => Navigator.of(context).pop(),
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.close_rounded,
            size: 20,
            color: isDark ? Colors.grey.shade500 : Colors.grey.shade500,
          ),
        ),
      );

  Widget _row(MessageChannel ch, bool isDark) {
    final on = _sel.contains(ch.id);
    return InkWell(
      onTap: () => setState(() {
        if (on) {
          _sel.remove(ch.id);
        } else {
          _sel.add(ch.id);
        }
      }),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            // 自绘复选框：与页面风格一致，不依赖平台样式
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: on ? AppTheme.primaryColor : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: on
                      ? AppTheme.primaryColor
                      : (isDark ? Colors.grey.shade600 : Colors.grey.shade300),
                  width: 1.5,
                ),
              ),
              child: on
                  ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ch.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: context.textPrimary,
                    ),
                  ),
                  if (ch.desc.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      ch.desc,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: isDark ? Colors.grey.shade500 : Colors.grey.shade500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
