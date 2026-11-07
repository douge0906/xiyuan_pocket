import 'package:flutter/material.dart';

import '../services/dorm_service.dart';
import '../services/elec_unit.dart';
import '../services/net_mode.dart';
import '../theme/app_theme.dart';
import '../widgets/empty_state_art.dart';
import '../widgets/card_spending_chart.dart';
import 'recharge_webview_page.dart';

/// 今天 / 昨天 / MM-DD。
String dayTagOf(DateTime t) {
  final now = DateTime.now();
  final diff = DateTime(now.year, now.month, now.day)
      .difference(DateTime(t.year, t.month, t.day))
      .inDays;
  if (diff == 0) return '今天';
  if (diff == 1) return '昨天';
  return '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';
}

/// `14:32`
String hmOf(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// 一卡通余额详情（2026-10-24）。
///
/// 余额卡片右侧内嵌「充值」按钮；交易明细直接铺在下方（不跳页）。
class CardBalancePage extends StatefulWidget {
  const CardBalancePage({super.key, required this.balance});

  final double? balance;

  @override
  State<CardBalancePage> createState() => _CardBalancePageState();
}

class _CardBalancePageState extends State<CardBalancePage> {
  static const int _pageSize = 20;
  /// 一次「查看更多」最多连取几页，省得反复点。
  static const int _moreBatch = 3;

  final List<CardTxn> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _failed = false;
  bool _moreFailed = false;
  bool _updating = false;
  bool _openingRecharge = false;

  /// 当前余额。**必须本地持有**：原先直接用 widget.balance，
  /// 而它只在构造时赋值一次 —— 手动更新后数字永远不会变（2026-10-26 修）。
  double? _balance;
  int _page = 1;
  int _pages = 1;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _balance = widget.balance;
    _init();
  }

  Future<void> _init() async {
    // 详情页也可能在切网后打开：先确认直连/网关路径，再拉流水。
    final ensureFresh = DormService.debugEnsureNetworkFresh ?? NetMode.ensureFresh;
    await ensureFresh();
    final cached = await DormService.loadTurnoverCache();
    if (cached != null && mounted) {
      setState(() {
        _items
          ..clear()
          ..addAll(_dedupe(cached.items));
        _page = cached.current;
        _pages = cached.pages;
        _loading = false;
      });
    }
    // 有缓存就原地刷新，保留列表并更新页码；没有缓存才走首屏加载态。
    // 缓存的 current 已在上面同步到 _page，避免随后请求下一页时再次追加首页。
    // 有缓存时它包含此前已加载的多页记录，必须把第一页当「刷新」而非
    // 普通请求处理；否则 refresh=false 且 page=1 会清空缓存并覆盖列表。
    await _fetch(refresh: true);
  }

  /// 返回是否成功；只刷新列表，不负责「加载更多」的按钮态。
  Future<bool> _fetch({bool refresh = false}) async {
    if (refresh) {
      setState(() {
        _loading = true;
        _failed = false;
        _moreFailed = false;
        _page = 1;
      });
    }
    final res = await DormService.fetchTurnover(page: _page, size: _pageSize);
    if (!mounted) return false;
    if (res == null) {
      setState(() {
        _loading = false;
        _loadingMore = false;
        _failed = true;
      });
      return false;
    }
    setState(() {
      _loading = false;
      _failed = false;
      _pages = res.pages;
      _total = res.total;
      if (refresh || _page == 1) {
        _items
          ..clear()
          ..addAll(_dedupe(res.items));
      } else {
        _items.addAll(_dedupe(res.items, base: _items));
      }
    });
    await DormService.saveTurnoverCache(CardTurnoverPage(
      items: List<CardTxn>.of(_items),
      total: res.total,
      current: _page,
      pages: _pages,
    ));
    return true;
  }

  /// 按「时间 + 摘要 + 地点 + 金额 + 收支方向」去重。
  ///
  /// 服务端分页参数用错时（`pageNum` 恒被忽略）每一页都是同样十条，
  /// 追加后就出现「交易明细重复前十条」。修了参数也不能只靠它 ——
  /// 两条真实流水在同一秒、同一台机器、同样金额是可能的，所以这里只
  /// 在**同一批次内与已加载列表**去重，不改变真实数据的相对顺序。
  static List<CardTxn> _dedupe(List<CardTxn> incoming, {List<CardTxn>? base}) {
    final seen = <String>{};
    for (final t in base ?? _emptyTxns) {
      seen.add(_txnKey(t));
    }
    final out = <CardTxn>[];
    for (final t in incoming) {
      if (seen.add(_txnKey(t))) out.add(t);
    }
    return out;
  }

  static const List<CardTxn> _emptyTxns = <CardTxn>[];

  static String _txnKey(CardTxn t) =>
      '${t.time}|${t.title}|${t.place}|'
      '${t.amountYuan.toStringAsFixed(2)}|${t.isIncome}';

  Future<void> _loadMore() async {
    if (_loadingMore || _page >= _pages) return;
    setState(() {
      _loadingMore = true;
      _moreFailed = false;
    });
    var ok = true;
    for (var i = 0; i < _moreBatch && _page < _pages; i++) {
      _page += 1;
      ok = await _fetch();
      if (!ok) {
        _page -= 1;
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _loadingMore = false;
      _moreFailed = !ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('一卡通余额',
            style: TextStyle(fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
      ),
      body: RefreshIndicator(
        onRefresh: () => _fetch(refresh: true),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _balanceCard(context),
            // 消费趋势（明细不足两天时组件自己隐藏，不占位）
            if (_items.isNotEmpty) ...[
              const SizedBox(height: 16),
              CardSpendingChart(items: _items),
            ],
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 8),
              child: Row(
                children: [
                  Text('交易明细',
                      style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary)),
                  const Spacer(),
                  if (_items.isNotEmpty)
                    Text(_total > _items.length ? '${_items.length}/$_total 条' : '共 ${_items.length} 条',
                        style: TextStyle(
                            fontSize: AppTheme.fontSmall, color: context.textTertiary)),
                ],
              ),
            ),
            _historyCard(context),
            const SizedBox(height: 12),
            Text('校园网微弱情况下卡顿属于正常状态',
                style: TextStyle(
                    fontSize: AppTheme.fontSmall, color: context.textTertiary)),
          ],
        ),
      ),
    );
  }

  Widget _balanceCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 14, 18),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('电子钱包余额',
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall, color: context.textTertiary)),
                const SizedBox(height: 8),
                Text(
                  _balance == null
                      ? '¥ --'
                      : '¥ ${_balance!.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: context.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                onPressed:
                    _openingRecharge ? null : () => _rechargeCard(context),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF111111),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(72, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(_openingRecharge ? '打开中…' : '充值',
                    style: const TextStyle(fontSize: AppTheme.fontBody)),
              ),
              const SizedBox(height: 8),
              manualUpdateButton(context, busy: _updating, onTap: _manualUpdate),
            ],
          ),
        ],
      ),
    );
  }

  Widget _historyCard(BuildContext context) {
    final base = BoxDecoration(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      border: Border.all(color: context.borderColor),
    );

    if (_loading) {
      return Container(
        height: 120,
        alignment: Alignment.center,
        decoration: base,
        child: const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_items.isEmpty) {
      // 空态也用手绘插画，与全 App 的空状态观感统一。
      return Container(
        decoration: base,
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: AppEmptyState(
          variant: _failed ? EmptyArtVariant.offline : EmptyArtVariant.wallet,
          title: _failed ? '暂时无法获取' : '暂无交易记录',
          subtitle: _failed ? '检查网络后重试' : '有过消费记录后会显示在这里',
          compact: true,
        ),
      );
    }

    final children = <Widget>[];
    for (var i = 0; i < _items.length; i++) {
      if (i > 0) {
        children.add(Divider(
            height: 1, indent: 16, endIndent: 16, color: context.borderColor));
      }
      children.add(_historyRow(context, _items[i]));
    }

    return Container(
      decoration: base,
      child: Column(children: [...children, _moreFooter(context)]),
    );
  }

  /// 底部：还有更多 → 按钮（带剩余条数 / 失败可重试）；到底 → 一行灰字。
  Widget _moreFooter(BuildContext context) {
    if (_page < _pages) {
      final remain = _total - _items.length;
      final String label;
      if (_loadingMore) {
        label = '加载中…';
      } else if (_moreFailed) {
        label = '加载失败，点击重试';
      } else if (remain > 0) {
        label = '查看更多（还有 $remain 条）';
      } else {
        label = '查看更多';
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(height: 1, color: context.borderColor),
          SizedBox(
            height: 44,
            child: TextButton(
              onPressed: _loadingMore ? null : _loadMore,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  color: _moreFailed
                      ? const Color(0xFFC0392B)
                      : AppTheme.primaryColor,
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (_items.length >= _pageSize) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text('没有更多了',
            style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
      );
    }
    return const SizedBox.shrink();
  }

  /// 今天 / 昨天 / 10-22（更早只显示月-日）。
  String _dayTag(String raw) {
    final t = DateTime.tryParse(raw);
    return t == null ? '' : dayTagOf(t);
  }

  Widget _historyRow(BuildContext context, CardTxn t) {
    final sign = t.isIncome ? '+' : '-';
    final color = t.isIncome ? const Color(0xFFC0392B) : context.textPrimary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.title.isEmpty ? (t.isIncome ? '充值' : '消费') : t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: AppTheme.fontBody, color: context.textPrimary),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(_dayTag(t.time),
                        style: TextStyle(
                            fontSize: 10, color: context.textTertiary)),
                    const SizedBox(width: 5),
                    Text(_shortTime(t.time),
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption, color: context.textTertiary)),
                    if (_readablePlace(t.place).isNotEmpty) ...[
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(_readablePlace(t.place),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: AppTheme.fontCaption,
                                color: context.textTertiary)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$sign${t.amountYuan.toStringAsFixed(2)}',
                style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                    color: color),
              ),
              if (t.balanceYuan != null) ...[
                const SizedBox(height: 1),
                Text('余额 ${t.balanceYuan!.toStringAsFixed(2)}',
                    style: TextStyle(
                        fontSize: 10, color: context.textTertiary)),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 只保留时间部分：`2026-10-24 12:10:53` → `12:10`。
  String _shortTime(String raw) {
    final i = raw.indexOf(' ');
    if (i < 0) return raw;
    final time = raw.substring(i + 1);
    return time.length >= 5 ? time.substring(0, 5) : time;
  }

  /// 地点可读化：已知机位前缀映射成地点名；纯机位号不展示。
  static const Map<String, String> _placeNames = {
    // '55': '第一食堂',  ← 需要真实对照表时在此补充
  };

  String _readablePlace(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '';
    final head = t.split('-').first;
    final name = _placeNames[head];
    if (name != null) return name;
    // 形如 55-028 的纯机位号：不展示，避免干扰
    if (RegExp(r'^\d+-\d+$').hasMatch(t)) return '';
    return t;
  }

  /// 手动更新：强制重探内网路径（校园网 / 校外网关）+ **重拉余额** + 重拉明细。
  ///
  /// 注意 [_fetch] 只刷交易明细、不碰余额 —— 余额要在这里单独查，
  /// 否则点了按钮只有列表在动、数字纹丝不动（2026-10-26 用户反馈）。
  Future<void> _manualUpdate() async {
    if (_updating) return;
    setState(() => _updating = true);
    try {
      // 先用当前网络模式查（通常 1~2 秒）；只有网络类失败才重探 ——
      // 无脑 probe(force) 每次要 2~6 秒，是「点更新像卡住」的主因。
      var res = await DormService.fetchCardBalanceDetailed().timeout(
        const Duration(seconds: 30),
        onTimeout: () => const CardQueryResult(reason: '更新超时，请稍后重试'),
      );
      if (res.balance == null && _isTransient(res.reason)) {
        await NetMode.probe(force: true);
        if (!mounted) return;
        res = await DormService.fetchCardBalanceDetailed().timeout(
          const Duration(seconds: 30),
          onTimeout: () => const CardQueryResult(reason: '更新超时，请稍后重试'),
        );
      }
      if (!mounted) return;
      if (res.balance != null) {
        await DormService.saveCardCache(res.balance!);
        if (!mounted) return;
        setState(() => _balance = res.balance);
      } else {
        // 静默失败最坑：明确告诉用户这次没拿到数
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.reason ?? '更新失败，请重试')),
        );
      }
      await _fetch(refresh: true)
          .timeout(const Duration(seconds: 30), onTimeout: () => false);
    } finally {
      // 超时路径也必须把指标复位，否则界面一直停在「更新中」
      if (mounted) {
        setState(() {
          _updating = false;
          _loading = false;
        });
      }
    }
  }

  Future<void> _rechargeCard(BuildContext context) async {
    if (_openingRecharge) return;
    setState(() => _openingRecharge = true);
    try {
      // 先确认当前路径，再取一张新的平台票。充值预热和余额刷新共用
      // DormService 的认证锁，不会互相顶掉 TGT / 会话。
      await NetMode.ensureFresh();
      final warmup = await DormService.cardBagLoginUrl();
      final url = DormService.cardBagRechargeUrl();
      if (!context.mounted) return;
      if (warmup == null || url == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(NetMode.current == CampusNetMode.offline
                ? '网络不可用，请连接校园网或检查网络后重试'
                : (DormService.lastLoginError.isEmpty
                    ? '充值页准备失败，请稍后重试'
                    : DormService.lastLoginError))));
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RechargeWebViewPage(
            url: url,
            warmupUrl: warmup,
            title: '一卡通充值',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _openingRecharge = false);
    }
  }
}

