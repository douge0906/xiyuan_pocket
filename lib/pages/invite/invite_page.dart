import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../providers/invite_provider.dart';
import '../../services/storage_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';
import '../../widgets/pressable.dart';

/// 邀请同学主页：我的邀请码 / 分享链接 / 邀请统计 / 脱敏名单 / 填码绑定。
///
/// 视觉与动效沿用现有 App：卡片外壳走 [AppCard]，可点元素走 [Pressable]
/// 按压回弹；页面入场用短时长淡入 + 轻微上滑，不引入新动画库。
class InvitePage extends ConsumerStatefulWidget {
  const InvitePage({super.key});

  @override
  ConsumerState<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends ConsumerState<InvitePage>
    with SingleTickerProviderStateMixin {
  final _codeController = TextEditingController();
  late final AnimationController _enterCtrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _enterCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _fade = CurvedAnimation(parent: _enterCtrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _enterCtrl, curve: Curves.easeOut));
    _enterCtrl.forward();
    _prefillPendingCode();
    // 再次进入本页时静默刷新一次（首次进入仍在加载，跳过避免重复请求）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!ref.read(inviteProvider).loading) {
        unawaited(ref.read(inviteProvider.notifier).reload());
      }
    });
  }

  @override
  void dispose() {
    _codeController.dispose();
    _enterCtrl.dispose();
    super.dispose();
  }

  Future<void> _prefillPendingCode() async {
    final pending = await StorageService.loadInvitePendingCode();
    if (pending != null && pending.isNotEmpty && mounted) {
      _codeController.text = pending;
    }
  }

  Future<void> _copy(String text, String label) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('复制失败，请长按文本手动复制')));
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$label已复制')));
  }

  String _shareText(InviteState state) {
    final url = ref.read(inviteProvider.notifier).shareUrl;
    const base = '我在用「掌上锡院」查课表、空教室和成绩，充值一卡通，一起来使用吧！：';
    final parts = <String>[base];
    if (url != null && url.isNotEmpty) parts.add(url);
    if (state.hasCode) parts.add('邀请码：${state.code}');
    return parts.join('\n');
  }

  Future<void> _share(InviteState state) async {
    await Share.share(_shareText(state));
  }

  Future<void> _bind() async {
    final code = _codeController.text.trim();
    await ref.read(inviteProvider.notifier).bind(code, 'manual_code');
    if (!mounted) return;
    // 绑定成功后清掉本地待回填码；失败保留便于重试。
    final ok = ref.read(inviteProvider).bindSuccess;
    if (ok) await StorageService.saveInvitePendingCode(null);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(inviteProvider);

    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(title: const Text('邀请同学')),
      body: state.loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => ref.read(inviteProvider.notifier).reload(),
              child: FadeTransition(
                opacity: _fade,
                child: SlideTransition(
                  position: _slide,
                  child: ListView(
                    // 内容不足一屏时也要能下拉，否则刷新手势会被吞掉。
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                    children: [
                      if (!state.available) ...[
                        _UnavailableCard(
                          activityClosed: state.configLoaded,
                          onRetry: () =>
                              ref.read(inviteProvider.notifier).reload(),
                        ),
                        const SizedBox(height: 12),
                      ] else ...[
                        _buildHero(state),
                        const SizedBox(height: 12),
                        _buildStats(state),
                        const SizedBox(height: 12),
                        _buildRelations(state),
                        const SizedBox(height: 12),
                      ],
                      // 活动关闭/网络异常时也保留填码入口：否则用户拿到码却
                      // 连输入框都看不到，只能反复下拉刷新。
                      _buildBindCard(state),
                      const SizedBox(height: 16),
                      _buildNotes(),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildHero(InviteState state) {
    return AppCard(
      radius: AppTheme.radiusLg,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: Icon(Icons.people_alt_rounded,
                    size: 24, color: AppTheme.primaryColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('邀请新同学',
                        style: TextStyle(
                            fontSize: AppTheme.fontTitle,
                            fontWeight: FontWeight.w600,
                            color: context.textPrimary)),
                    const SizedBox(height: 3),
                    Text('把课表工具分享给同班同学，填码立即生效',
                        style: TextStyle(
                            fontSize: AppTheme.fontSmall,
                            color: context.textTertiary)),
                    const SizedBox(height: 4),
                    Text('每成功邀请 1 人，资源中心每日下载额度 +10 次',
                        style: TextStyle(
                            fontSize: AppTheme.fontSmall,
                            color: AppTheme.primaryColor)),
                    const SizedBox(height: 2),
                    // 判据说清楚，省得同学填完码才发现「不算」——
                    // 圈定规则在服务端（api.invite_bind），这里只是把它讲成人话。
                    Text('只算注册 30 天内、且不在同一台手机上的新同学',
                        style: TextStyle(
                            fontSize: AppTheme.fontSmall,
                            color: context.textTertiary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (state.hasCode) ...[
            _buildCodeRow(state),
            const SizedBox(height: 10),
            _buildLinkRow(state),
          ] else
            Text('邀请信息暂时加载失败，下拉刷新重试',
                style: TextStyle(
                    fontSize: AppTheme.fontSmall, color: context.textTertiary)),
        ],
      ),
    );
  }

  Widget _buildCodeRow(InviteState state) {
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppTheme.fillLight,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: Text(
              state.code!,
              style: TextStyle(
                fontSize: AppTheme.fontHeading,
                fontWeight: FontWeight.bold,
                letterSpacing: 3,
                color: context.textPrimary,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Pressable(
          onTap: () => _copy(state.code!, '邀请码'),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: Text('复制',
                style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primaryColor)),
          ),
        ),
      ],
    );
  }

  Widget _buildLinkRow(InviteState state) {
    final url = ref.read(inviteProvider.notifier).shareUrl;
    if (url == null || url.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        Expanded(
          child: Text(
            url,
            style: TextStyle(
                fontSize: AppTheme.fontSmall, color: context.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 10),
        Pressable(
          // 用户明确要求：点「复制链接」时，剪贴板里要同时带上整段邀请文案，
          // 不能只复制一个裸 URL，否则同学粘贴出来只有链接、没有说明。
          onTap: () => _copy(_shareText(state), '邀请文案'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Text('复制链接',
                style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primaryColor)),
          ),
        ),
        Pressable(
          onTap: () => _share(state),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.share_outlined, size: 16, color: Colors.white),
                const SizedBox(width: 6),
                Text('分享',
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall,
                        fontWeight: FontWeight.w600,
                        color: Colors.white)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStats(InviteState state) {
    return Row(
      children: [
        Expanded(
          child: _StatCard(
            label: '已邀请',
            value: state.totalInvited,
            color: AppTheme.primaryColor,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatCard(
            label: '已激活',
            value: state.activatedCount,
            color: AppTheme.success,
          ),
        ),
      ],
    );
  }

  Widget _buildRelations(InviteState state) {
    return AppCard(
      radius: AppTheme.radiusLg,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('邀请记录',
              style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary)),
          const SizedBox(height: 10),
          if (state.relations.isEmpty)
            Text('还没有邀请记录，分享你的邀请码给同学吧',
                style: TextStyle(
                    fontSize: AppTheme.fontSmall, color: context.textTertiary))
          else
            ...state.relations.map(_relationRow),
        ],
      ),
    );
  }

  Widget _relationRow(InviteRelation r) {
    final (label, color) = switch (r.status) {
      'activated' => ('已激活', AppTheme.success),
      'pending' => ('待激活', AppTheme.warning),
      'invalid' => ('已失效', context.textTertiary),
      'revoked' => ('已撤销', context.textTertiary),
      _ => ('待激活', AppTheme.warning),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            ),
            child: Icon(Icons.person_outline_rounded, size: 18, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(r.label,
                style: TextStyle(
                    fontSize: AppTheme.fontBody, color: context.textPrimary)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    fontWeight: FontWeight.w600,
                    color: color)),
          ),
        ],
      ),
    );
  }

  Widget _buildBindCard(InviteState state) {
    return AppCard(
      radius: AppTheme.radiusLg,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('我有邀请码',
              style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary)),
          const SizedBox(height: 6),
          Text('填写同学发来的 8 位邀请码，立即激活生效',
              style: TextStyle(
                  fontSize: AppTheme.fontSmall, color: context.textTertiary)),
          const SizedBox(height: 12),
          TextField(
            controller: _codeController,
            textCapitalization: TextCapitalization.characters,
            maxLength: 8,
            decoration: InputDecoration(
              hintText: '输入 8 位邀请码',
              counterText: '',
              filled: true,
              fillColor: AppTheme.fillLight,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                borderSide: BorderSide(color: context.borderColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                borderSide: BorderSide(color: context.borderColor),
              ),
            ),
          ),
          if (state.bindMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              state.bindMessage!,
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                color: state.bindSuccess ? AppTheme.success : AppTheme.danger,
              ),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: FilledButton(
              onPressed: state.binding ? null : _bind,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                shape: RoundedRectangleBorder(
                  borderRadius: AppTheme.radiusMdAll,
                ),
              ),
              child: state.binding
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2))
                  : const Text('立即激活',
                      style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotes() {
    return Text(
      '邀请码填写后立即生效并计入邀请；邀请记录仅以脱敏标签展示。',
      style: TextStyle(
          fontSize: AppTheme.fontCaption, color: context.textTertiary),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      radius: AppTheme.radiusLg,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$value',
              style: TextStyle(
                  fontSize: AppTheme.fontDisplay,
                  fontWeight: FontWeight.bold,
                  color: color)),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                  fontSize: AppTheme.fontSmall, color: context.textTertiary)),
        ],
      ),
    );
  }
}

class _UnavailableCard extends StatelessWidget {
  const _UnavailableCard({required this.activityClosed, required this.onRetry});

  /// true = 服务端明确返回「活动未开放」；false = 配置/网络没拉到，原因未知。
  final bool activityClosed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final title = activityClosed ? '邀请活动暂未开放' : '暂时连不上邀请服务';
    final subtitle = activityClosed
        ? '可以先把邀请码填在下方，活动开放后会按规则生效'
        : '请检查网络后点「重试」；也可以先填写邀请码，恢复后自动生效';
    return AppCard(
      radius: AppTheme.radiusLg,
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Icon(Icons.card_giftcard_outlined,
              size: 40, color: context.textTertiary),
          const SizedBox(height: 12),
          Text(title,
              style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary)),
          const SizedBox(height: 6),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: AppTheme.fontSmall, color: context.textTertiary)),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: onRetry,
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
              shape: RoundedRectangleBorder(
                borderRadius: AppTheme.radiusMdAll,
              ),
            ),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
