import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/message_repository.dart';
import '../services/message_source.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';

/// 消息设置（独立页面）。
///
/// 入口：消息页右上角齿轮 → push 到本页。
/// 三项设置**都是一行**，点开是**居中弹窗**（项目死律：不用底部弹层）：
/// * 每次进入自动更新 —— 进消息页要不要联网查新（开关，就地拨）
/// * 栏目样式 —— 纯白列表 / 圆角卡片，选完立即生效并持久化
/// * 最多同步条数 —— 每个栏目最多保留并显示多少条
class MessageSettingsPage extends StatefulWidget {
  /// 消息仓库。用于「调大条数后真的重新抓一遍」——
  /// 不传也能用，只是改了条数要等下次进消息页才生效。
  final MessageRepository? repository;

  const MessageSettingsPage({super.key, this.repository});

  @override
  State<MessageSettingsPage> createState() => _MessageSettingsPageState();
}

class _MessageSettingsPageState extends State<MessageSettingsPage> {
  String _style = StorageService.kMessageStylePlain;
  int _count = StorageService.kMessageSyncCountDefault;
  bool _autoRefresh = StorageService.kMessageAutoRefreshDefault;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final style = await StorageService.loadMessageStyle();
    final count = await StorageService.loadMessageSyncCount();
    final auto = await StorageService.loadMessageAutoRefresh();
    if (!mounted) return;
    setState(() {
      _style = style;
      _count = count;
      _autoRefresh = auto;
      _loading = false;
    });
  }

  // ---------------- 每次进入自动更新 ----------------

  /// 拨开关。**只改行为，不动已存内容** —— 关掉不是清空档案，
  /// 只是下次进消息页不再联网；用户想立刻查新依然可以下拉刷新。
  Future<void> _toggleAutoRefresh(bool v) async {
    setState(() => _autoRefresh = v);
    final repo = widget.repository;
    if (repo == null) {
      await StorageService.saveMessageAutoRefresh(v);
      return;
    }
    // 仓库是会话内的真相：改它才会写存储，也才会被下次 setActive 读到。
    await repo.setAutoRefresh(v);
  }

  // ---------------- 栏目样式 ----------------

  Future<void> _pickStyle() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _StyleDialog(current: _style),
    );
    if (picked == null || picked == _style) return;
    setState(() => _style = picked); // 立即生效，不回读存储 → 选中态不闪
    await StorageService.saveMessageStyle(picked);
  }

  // ---------------- 最多同步条数 ----------------

  /// 改「最多同步条数」。
  ///
  /// 🔴 **改完自动回消息页并立刻开始加载** —— 进度条在那里，用户得看得见它动。
  /// 留在设置页的话，同步已经在后台跑，用户却对着一个静止的「同步中…」发呆，
  /// 只能猜到底有没有生效。
  Future<void> _pickSyncCount() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (_) => _SyncCountDialog(current: _count),
    );
    if (picked == null || picked == _count) return;

    final old = _count;
    setState(() => _count = picked);
    await StorageService.saveMessageSyncCount(picked);

    final repo = widget.repository;
    if (!mounted || repo == null) return;

    if (picked <= old) {
      // 调小：**不用联网**。展示条数由设置决定，档案里的多余部分被截掉即可
      // （用户已明确接受「调小会真的丢弃多出来的条目」）。
      for (final s in repo.registeredSources) {
        await repo.load(s.channel.id, mode: FetchMode.archive);
      }
      if (mounted) Navigator.of(context).maybePop();
      return;
    }

    // 调大：**必须真的重抓一遍**。否则就是原来的「把 3 页改成 20 页，
    // 回来一看还是 80 条」—— 全量入口在有档案时够不着，设置形同虚设。
    //
    // 🔴 不再弹 SnackBar：消息页底部那条更新条（「更新中 0/5 · 2s」+ 计时）
    // 已经在报同一件事，而且它就在底部，SnackBar 会**叠在它上面**把它压住。
    // 重复的信息 + 视觉打架，直接去掉。
    final navigator = Navigator.of(context);
    navigator.pop();
    // 不 await：抓上百条要好几秒，设置页没必要为此挂着一个转圈。
    unawaited(repo.refreshAll(mode: FetchMode.full));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('消息设置',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _card([
                  _switchRow(
                    icon: Icons.sync_rounded,
                    title: '每次进入自动更新',
                    subtitle: _autoRefresh
                        ? '进消息页时会联网查一次新内容'
                        : '只看本机已存内容，下拉刷新不受影响',
                    value: _autoRefresh,
                    onChanged: _toggleAutoRefresh,
                  ),
                  Divider(height: 1, color: context.borderColor),
                  _row(
                    icon: Icons.view_agenda_outlined,
                    title: '栏目样式',
                    subtitle: '列表外观，两套随时互换',
                    value: _style == StorageService.kMessageStyleCard
                        ? '圆角卡片'
                        : '纯白列表',
                    onTap: _pickStyle,
                  ),
                  Divider(height: 1, color: context.borderColor),
                  _row(
                    icon: Icons.download_rounded,
                    title: '最多同步条数',
                    subtitle: '每个栏目最多保留并显示多少条',
                    value: '$_count 条',
                    onTap: _pickSyncCount,
                  ),
                ]),
                const SizedBox(height: 14),
                Text(
                  '样式改动立即生效；调大条数会重新抓取一次（可能需要一小会儿）。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: context.textTertiary),
                ),
                const SizedBox(height: 6),
                Text(
                  '关闭「自动更新」不会清掉已经存下的内容。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: context.textTertiary),
                ),
              ],
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

  /// 一行设置：图标 + 标题/副标题 + 当前值 + 箭头（点开是居中弹窗）。
  Widget _row({
    required IconData icon,
    required String title,
    required String subtitle,
    required String value,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
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
                          fontWeight: FontWeight.w500,
                          color: context.textPrimary)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12, color: context.textTertiary)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(value,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: context.textSecondary)),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }
  /// 开关行：与 [_row] 同壳，但右侧是 Switch 而非「值 + 箭头」。
  ///
  /// 为什么不复用 [_row] 弹窗：开关只有两态，为它再弹一层窗是多余的一次点击。
  Widget _switchRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
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
                          fontWeight: FontWeight.w500,
                          color: context.textPrimary)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12, color: context.textTertiary)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Switch(
              // Flutter 3.24 只有 activeColor（更新的 SDK 才叫 activeThumbColor）。
              value: value,
              onChanged: onChanged,
              activeColor: AppTheme.primaryColor,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------- 居中弹窗 ----------------

/// 弹窗外壳：标题 + 右上角 ✕ + 内容。**所有弹窗都走它，保证长得一样。**
class _DialogShell extends StatelessWidget {
  final String title;
  final String? desc;
  final Widget child;

  const _DialogShell({required this.title, this.desc, required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Dialog(
      backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title,
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: context.textPrimary)),
                  ),
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    customBorder: const CircleBorder(),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.close_rounded,
                          size: 20, color: Colors.grey.shade500),
                    ),
                  ),
                ],
              ),
              if (desc != null) ...[
                const SizedBox(height: 4),
                Text(desc!,
                    style: TextStyle(
                        fontSize: 12.5, height: 1.4, color: Colors.grey.shade500)),
              ],
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// 栏目样式选择弹窗：点一项即生效并关闭。
class _StyleDialog extends StatelessWidget {
  final String current;

