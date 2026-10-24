import 'package:flutter/material.dart';

import '../pages/balance_detail_pages.dart';
import '../pages/dorm_dialog.dart';
import '../services/campus_net_monitor.dart';
import '../services/campus_net_service.dart';
import '../services/dorm_service.dart';
import '../services/elec_unit.dart';
import '../services/auth_gate.dart';
import '../theme/app_theme.dart';

/// 一卡通 / 电费余额卡片区（**放在服务页顶部**）。
///
/// 自带「缓存优先 + 后台刷新」逻辑，外部不用管状态，直接 `BalanceCardsSection()`：
///   · 有缓存 → 立即展示；缓存新鲜就不请求，过期才后台静默刷新
///   · 无缓存 → 显示「获取中…」
///   · 未登录 → 提示先登录
/// 点一卡通卡片可强制刷新。
///
/// 数据由客户端**直连融合门户**获取（见 `LocalCampusService.fetchCardBalance`）。
class BalanceCardsSection extends StatefulWidget {
  const BalanceCardsSection({super.key});

  @override
  State<BalanceCardsSection> createState() => _BalanceCardsSectionState();
}

class _BalanceCardsSectionState extends State<BalanceCardsSection> {
  double? _balance;
  bool _loading = false;
  bool _refreshing = false;
  String? _error;

  /// 校园网状态（复用首页检测结果，没有才自己探一次）。
  CampusNetStatus? _net;

  /// 宿舍与电费（宿舍未填写时卡片显示「填写宿舍号」）。
  DormInfo? _dorm;
  ElectricityInfo? _elec;
  bool _elecLoading = false;
  String? _elecError;
  bool _dormChecking = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// 拉一卡通余额。先展示缓存（_bootstrap 里已读），成功后覆盖并写回缓存。
  Future<void> _load() async {
    if (_loading || _refreshing) return;

    if (_net != CampusNetStatus.online) {
      _error = '未连接校园网';
      if (mounted) setState(() {});
      return;
    }
    if (!await AuthGate.isLoggedIn()) {
      if (mounted) setState(() => _error = '登录后查看');
      return;
    }

    final hasValue = _balance != null;
    if (mounted) {
      setState(() {
        if (hasValue) {
          _refreshing = true;
        } else {
          _loading = true;
        }
        _error = null;
      });
    }

    try {
      var res = await DormService.fetchCardBalanceDetailed();
      // 弱网/临时失败：等 1.2 秒自动重试一次
      if (res.balance == null && res.reason != '登录失败') {
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        res = await DormService.fetchCardBalanceDetailed();
      }
      if (!mounted) return;
      if (res.balance != null) {
        await DormService.saveCardCache(res.balance!);
        if (!mounted) return;
        setState(() {
          _balance = res.balance;
          _error = null;
          _loading = false;
          _refreshing = false;
        });
      } else {
        setState(() {
          _error = res.reason ?? '暂不可用';
          _loading = false;
          _refreshing = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '暂不可用';
        _loading = false;
        _refreshing = false;
      });
    }
  }

  Future<void> _bootstrap() async {
    await ElecUnitStore.load();
    // 1) 一卡通缓存（与宿舍无关）
    final cachedBalance = await DormService.loadCardCache();
    // 2) 宿舍先于电费缓存：缓存按「楼栋+房号」区分
    _dorm = await DormStore.load();
    final cachedElec =
        _dorm == null ? null : await DormService.loadElecCache(_dorm!);
    if (!mounted) return;
    setState(() {
      _balance = cachedBalance ?? _balance;
      _elec = cachedElec ?? _elec;
      _loading = false;
    });

    // 3) 探网（_loadDorm 只做变更检查）
    await _initNet();
    await _loadDorm();

    // 3) 在校园网内：拉新数据覆盖缓存
    if (_net == CampusNetStatus.online) {
      await _load();
      await _loadElec();
    }
  }

  /// 订阅全局监控：重连后自动刷新，不再只探一次。
  Future<void> _initNet() async {
    final m = CampusNetMonitor.instance;
    _net = m.status.value;
    m.status.addListener(_onNetChanged);
    if (_net == CampusNetStatus.unknown) {
      await m.refresh();
      if (!mounted) return;
      setState(() => _net = m.status.value);
    }
  }

  void _onNetChanged() {
    final s = CampusNetMonitor.instance.status.value;
    if (!mounted || s == _net) return;
    setState(() => _net = s);
    if (s == CampusNetStatus.online) {
      _load();
      _loadElec();
    }
  }

  @override
  void dispose() {
    CampusNetMonitor.instance.status.removeListener(_onNetChanged);
    super.dispose();
  }

  Future<void> _loadDorm() async {
    if (_dormChecking) return;
    _dormChecking = true;
    final d = await DormStore.load();
    _dormChecking = false;
    if (!mounted) return;
    if (d != null && (_dorm?.display != d.display)) {
      // 换宿舍：旧电费立刻清掉，避免显示上一个房间的数
      setState(() {
        _dorm = d;
        _elec = null;
        _elecError = null;
      });
      if (_net == CampusNetStatus.online) await _loadElec();
    } else {
      setState(() => _dorm = d ?? _dorm);
    }
  }

  /// 点击电费卡片：未连校园网 → 重新检测；没宿舍 → 弹填写；有宿舍 → 刷新。
  Future<void> _onElecTap() async {
    if (_elecLoading) return;
    if (_net != CampusNetStatus.online) {
      await _initNet();
      return;
    }
    if (_dorm == null) {
      // 用户可能在「我的」页刚填过，先回读一次，避免又弹一遍
      final saved = await DormStore.load();
      if (saved != null) {
        if (!mounted) return;
        setState(() => _dorm = saved);
        await _loadElec();
        return;
      }
      if (!mounted) return;
      final d = await showDormDialog(context, current: null);
      if (d == null || !mounted) return;
      await DormStore.save(d);
      setState(() {
        _dorm = d;
        _elec = null; // 换房间后旧数据作废
      });
      await _loadElec();
      return;
    }
    await _loadElec();
  }

  /// 点电费卡片：没填宿舍先填，填了进详情页。
  Future<void> _openElectricity() async {
    if (_dorm == null) {
      await _onElecTap();
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ElectricityPage(info: _elec, dorm: _dorm!),
      ),
    );
  }

