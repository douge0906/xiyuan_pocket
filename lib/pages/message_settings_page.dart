import 'package:flutter/material.dart';

import '../services/storage_service.dart';
import '../theme/app_theme.dart';

/// 消息栏目设置（独立页面）。
///
/// 入口：消息页右上角的设置图标 → push 到本页。
/// 目前只有「栏目样式」一项（纯白列表 / 圆角卡片），选择后**立即生效并持久化**，
/// 返回消息页时自动按新样式渲染。
class MessageSettingsPage extends StatefulWidget {
  const MessageSettingsPage({super.key});

  @override
  State<MessageSettingsPage> createState() => _MessageSettingsPageState();
}

class _MessageSettingsPageState extends State<MessageSettingsPage> {
  Future<String>? _future;
  String _style = StorageService.kMessageStylePlain;

  @override
  void initState() {
    super.initState();
    _future = StorageService.loadMessageStyle();
  }

  Future<void> _pick(String v) async {
    setState(() {
      _style = v;
      _future = Future<String>.value(v); // 立即生效，不回读存储 -> 避免选中态闪一下
    });
    await StorageService.saveMessageStyle(v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('消息设置',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: FutureBuilder<String>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
          }
          _style = snap.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text('栏目样式',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: context.textSecondary)),
              ),
              _card([
                _option(
                  icon: Icons.view_agenda_outlined,
                  title: '纯白列表',
                  subtitle: '无卡片边框，行与行之间一条细线',
                  value: StorageService.kMessageStylePlain,
                ),
                Divider(height: 1, color: context.borderColor),
                _option(
                  icon: Icons.crop_square_rounded,
                  title: '圆角卡片',
                  subtitle: '每条消息一个白色圆角卡片，带阴影',
                  value: StorageService.kMessageStyleCard,
                ),
              ]),
              const SizedBox(height: 14),
              Text('样式改动立即生效，返回消息页即可看到效果。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: context.textTertiary)),
            ],
          );
        },
      ),
    );
  }

  /// 白色圆角卡容器（与其他设置页一致：1px 灰线 + 圆角 20 + 轻阴影）
  Widget _card(List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: context.borderColor),
          boxShadow: AppTheme.cardShadow,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(children: children),
      );

  Widget _option({
    required IconData icon,
    required String title,
    required String subtitle,
    required String value,
  }) {
    final on = _style == value;
    return InkWell(
      onTap: () => _pick(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppTheme.primaryColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              on ? FontWeight.w600 : FontWeight.normal,
                          color: context.textPrimary)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12, color: context.textTertiary)),
                ],
              ),
            ),
            SizedBox(
              width: 24,
              child: on
                  ? Icon(Icons.check_rounded,
                      size: 20, color: AppTheme.primaryColor)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
