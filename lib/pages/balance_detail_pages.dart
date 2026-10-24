import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/dorm_service.dart';
import '../services/elec_unit.dart';
import '../theme/app_theme.dart';

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
  int _page = 1;
  int _pages = 1;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final cached = await DormService.loadTurnoverCache();
    if (cached != null && mounted) {
      setState(() {
        _items
          ..clear()
          ..addAll(cached.items);
        _pages = cached.pages;
        _loading = false;
      });
    }
    await _fetch(refresh: cached == null);
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
          ..addAll(res.items);
      } else {
        _items.addAll(res.items);
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
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: RefreshIndicator(
        onRefresh: () => _fetch(refresh: true),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _balanceCard(context),
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 8),
              child: Row(
                children: [
                  Text('交易明细',
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary)),
                  const Spacer(),
                  if (_items.isNotEmpty)
                    Text(_total > _items.length ? '${_items.length}/$_total 条' : '共 ${_items.length} 条',
                        style: TextStyle(
                            fontSize: 11.5, color: context.textTertiary)),
                ],
              ),
            ),
            _historyCard(context),
            const SizedBox(height: 12),
            Text('校园网微弱情况下卡顿属于正常状态',
                style: TextStyle(
                    fontSize: 11.5, color: context.textTertiary)),
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
                        fontSize: 12.5, color: context.textTertiary)),
                const SizedBox(height: 8),
                Text(
                  widget.balance == null
                      ? '¥ --'
                      : '¥ ${widget.balance!.toStringAsFixed(2)}',
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
          FilledButton(
            onPressed: () => _rechargeCard(context),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF111111),
              foregroundColor: Colors.white,
              minimumSize: const Size(72, 36),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('充值', style: TextStyle(fontSize: 13.5)),
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
      return Container(
        height: 120,
        alignment: Alignment.center,
        decoration: base,
        child: Text(_failed ? '暂时无法获取' : '暂无交易记录',
            style: TextStyle(fontSize: 12.5, color: context.textTertiary)),
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
                  fontSize: 13,
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
            style: TextStyle(fontSize: 11.5, color: context.textTertiary)),
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
                  style: TextStyle(fontSize: 13.5, color: context.textPrimary),
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
                            fontSize: 10.5, color: context.textTertiary)),
                    if (_readablePlace(t.place).isNotEmpty) ...[
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(_readablePlace(t.place),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 10.5,
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
                    fontSize: 14.5,
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

  Future<void> _rechargeCard(BuildContext context) async {
    final url = await DormService.cardBagLoginUrl();
    if (url == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('需要连接校园网')));
      return;
    }
    await _openUrl(url);
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
  List<({DateTime time, double balance, double? kwh})> _points = const [];

  @override
  void initState() {
    super.initState();
    ElecUnitStore.load().then((_) {
      if (!mounted) return;
      setState(() => _showKwh = ElecUnitStore.unit.value == ElecUnit.kwh);
    });
    DormService.loadElecPoints(dorm: widget.dorm).then((v) {
      if (!mounted) return;
      setState(() => _points = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final value = _showKwh ? info?.kwh : info?.balance;
    final unit = _showKwh ? '度' : '元';

    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('电费余额',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${widget.dorm.buildingName} ${widget.dorm.room}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5, color: context.textTertiary),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: _recharge,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF111111),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(72, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child:
                          const Text('充值', style: TextStyle(fontSize: 13.5)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  value == null ? '--' : '${value.toStringAsFixed(2)} $unit',
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
                    _showKwh
                        ? '约 ¥ ${(info.balance ?? 0).toStringAsFixed(2)}'
                        : '剩余 ${(info.kwh ?? 0).toStringAsFixed(2)} 度',
                    style: TextStyle(
                        fontSize: 12.5, color: context.textTertiary),
                  ),
                ],
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
              style: TextStyle(fontSize: 11.5, color: context.textTertiary)),
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
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary)),
                const Spacer(),
                Text('共 ${all.length} 次',
                    style: TextStyle(
                        fontSize: 11.5, color: context.textTertiary)),
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
                  style: TextStyle(fontSize: 13, color: AppTheme.primaryColor),
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
    final b = widget.info?.balance;
    final k = widget.info?.kwh;
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
                  style: TextStyle(fontSize: 13, color: context.textPrimary),
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
                            fontSize: 10.5, color: context.textTertiary)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(deltaText,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: deltaColor)),
        ],
      ),
    );
  }

  Future<void> _recharge() async {
    final url = await DormService.rechargeUrlFor(widget.dorm.feeitemid);
    if (url == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('需要连接校园网')));
      return;
    }
    if (!mounted) return;
    await _openUrl(url);
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
                  style: TextStyle(fontSize: 14, color: context.textPrimary)),
              const Spacer(),
              Text(_showKwh ? '度' : '元',
                  style: TextStyle(fontSize: 13, color: context.textTertiary)),
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

Future<void> _openUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
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
    final pts = <Offset>[
      for (var i = 0; i < values.length; i++)
        Offset(i * dx, size.height - (values[i] - minV) / span * size.height),
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
          colors: [color.withOpacity(0.18), color.withOpacity(0.02)],
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
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary)),
              const Spacer(),
              Text('近 ${pts.length} 次',
                  style: TextStyle(
                      fontSize: 11.5, color: context.textTertiary)),
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
              Text('最低 ¥${minV.toStringAsFixed(2)}',
                  style: TextStyle(
                      fontSize: 11, color: context.textTertiary)),
              const Spacer(),
              Text('最高 ¥${maxV.toStringAsFixed(2)}',
                  style: TextStyle(
                      fontSize: 11, color: context.textTertiary)),
            ],
          ),
        ],
      ),
    );
  }
}