  Future<void> _loadElec() async {
    final dorm = _dorm;
    if (dorm == null || _elecLoading) return;
    setState(() {
      _elecLoading = true;
      _elecError = null;
    });
    var info = await DormService.query(dorm);
    if (info == null) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      info = await DormService.query(dorm);
    }
    if (info != null) {
      await DormService.saveElecCache(info, dorm);
      if (info.balance != null) {
        await DormService.saveElecPoint(info.balance!,
            kwh: info.kwh, dorm: dorm);
      }
    }
    if (!mounted) return;
    setState(() {
      _elecLoading = false;
      if (info != null) {
        _elec = info;
        _elecError = null;
      } else {
        _elecError = '暂不可用';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return UserBalanceCards(
      isDark: Theme.of(context).brightness == Brightness.dark,
      cardBalance: _balance,
      balanceLoading: _loading,
      balanceRefreshing: _refreshing,
      balanceError: _error,
      campusOnline: _net == CampusNetStatus.online,
      netStatus: _net,
      elec: _elec,
      elecLoading: _elecLoading,
      elecError: _elecError,
      dorm: _dorm,
      onRefreshCard: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CardBalancePage(balance: _balance),
        ),
      ),
      onElecTap: _openElectricity,
    );
  }
}

/// 顶部余额卡片行：一卡通余额 / 电费余额。
class UserBalanceCards extends StatelessWidget {
  const UserBalanceCards({
    super.key,
    required this.isDark,
    required this.cardBalance,
    required this.balanceLoading,
    required this.balanceRefreshing,
    required this.balanceError,
    required this.campusOnline,
    required this.netStatus,
    required this.elec,
    required this.elecLoading,
    required this.elecError,
    required this.dorm,
    required this.onRefreshCard,
    required this.onElecTap,
  });

