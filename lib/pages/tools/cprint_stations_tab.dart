import 'package:flutter/material.dart';

import '../../services/campus/cprint_client.dart';
import '../../services/campus/cprint_models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';
import '../../widgets/state_views.dart';
import 'cprint_shared.dart';

/// 云打印 · 「打印点」页签（哪台打印机在哪、现在能不能用）。
///
/// 对应网页版 `printDev.html`。网页版是四列表格（名称/纸张/功能/状态），
/// 手机上表格放不下，改成卡片：名称一行，纸张与功能一行胶囊，状态在右侧。
/// 顶部保留服务商切换（学校里通常只有一个，所以只有一个时不显示）。
class CprintStationsTab extends StatefulWidget {
  const CprintStationsTab({
    super.key,
    required this.authed,
    required this.onNeedAuth,
  });

  final bool authed;
  final VoidCallback onNeedAuth;

  @override
  State<CprintStationsTab> createState() => _CprintStationsTabState();
}

class _CprintStationsTabState extends State<CprintStationsTab>
    with AutomaticKeepAliveClientMixin {
  CprintStationResult? _data;
  bool _loading = true;
  String? _error;
  int _srvSn = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (widget.authed) {
      _load();
    } else {
      _loading = false;
    }
  }

  @override
  void didUpdateWidget(covariant CprintStationsTab old) {
    super.didUpdateWidget(old);
    if (widget.authed && !old.authed) _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = _data == null;
      _error = null;
    });
    final r = await CprintClient.stations();
    if (!mounted) return;
    if (r.needReauth) {
      setState(() => _loading = false);
      widget.onNeedAuth();
      return;
    }
    setState(() {
      _loading = false;
      if (r.ok) {
        _data = r;
        if (_srvSn == 0 && r.srvs.isNotEmpty) _srvSn = r.srvs.first.sn;
      } else {
        _error = r.message.isEmpty ? '读不到打印点，请稍后重试。' : r.message;
      }
    });
  }

  List<CprintSrv> get _srvs => _data?.srvs ?? const [];

  List<CprintStation> get _shown {
    final all = _data?.stations ?? const <CprintStation>[];
    if (_srvSn == 0) return all;
    return all.where((s) => s.devSn ~/ 1000 == _srvSn).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!widget.authed) {
      return CprintNeedAuthView(
        message: '登录后才能看到打印点的实时状态。',
        onLogin: () async => widget.onNeedAuth(),
      );
    }
    if (_loading) return cprintLoading();
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: 380, child: ErrorState(message: _error!, onRetry: _load)),
        ],
      );
    }
    final list = _shown;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (_srvs.length > 1) ...[
            _srvRow(),
            const SizedBox(height: 10),
          ],
          cprintHint(
            context,
            '状态是图书馆那边实时返回的。纸张指的是机器里装了什么纸，'
            '不是这次打印用什么纸。',
          ),
          const SizedBox(height: 10),
          if (list.isEmpty)
            const SizedBox(
              height: 320,
              child: EmptyState(
                message: '这组没有打印点',
                hint: '换上面的服务商看看，或者稍后下拉刷新。',
                icon: Icons.print_outlined,
              ),
            )
          else
            for (final s in list) ...[
              _stationCard(s),
              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }

  Widget _srvRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final s in _srvs) ...[
            ChoiceChip(
              label: Text(s.name, style: const TextStyle(fontSize: 13)),
              selected: _srvSn == s.sn,
              onSelected: (_) => setState(() => _srvSn = s.sn),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _stationCard(CprintStation s) {
    final (color, bg) = switch (s.stateFlag) {
      2 => (context.successColor, context.successColor),
      1 => (context.warningColor, context.warningColor),
      _ => (context.textTertiary, context.textTertiary),
    };
    return AppCard(
      radius: AppTheme.radiusMd,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.name.isEmpty ? '未命名打印点' : s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: bg.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  s.stateLabel,
                  style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 5,
            children: [
              if (s.paperLabel.isNotEmpty)
                cprintPill('纸张 ${s.paperLabel}', context.textSecondary),
              if (s.functionLabel.isNotEmpty)
                cprintPill(s.functionLabel, context.textSecondary),
            ],
          ),
        ],
      ),
    );
  }
}