/// 电费详情：余额 + 剩余电量，支持「元 / 度」切换（先做展示切换）。
class ElectricityPage extends StatefulWidget {
  const ElectricityPage({super.key, required this.info, required this.dorm});

  final ElectricityInfo? info;
  final DormInfo dorm;

  @override
  State<ElectricityPage> createState() => _ElectricityPageState();
}

class _ElectricityPageState extends State<ElectricityPage> {
  bool _showKwh = false;
  bool _recordsExpanded = false;
  bool _updating = false;
  bool _openingRecharge = false;

  /// 当前展示的电费数据（手动更新会替换它，所以不能直接用 widget.info）。
  ElectricityInfo? _info;

  /// 当前宿舍。**可变**：用户可能在别的页改了宿舍，
  /// 直接用 `_dorm` 会一直查旧房间（2026-10-26 反馈「手动更新也没用」）。
  late DormInfo _dorm;
  List<({DateTime time, double balance, double? kwh})> _points = const [];

  @override
  void initState() {
    super.initState();
    _info = widget.info;
    _dorm = widget.dorm;
    ElecUnitStore.load().then((_) {
      if (!mounted) return;
      setState(() => _showKwh = ElecUnitStore.unit.value == ElecUnit.kwh);
    });
    DormService.loadElecPoints(dorm: _dorm).then((v) {
      if (!mounted) return;
      setState(() => _points = v);
    });
  }