  const _StyleDialog({required this.current});

  @override
  Widget build(BuildContext context) {
    return _DialogShell(
      title: '栏目样式',
      desc: '两套随时互换，选完立即生效。',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _option(
            context,
            icon: Icons.view_agenda_outlined,
            title: '纯白列表',
            subtitle: '无卡片边框，行与行之间一条细线',
            value: StorageService.kMessageStylePlain,
          ),
          const SizedBox(height: 6),
          _option(
            context,
            icon: Icons.crop_square_rounded,
            title: '圆角卡片',
            subtitle: '每条消息一个白色圆角卡片，带阴影',
            value: StorageService.kMessageStyleCard,
          ),
        ],
      ),
    );
  }

  Widget _option(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String value,
  }) {
    final on = current == value;
    return InkWell(
      onTap: () => Navigator.of(context).pop(value),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: on ? AppTheme.primaryColor : context.borderColor,
          ),
        ),
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
                          fontWeight: on ? FontWeight.w600 : FontWeight.normal,
                          color: context.textPrimary)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style:
                          TextStyle(fontSize: 12, color: context.textTertiary)),
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

/// 最多同步条数弹窗：几个预设 + 一个自定义输入框。
class _SyncCountDialog extends StatefulWidget {
  final int current;

  const _SyncCountDialog({required this.current});

  @override
  State<_SyncCountDialog> createState() => _SyncCountDialogState();
}

class _SyncCountDialogState extends State<_SyncCountDialog> {
  late final TextEditingController _ctl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: '${widget.current}');
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _submit() {
    final n = int.tryParse(_ctl.text.trim());
    if (n == null) {
      setState(() => _error = '请输入数字');
      return;
    }
    // 越界就夹到范围内（不是悄悄回默认值 —— 那样用户会以为没生效）。
    final v = StorageService.normalizeMessageSyncCount(n);
    if (v != n) {
      setState(() {
        _error =
            '已调整到 ${StorageService.kMessageSyncCountMin}–${StorageService.kMessageSyncCountMax} 之间';
        _ctl.text = '$v';
      });
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return _DialogShell(
      title: '最多同步条数',
      desc: '每个栏目最多保留并显示这么多条。调大会重新抓取一次；'
          '调小会丢弃多出来的条目（连同它们的详情链接），不做恢复。',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in StorageService.kMessageSyncCountPresets)
                _preset(p),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _ctl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            style: TextStyle(fontSize: 14, color: context.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              labelText: '自定义条数',
              errorText: _error,
              helperText:
                  '${StorageService.kMessageSyncCountMin} – ${StorageService.kMessageSyncCountMax}',
              border: const OutlineInputBorder(),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text('确定'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _preset(int n) {
    final on = _ctl.text.trim() == '$n';
    return InkWell(
      onTap: () => setState(() {
        _ctl.text = '$n';
        _error = null;
      }),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: on ? AppTheme.primaryColor : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: on ? AppTheme.primaryColor : context.borderColor,
          ),
        ),
        child: Text(
          '$n 条',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: on ? FontWeight.w600 : FontWeight.w500,
            color: on ? Colors.white : Colors.grey.shade700,
          ),
        ),
      ),
    );
  }
}
