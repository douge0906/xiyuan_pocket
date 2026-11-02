import 'dart:async';

import 'package:flutter/material.dart';

import '../pages/balance_detail_pages.dart';
import '../pages/dorm_dialog.dart';
import '../services/current_tab.dart';
import '../services/net_mode.dart';
import '../services/dorm_service.dart';
import '../services/elec_unit.dart';
import '../services/auth_gate.dart';
import '../services/widget_sync_service.dart';
import '../theme/app_theme.dart';
import 'app_card.dart';

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

class _BalanceCardsSectionState extends State<BalanceCardsSection>
    with WidgetsBindingObserver {
  double? _balance;
  bool _loading = false;
  bool _refreshing = false;
  String? _error;

  /// 内网走哪条路（校园网直连 / 校外网关 / 都不通）。null = 还在探。
  ///
  /// 2026-10-25：从「是否连着校园 WiFi」改为「内网接口能不能调到」——
  /// 校外经 WebVPN 也能查余额，用 WiFi 状态判断会把这种情况误判成离线。
  CampusNetMode? _mode;

  /// 内网可查（直连或走网关）。
  bool get _canQuery => _mode != null && _mode != CampusNetMode.offline;

  /// 宿舍与电费（宿舍未填写时卡片显示「填写宿舍号」）。
  DormInfo? _dorm;
  ElectricityInfo? _elec;
  bool _elecLoading = false;
  String? _elecError;
  bool _dormChecking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DormStore.current.addListener(_onDormChanged);
    // 用户真正切到服务页 → 此时刷新余额（预热阶段不联网，见 [_bootstrap]）。
    _unsubEntered = CurrentTab.addListener(_onEntered);
    _bootstrap();
  }

  /// 注销「用户进入」监听。
  void Function()? _unsubEntered;

  /// 用户真正进入服务页 → 不重复刷新（余额已在预热时加载完，
  /// 重复刷新会让数字滚动一次，观感上就是闪）。
  void _onEntered(NavPageRef page) {
    if (page != NavPageRef.service || !mounted) return;
  }

  /// 宿舍变了（用户在「我的」页改的）→ 立刻作废旧电费并查新房间。
  ///
  /// 旧实现只在 initState 读一次，改完宿舍首页毫无反应（2026-10-26 反馈）。
  void _onDormChanged() {
    final d = DormStore.current.value;
    if (!mounted || d?.display == _dorm?.display) return;
    _applyDorm(d);
  }

  Future<void> _applyDorm(DormInfo? d) async {
    // 先取新宿舍自己的缓存（按楼栋+房号分键，换房间不会串）
    final cached = d == null ? null : await DormService.loadElecCache(d);
    if (!mounted) return;
    setState(() {
      _dorm = d;
      _elec = cached; // 新房间的缓存（没有就是 null，不显示旧房间的数）
      _elecError = null;
    });
    if (d != null && _canQuery) await _loadElec();
  }

  /// 回前台：**不再自动刷新**（2026-10-30）。
  ///
  /// 之前每次回前台都会重新拉一卡通/电费 → 卡片上的数字反复变、
  /// 「更新中…」提示反复闪，切页面时特别干扰。
  /// 现在只在**首次进入 App** 与**用户手动点击**时刷新。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {}

  /// 一卡通和电费共用同一个平台会话，必须串行刷新，
  /// 否则一个请求清 token / 关会话会让另一个请求随机失败。
  Future<void> _refreshAll() async {
    if (!_canQuery) return;
    await _load();
    if (!mounted) return;
    await _loadElec();
  }

  /// 拉一卡通余额。先展示缓存（_bootstrap 里已读），成功后覆盖并写回缓存。
  Future<void> _load() async {
    if (_loading || _refreshing) return;

    if (!_canQuery) {
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
      // 失败先**重探网络**再重试：多半是刚从校外回到校园网（模式还停在网关），
      // 干等 1.2 秒解决不了问题，只会拖慢（2026-10-26）。
      if (res.balance == null && res.reason != '登录失败(密码)') {
        await NetMode.probe(force: true);
        if (!mounted) return;
        res = await DormService.fetchCardBalanceDetailed();
      }
      if (!mounted) return;
      if (res.balance != null) {
        await DormService.saveCardCache(res.balance!);
        unawaited(WidgetSyncService.syncCardWidget());
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
    // 1) **先读缓存出数**（毫秒级），单位偏好放到后面 ——
    //    否则首屏会先闪一下「--」再出数（2026-10-26 反馈）。
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

    // 3) 读显示单位（不影响数字能否显示）
    await ElecUnitStore.load();
    // 4) 探网（_loadDorm 只做变更检查）
    await _initNet();
    await _loadDorm();

    // 3) 内网可查（直连或网关）：拉新数据覆盖缓存。
    //    预热时就加载（各页间隔 400ms，不会与其他请求撞车），
    //    切到服务页时余额已是最新 → 数字不再「跳一下」。
    await _refreshAll();
  }

  /// 探一次内网路径（直连 / 网关 / 都不通），并订阅结果。
  ///
  /// 探测本身在 [NetMode] 里做且**只做一次**（App 启动时已探过就直接复用）；
  /// 这里额外挂上校园网变化监听：WiFi 断了/回来了会强制重探一次，
  /// 否则「从校外回到宿舍」这种切换要重启 App 才生效。
  Future<void> _initNet() async {
    // 进入页面必须重新确认「现在能不能走内网」：复用 App 启动时的旧结果
    // 会在刚连上校园网 / 刚切到校外时走错路径，表现为偶发自动登录失败。
    await NetMode.ensureFresh();
    if (!mounted) return;
    setState(() => _mode = NetMode.current);
    NetMode.notifier.removeListener(_onModeChanged);
    NetMode.notifier.addListener(_onModeChanged);
  }

  void _onModeChanged() {
    if (!mounted) return;
    final m = NetMode.current;
    if (m == _mode) return;
    setState(() => _mode = m);
    // 网络模式变化**不自动刷新**（2026-10-30）：避免卡片数字自己跳。
    // 需要时用户点卡片手动刷。
  }

  /// 校园网状态变了 → 强制重探一次内网路径（结果交给 [_onModeChanged] 处理）。
  @override
  void dispose() {
    _unsubEntered?.call();
    WidgetsBinding.instance.removeObserver(this);
    DormStore.current.removeListener(_onDormChanged);
    NetMode.notifier.removeListener(_onModeChanged);
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
      if (_canQuery) await _loadElec();
    } else {
      setState(() => _dorm = d ?? _dorm);
    }
  }

  /// 点击电费卡片：未连校园网 → 重新检测；没宿舍 → 弹填写；有宿舍 → 刷新。
  Future<void> _onElecTap() async {
    if (_elecLoading) return;
    if (!_canQuery) {
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
    // 详情页里可能点过「手动更新」—— 回来按缓存同步卡片，否则卡片还显示旧数
    if (!mounted) return;
    final cached = await DormService.loadElecCache(_dorm!);
    if (cached != null && mounted) setState(() => _elec = cached);
  }

  /// 两个宿舍是否同一间（楼栋 + 房号）。
  static bool _sameDorm(DormInfo? a, DormInfo? b) {
    if (a == null || b == null) return a == b;
    return a.buildingValue == b.buildingValue && a.room == b.room;
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
      // 同上：重探网络比干等有效
      await NetMode.probe(force: true);
      if (!mounted) return;
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
    // 🔴 丢弃过期结果：查询期间用户可能改了宿舍号（_dorm 已变），
    //    这时旧房间的余额不能写进 _elec（会显示成新房间的数据）。
    if (!_sameDorm(dorm, _dorm)) {
      setState(() => _elecLoading = false);
      return;
    }
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

  /// 手动刷新一卡通余额（用户点卡片上的刷新按钮时调用）。
  Future<void> _manualRefresh() async {
    if (_loading || _refreshing) return;
    await NetMode.ensureFresh();
    if (!mounted) return;
    if (_canQuery) {
      await _load();
      if (!mounted) return;
      await _loadElec();
    }
  }

  @override
  Widget build(BuildContext context) {
    return UserBalanceCards(
      isDark: Theme.of(context).brightness == Brightness.dark,
      cardBalance: _balance,
      balanceLoading: _loading,
      balanceRefreshing: _refreshing,
      balanceError: _error,
      campusOnline: _canQuery,
      probed: _mode != null,
      elec: _elec,
      elecLoading: _elecLoading,
      elecError: _elecError,
      dorm: _dorm,
      onRefreshCard: _manualRefresh,
      onDetailCard: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CardBalancePage(balance: _balance),
          ),
        );
        // 详情页里可能刚手动更新过余额 → 回读缓存同步卡片
        if (!mounted) return;
        final cached = await DormService.loadCardCache();
        if (cached != null && mounted) setState(() => _balance = cached);
      },
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
    required this.probed,
    required this.elec,
    required this.elecLoading,
    required this.elecError,
    required this.dorm,
    required this.onRefreshCard,
    required this.onDetailCard,
    required this.onElecTap,
  });

  final bool isDark;
  final double? cardBalance;
  final bool balanceLoading;
  final bool balanceRefreshing;
  final String? balanceError;

  final bool campusOnline;
  /// 是否已探完内网路径（false = 还在探，hint 留空）。
  final bool probed;
  final ElectricityInfo? elec;
  final bool elecLoading;
  final String? elecError;
  final DormInfo? dorm;

  /// 点击一卡通卡片上的「刷新」按钮（手动刷新）。
  final VoidCallback? onRefreshCard;

  /// 点击一卡通卡片主体 → 进入余额详情页。
  final VoidCallback? onDetailCard;

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
    // 有值就先显示值（**离线也显示缓存**），网络状态只影响提示文案。
    if (elec?.balance != null) {
      elecValue = '¥ ${elec!.balance!.toStringAsFixed(2)}';
      elecHint = elecLoading ? '更新中…' : (dorm?.display ?? '');
    } else if (!probed) {
      // 还没探完网络：显示「获取中」，别急着说未连接校园网
      elecHint = dorm == null ? '填写宿舍号' : '获取中…';
    } else if (dorm == null) {
      elecHint = '填写宿舍号';
    } else if (!campusOnline) {
      elecHint = '未连接校园网';
    } else if (elecLoading) {
      elecHint = '获取中…';
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
            numericValue: cardBalance,
            hint: cardHint,
            skeleton: balanceLoading && cardBalance == null,
            onTap: onDetailCard,
            onRefresh: onRefreshCard,
            refreshing: balanceRefreshing,
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
              // 只有「元」模式才走数字滚动：kwh 模式的字符串带「度」后缀，
              // 滚动组件只渲染数字会把单位吃掉。
              final numeric =
                  unit == ElecUnit.kwh ? null : elec?.balance;
              return _BalanceCard(
                isDark: isDark,
                icon: Icons.bolt_rounded,
                label: '电费余额',
                color: const Color(0xFFF59E0B),
                value: shown,
                numericValue: numeric,
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
    this.numericValue,
    this.hint = '待接入',
    this.skeleton = false,
    this.onTap,
    this.onRefresh,
    this.refreshing = false,
  });

  final bool isDark;
  final IconData icon;
  final String label;
  final Color color;
  final String value;

  /// 数值（用于数字滚动动效）；null = 没有数值，走纯文本。
  final double? numericValue;
  final String hint;

  /// 首次加载：显示灰条占位，避免「¥ --」闪一下
  final bool skeleton;
  final VoidCallback? onTap;

  /// 手动刷新按钮（可选）。
  final VoidCallback? onRefresh;

  /// 正在刷新（刷新按钮转圈）。
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final Widget content = AppCard(
      padding: const EdgeInsets.all(14),
      radius: AppTheme.radiusLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
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
                    fontSize: AppTheme.fontSmall,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.grey.shade300 : const Color(0xFF6B7280),
                  ),
                ),
              ),
              if (onRefresh != null)
                _RefreshDot(
                  onTap: onRefresh!,
                  spinning: refreshing,
                  color: color,
                )
              else
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
          else if (numericValue != null)
            // 数值刷新时走**数字滚动**：旧数向上滚出、新数从下方滚入。
            _RollingNumber(
              value: numericValue!,
              prefix: '¥ ',
              textStyle: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: context.textPrimary,
                letterSpacing: 0.5,
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
            style: TextStyle(fontSize: AppTheme.fontCaption, color: Colors.grey.shade500),
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
/// 卡片右上角的刷新小圆点：静止时显示 ↻，刷新中转圈。
class _RefreshDot extends StatefulWidget {
  const _RefreshDot({
    required this.onTap,
    required this.spinning,
    required this.color,
  });

  final VoidCallback onTap;
  final bool spinning;
  final Color color;

  @override
  State<_RefreshDot> createState() => _RefreshDotState();
}

class _RefreshDotState extends State<_RefreshDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.spinning) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant _RefreshDot old) {
    super.didUpdateWidget(old);
    if (widget.spinning && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.spinning && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.spinning
        ? RotationTransition(
            turns: _ctrl,
            child: Icon(Icons.sync_rounded, size: 15, color: widget.color),
          )
        : Icon(Icons.refresh_rounded, size: 15, color: Colors.grey.shade500);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.spinning ? null : widget.onTap,
      child: Padding(padding: const EdgeInsets.all(4), child: child),
    );
  }
}