  /// 手动更新：重探内网路径 → 重查电费 → 补一条查询记录 → 重读记录列表。
  Future<void> _manualUpdate() async {
    if (_updating) return;
    setState(() => _updating = true);
    try {
      // 先重读宿舍：用户可能刚在「我的」页改过，这里必须跟上
      final latest = await DormStore.load();
      if (latest != null && latest.display != _dorm.display) {
        if (!mounted) return;
        setState(() {
          _dorm = latest;
          _info = null; // 换房间后旧数据立即作废
        });
      }

      var fresh = await DormService.query(_dorm).timeout(
        const Duration(seconds: 30),
        onTimeout: () => null,
      );
      if (fresh == null) {
        // 可能是网络模式刚变（如从校外回到校园网），重探一次再试
        await NetMode.probe(force: true);
        fresh = await DormService.query(_dorm).timeout(
          const Duration(seconds: 30),
          onTimeout: () => null,
        );
      }
      if (fresh != null) {
        await DormService.saveElecCache(fresh, _dorm);
        if (fresh.balance != null) {
          await DormService.saveElecPoint(fresh.balance!,
              kwh: fresh.kwh, dorm: _dorm);
        }
      } else if (mounted) {
        // 静默失败最坑：这次没拿到数也要说一声
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(DormService.lastLoginError.isEmpty
                  ? '更新失败，请检查网络后重试'
                  : DormService.lastLoginError)),
        );
      }
      final pts = await DormService.loadElecPoints(dorm: _dorm);
      if (!mounted) return;
      setState(() {
        if (fresh != null) _info = fresh;
        _points = pts;
      });
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final value = _showKwh ? info?.kwh : info?.balance;
    final unit = _showKwh ? '度' : '元';

    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('电费余额',
            style: TextStyle(fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
              border: Border.all(color: context.borderColor),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_dorm.buildingName} ${_dorm.room}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: AppTheme.fontSmall, color: context.textTertiary),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        value == null
                            ? '--'
                            : '${value.toStringAsFixed(2)} $unit',
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: context.textPrimary,
                        ),
                      ),
                      if (info != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          // 449/450 片区**不下发电量**（只有金额），
                          // 不能拿 0 兜底——那会显示成「剩余 0.00 度」，纯误导。
                          _showKwh
                              ? (info.balance == null
                                  ? '暂无金额'
                                  : '约 ¥ ${info.balance!.toStringAsFixed(2)}')
                              : (info.kwh == null
                                  ? '该片区仅提供金额'
                                  : '剩余 ${info.kwh!.toStringAsFixed(2)} 度'),
                          style: TextStyle(
                              fontSize: AppTheme.fontSmall, color: context.textTertiary),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    FilledButton(
                      onPressed: _openingRecharge ? null : _recharge,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF111111),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(72, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: Text(_openingRecharge ? '打开中…' : '充值',
                          style: const TextStyle(fontSize: AppTheme.fontBody)),
                    ),
                    const SizedBox(height: 8),
                    manualUpdateButton(context,
                        busy: _updating, onTap: _manualUpdate),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _section(context, [
            _unitRow(context),
          ]),
          if (_points.length >= 2) ...[
            const SizedBox(height: 16),
            _trendCard(context),
          ],
          if (_points.isNotEmpty) ...[
            const SizedBox(height: 16),
            _recordsCard(context),
          ],
          const SizedBox(height: 12),
          Text('校园网微弱情况下卡顿属于正常状态',
              style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
        ],
      ),
    );
  }

  /// 查询记录：最近 8 条，可展开全部（最多 60 条）。
  Widget _recordsCard(BuildContext context) {
    final all = _records;
    if (all.isEmpty) return const SizedBox.shrink();
    final shown =
        _recordsExpanded || all.length <= 8 ? all : all.take(8).toList();

    final rows = <Widget>[];
    for (var i = 0; i < shown.length; i++) {
      if (i > 0) {
        rows.add(Divider(
            height: 1, indent: 16, endIndent: 16, color: context.borderColor));
      }
      rows.add(_recordRow(context, shown[i]));
    }

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
            child: Row(
              children: [
                Text('查询记录',
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary)),
                const Spacer(),
                Text('共 ${all.length} 次',
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall, color: context.textTertiary)),
              ],
            ),
          ),
          ...rows,
          if (all.length > 8) ...[
            Divider(height: 1, color: context.borderColor),
            SizedBox(
              height: 44,
              child: TextButton(
                onPressed: () =>
                    setState(() => _recordsExpanded = !_recordsExpanded),
                child: Text(
                  _recordsExpanded
                      ? '收起'
                      : '查看更多（还有 ${all.length - 8} 条）',
                  style: TextStyle(fontSize: AppTheme.fontSmall, color: AppTheme.primaryColor),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 度/元 换算比（本次查询的「剩余电量 ÷ 余额」）。
  ///
  /// 老快照只存了元、没存度数（度数字段是后来才加的），靠它把历史记录也换算成度，
  /// 否则切到「度」时老记录会整片退回元、看起来像没生效。
  double? get _kwhPerYuan {
    // 🔴 2026-11-04 审查 P1：这里原来读 `widget.info`，而 `_manualUpdate()`
    //    成功后会 `_info = fresh`（见本文件 `_manualUpdate` 的 setState）。
    //    于是用户进页面 → 手动更新拿到新「剩余电量/余额」→ 切到「度」时，
    //    历史记录仍按**进页面那一刻**的旧比率换算。学校电价调过
    //    （`defaultUnitPrice = 0.54` 就是兜底值），旧比率算出的度数会整段
    //    成比例偏差，且肉眼看不出是错的。必须跟 `_info` 走。
    final b = _info?.balance;
    final k = _info?.kwh;
    if (b == null || k == null || b <= 0 || k <= 0) return null;
    return k / b;
  }

  /// 按时间倒序，并算出相对上一次的变化量（单位跟随当前「元 / 度」设置）。
  List<_ElecRecord> get _records {
    final pts = _points;
    final useKwh = _showKwh;
    final rate = _kwhPerYuan;
    final out = <_ElecRecord>[];
    for (var i = 0; i < pts.length; i++) {
      // 优先用快照自带的度数；没有就按本次单价换算；都换不出来才退回元
      final curK = pts[i].kwh ?? (rate == null ? null : pts[i].balance * rate);
      final pk = i == 0 ? null : pts[i - 1].kwh;
      final prevK =
          pk ?? (rate == null || i == 0 ? null : pts[i - 1].balance * rate);
      // 首条没有「上一次」，只要当前有度数就按度显示；缺度数则整行退回元
      final canKwh = useKwh && curK != null && (i == 0 || prevK != null);
      double cur;
      double? prev;
      if (canKwh) {
        cur = curK;
        prev = i == 0 ? null : prevK;
      } else {
        cur = pts[i].balance;
        prev = i == 0 ? null : pts[i - 1].balance;
      }
      out.add(_ElecRecord(
        time: pts[i].time,
        value: cur,
        unit: canKwh ? '度' : '元',
        delta: prev == null ? null : cur - prev,
      ));
    }
    return out.reversed.toList();
  }

  Widget _recordRow(BuildContext context, _ElecRecord r) {
    final d = r.delta;
    final String deltaText;
    final Color deltaColor;
    if (d == null) {
      deltaText = '首次记录';
      deltaColor = context.textTertiary;
    } else if (d.abs() < 0.005) {
      deltaText = '持平';
      deltaColor = context.textTertiary;
    } else if (d > 0) {
      deltaText = '+${d.toStringAsFixed(2)}';
      deltaColor = const Color(0xFFC0392B);
    } else {
      deltaText = d.toStringAsFixed(2);
      deltaColor = context.textPrimary;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  r.unit == '度'
                      ? '${r.value.toStringAsFixed(2)} 度'
                      : '¥ ${r.value.toStringAsFixed(2)}',
                  style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textPrimary),
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    Text(dayTagOf(r.time),
                        style: TextStyle(
                            fontSize: 10, color: context.textTertiary)),
                    const SizedBox(width: 5),
                    Text(hmOf(r.time),
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption, color: context.textTertiary)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(deltaText,
              style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  fontWeight: FontWeight.w600,
                  color: deltaColor)),
        ],
      ),
    );
  }

  Future<void> _recharge() async {
    if (_openingRecharge) return;
    setState(() => _openingRecharge = true);
    try {
      // 与电费刷新/一卡通刷新共用认证锁，避免同时登录把票据顶掉。
      await NetMode.ensureFresh();
      final url = await DormService.rechargeUrlFor(_dorm.feeitemid);
      if (!mounted) return;
      if (url == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(NetMode.current == CampusNetMode.offline
                ? '网络不可用，请连接校园网或检查网络后重试'
                : (DormService.lastLoginError.isEmpty
                    ? '充值页准备失败，请稍后重试'
                    : DormService.lastLoginError))));
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RechargeWebViewPage(url: url, title: '电费充值'),
        ),
      );
    } finally {
      if (mounted) setState(() => _openingRecharge = false);
    }
  }

  /// 设置项：显示单位（元 / 度）。
  Widget _unitRow(BuildContext context) {
    return InkWell(
      onTap: () {
        final next = !_showKwh;
        setState(() => _showKwh = next);
        ElecUnitStore.set(next ? ElecUnit.kwh : ElecUnit.yuan);
      },
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(Icons.straighten_rounded,
                  size: 20, color: AppTheme.primaryColor),
              const SizedBox(width: 12),
              Text('显示单位',
                  style: TextStyle(fontSize: AppTheme.fontBody, color: context.textPrimary)),
              const Spacer(),
              Text(_showKwh ? '度' : '元',
                  style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: context.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _section(BuildContext context, List<Widget> children) {
  return Container(
    decoration: BoxDecoration(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      border: Border.all(color: context.borderColor),
    ),
    child: Column(children: children),
  );
}

/// 电费查询记录的一行（当时余额 + 相对上一次的变化量）。
class _ElecRecord {
  const _ElecRecord({
    required this.time,
    required this.value,
    required this.unit,
    this.delta,
  });

  final DateTime time;

  /// 当时的值：元或度，取决于 [unit]。
  final double value;
  final String unit;
  final double? delta;
}

/// 充值按钮下方的「手动更新」次要按钮（两个详情页共用）。
///
/// 描边样式，不抢充值的主视觉；更新中禁用并显示「更新中」。
Widget manualUpdateButton(
  BuildContext context, {
  required bool busy,
  required VoidCallback onTap,
}) {
  return SizedBox(
    width: 72,
    height: 32,
    child: OutlinedButton(
      onPressed: busy ? null : onTap,
      style: OutlinedButton.styleFrom(
        padding: EdgeInsets.zero,
        foregroundColor: AppTheme.primaryColor,
        side: BorderSide(color: context.borderColor),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Text(busy ? '更新中' : '手动更新',
          style: const TextStyle(fontSize: AppTheme.fontSmall)),
    ),
  );
}

/// 这类失败值得「重探网络后重试」；密码错、无卡账号等确定性问题重试没意义。
bool _isTransient(String? reason) {
  if (reason == null) return true;
  return reason.contains('网络') ||
      reason.contains('超时') ||
      reason.contains('查询失败') ||
      reason.contains('VPN');
}


/// 余额趋势卡（最近 30 个点）。
class _TrendCardPainter extends CustomPainter {
  _TrendCardPainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final minV = values.reduce((a, b) => a < b ? a : b);
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final span = (maxV - minV).abs() < 0.01 ? 1.0 : (maxV - minV);

    final dx = size.width / (values.length - 1);
    // 上下各留 6px：否则最高点落在 y=0，末点圆点被裁掉一半
    const padY = 6.0;
    final usableH = size.height - padY * 2;
    final pts = <Offset>[
      for (var i = 0; i < values.length; i++)
        Offset(i * dx, padY + usableH - (values[i] - minV) / span * usableH),
    ];

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }

    final fill = Path.from(path)
      ..lineTo(pts.last.dx, size.height)
      ..lineTo(pts.first.dx, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.18), color.withValues(alpha: 0.02)],
        ).createShader(Offset.zero & size),
    );

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );

    canvas.drawCircle(pts.last, 3.2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _TrendCardPainter old) =>
      old.values != values || old.color != color;
}

extension on _ElectricityPageState {
  String _md(DateTime d) => '${d.month}/${d.day}';

  Widget _trendCard(BuildContext context) {
    final pts = _points.length > 30
        ? _points.sublist(_points.length - 30)
        : _points;
    final values = [for (final p in pts) p.balance];
    final minV = values.reduce((a, b) => a < b ? a : b);
    final maxV = values.reduce((a, b) => a > b ? a : b);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('余额趋势',
                  style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary)),
              const Spacer(),
              Text('近 ${pts.length} 次',
                  style: TextStyle(
                      fontSize: AppTheme.fontSmall, color: context.textTertiary)),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 92,
            width: double.infinity,
            child: CustomPaint(
              painter: _TrendCardPainter(
                values: values,
                color: AppTheme.primaryColor,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('${_md(pts.first.time)} - ${_md(pts.last.time)}',
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption, color: context.textTertiary)),
              const Spacer(),
              Text(
                  '最低 ¥${minV.toStringAsFixed(2)} · 最高 ¥${maxV.toStringAsFixed(2)}',
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption, color: context.textTertiary)),
            ],
          ),
        ],
      ),
    );
  }
}