  final bool isDark;
  final double? cardBalance;
  final bool balanceLoading;
  final bool balanceRefreshing;
  final String? balanceError;

  final bool campusOnline;
  final CampusNetStatus? netStatus;
  final ElectricityInfo? elec;
  final bool elecLoading;
  final String? elecError;
  final DormInfo? dorm;

  /// 点击一卡通卡片时的刷新回调（不可刷新时传 null）。
  final VoidCallback? onRefreshCard;

  /// 点击电费卡片（检测网络 / 填写宿舍 / 刷新）。
  final VoidCallback onElecTap;

  @override
  Widget build(BuildContext context) {
    final String cardValue;
    final String cardHint;
    // 一卡通：校园网内直连、校外走融合门户兜底，所以离线也能显示；
    // 小字在离线时明确说明「未连接校园网」。
    // 不再提供「点击刷新」，卡片本身进入详情页。
    if (cardBalance != null) {
      cardValue = '¥ ${cardBalance!.toStringAsFixed(2)}';
      cardHint = balanceRefreshing ? '更新中…' : '点击查看详情页';
    } else if (balanceLoading) {
      cardValue = '¥ --';
      cardHint = '获取中…';
    } else {
      cardValue = '¥ --';
      cardHint = balanceError ??
          (campusOnline ? '暂无数据' : '未连接校园网');
    }

    // 电费：必须先连校园网，再填宿舍号，才查得到。
    var elecValue = '¥ --';
    String elecHint;
    if (netStatus == null) {
      elecHint = '';
    } else if (!campusOnline) {
      elecHint = '未连接校园网';
    } else if (dorm == null) {
      elecHint = '填写宿舍号';
    } else if (elecLoading) {
      elecHint = '获取中…';
    } else if (elec?.balance != null) {
      elecValue = '¥ ${elec!.balance!.toStringAsFixed(2)}';
      elecHint = dorm!.display;
    } else {
      elecHint = elecError ?? '暂不可用';
    }
    return Row(
      children: [
        Expanded(
          child: _BalanceCard(
            isDark: isDark,
            icon: Icons.credit_card_rounded,
            label: '一卡通余额',
            color: const Color(0xFF3B82F6),
            value: cardValue,
            hint: cardHint,
            skeleton: balanceLoading && cardBalance == null,
            onTap: onRefreshCard,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ValueListenableBuilder<ElecUnit>(
            valueListenable: ElecUnitStore.unit,
            builder: (_, unit, __) {
              final shown = unit == ElecUnit.kwh
                  ? (elec?.kwh == null
                      ? '-- 度'
                      : '${elec!.kwh!.toStringAsFixed(2)} 度')
                  : elecValue;
              return _BalanceCard(
                isDark: isDark,
                icon: Icons.bolt_rounded,
                label: '电费余额',
                color: const Color(0xFFF59E0B),
                value: shown,
                hint: elecHint,
                skeleton: elecLoading && elec?.balance == null,
                onTap: onElecTap,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({
    required this.isDark,
    required this.icon,
    required this.label,
    required this.color,
    this.value = '¥ --',
    this.hint = '待接入',
    this.skeleton = false,
    this.onTap,
  });

  final bool isDark;
  final IconData icon;
  final String label;
  final Color color;
  final String value;
  final String hint;

  /// 首次加载：显示灰条占位，避免「¥ --」闪一下
  final bool skeleton;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Widget content = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: context.borderColor),
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: Icon(icon, size: 17, color: color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.grey.shade300 : const Color(0xFF6B7280),
                  ),
                ),
              ),
              Icon(Icons.chevron_right,
                  size: 16,
                  color: isDark ? Colors.grey.shade600 : Colors.grey.shade400),
            ],
          ),
          const SizedBox(height: 12),
          if (skeleton)
            Container(
              width: 88,
              height: 20,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF0F1F3),
                borderRadius: BorderRadius.circular(6),
              ),
            )
          else
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: context.textPrimary,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            hint,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
    if (onTap == null) return content;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: content,
    );
  }
}