/// 数字快速滚动：数值变化时，旧数字向上滚出、新数字从下方滚入。
///
/// 自己持有 [AnimationController]（不用 TweenAnimationBuilder）：
/// 需要知道「上一个值」才能做出前后两条数字交叠的滚动效果。
class _RollingNumber extends StatefulWidget {
  const _RollingNumber({
    required this.value,
    required this.textStyle,
    this.prefix = '',
  });

  final double value;
  final TextStyle textStyle;

  /// 货币符号等前缀（数字滚动组件只渲染数字，前缀必须单独带上）。
  final String prefix;

  @override
  State<_RollingNumber> createState() => _RollingNumberState();
}

class _RollingNumberState extends State<_RollingNumber>
    with SingleTickerProviderStateMixin {
  late double _from;
  late double _to;
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _from = widget.value;
    _to = widget.value;
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
      value: 1,
    );
    // ⚠️ 必须监听：动画控制器变化**不会**自动触发 build，
    //    不监听的话数字会一直停在旧值（滚动根本不动）。
    _ctrl.addListener(_onTick);
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _RollingNumber old) {
    super.didUpdateWidget(old);
    if ((widget.value - _to).abs() < 0.001) return;
    _from = _current;
    _to = widget.value;
    _ctrl.forward(from: 0);
  }

  /// 当前显示的数值（动画中间值）。
  double get _current {
    final t = Curves.easeOutCubic.transform(_ctrl.value);
    return _from + (_to - _from) * t;
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onTick);
    _ctrl.dispose();
    super.dispose();
  }

  String _fmt(double v) => '${widget.prefix}${v.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final style = widget.textStyle;
    if ((widget.value - _to).abs() < 0.001 && _ctrl.value >= 1) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(_fmt(widget.value), style: style),
      );
    }
    final t = Curves.easeOutCubic.transform(_ctrl.value);
    return ClipRect(
      child: SizedBox(
        height: 26,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            // 旧值向上滚出
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(0, -26 * t),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(_fmt(_from), style: style),
                ),
              ),
            ),
            // 新值从下方滚入
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(0, 26 * (1 - t)),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(_fmt(_to), style: style),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
