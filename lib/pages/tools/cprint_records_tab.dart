import 'package:flutter/material.dart';

import '../../services/campus/cprint_client.dart';
import '../../services/campus/cprint_models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';
import '../../widgets/state_views.dart';
import 'cprint_shared.dart';

/// 云打印 · 「使用记录」页签（打印/扫描/复印花了多少钱）。
///
/// 对应网页版 `footprint.html`。网页版有三个 tab（打印/扫描/复印）+
/// 两个日期框 + 搜索按钮 + 分页，手机上照抄会有三层选择器。
/// 这里压缩成：一行三个类型胶囊 + 一行「最近 30 天 / 全部时间」的时间范围，
/// 默认只看最近 30 天（学校的记录里大多数是这几天的事）。
class CprintRecordsTab extends StatefulWidget {
  const CprintRecordsTab({
    super.key,
    required this.authed,
    required this.onNeedAuth,
  });

  final bool authed;
  final VoidCallback onNeedAuth;

  @override
  State<CprintRecordsTab> createState() => _CprintRecordsTabState();
}

class _CprintRecordsTabState extends State<CprintRecordsTab>
    with AutomaticKeepAliveClientMixin {
  static const _types = [
    (1, '打印记录'),
    (4, '扫描记录'),
    (2, '复印记录'),
  ];

  int _type = 1;
  int _rangeDays = 30; // 0 = 全部时间
  List<CprintRecord> _items = const [];
  int _pageNo = 1;
  int _totalPage = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

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
  void didUpdateWidget(covariant CprintRecordsTab old) {
    super.didUpdateWidget(old);
    if (widget.authed && !old.authed) _load();
  }

  String _fmt(int y, int m, int d) =>
      '$y${m.toString().padLeft(2, '0')}${d.toString().padLeft(2, '0')}';

  Future<void> _load({bool more = false}) async {
    if (!mounted) return;
    if (more) {
      if (_loadingMore || _pageNo >= _totalPage) return;
      setState(() => _loadingMore = true);
    } else {
      setState(() {
        _loading = _items.isEmpty;
        _error = null;
        _pageNo = 1;
      });
    }
    final now = DateTime.now();
    // 日期按站点的规矩传纯数字 yyyyMMdd；空串 = 不限制。
    final end = _rangeDays == 0 ? '' : _fmt(now.year, now.month, now.day);
    final from = now.subtract(Duration(days: _rangeDays));
    final begin = _rangeDays == 0 ? '' : _fmt(from.year, from.month, from.day);
    final r = await CprintClient.records(
      type: _type,
      begin: begin,
      end: end,
      pageNo: more ? _pageNo + 1 : 1,
      rowCount: 20,
    );
    if (!mounted) return;
    if (r.needReauth) {
      setState(() {
        _loading = false;
        _loadingMore = false;
      });
      widget.onNeedAuth();
      return;
    }
    setState(() {
      _loading = false;
      _loadingMore = false;
      if (r.ok) {
        _error = null;
        _pageNo = r.pageNo;
        _totalPage = r.totalPage;
        _items = more ? [..._items, ...r.items] : r.items;
      } else {
        _error = r.message.isEmpty ? '读不到使用记录，请稍后重试。' : r.message;
        if (!more) _items = const [];
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!widget.authed) {
      return CprintNeedAuthView(
        message: '登录后才能看到自己的消费记录。',
        onLogin: () async => widget.onNeedAuth(),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            children: [
              Row(
                children: [
                  for (final t in _types) ...[
                    ChoiceChip(
                      label: Text(t.$2, style: const TextStyle(fontSize: 13)),
                      selected: _type == t.$1,
                      onSelected: (_) {
                        if (_type == t.$1) return;
                        setState(() {
                          _type = t.$1;
                          _items = const [];
                        });
                        _load();
                      },
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final r in [(30, '最近 30 天'), (0, '全部时间')]) ...[
                    ChoiceChip(
                      label: Text(r.$2, style: const TextStyle(fontSize: 12)),
                      selected: _rangeDays == r.$1,
                      onSelected: (_) {
                        if (_rangeDays == r.$1) return;
                        setState(() {
                          _rangeDays = r.$1;
                          _items = const [];
                        });
                        _load();
                      },
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_loading) return cprintLoading();
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: 340, child: ErrorState(message: _error!, onRetry: _load)),
        ],
      );
    }
    if (_items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(
            height: 340,
            child: EmptyState(
              message: '这段时间没有记录',
              hint: '换成「全部时间」看看，或者换个类型。',
              icon: Icons.receipt_long_outlined,
            ),
          ),
        ],
      );
    }
    final money = _items.fold<double>(0, (sum, e) => sum + e.moneyYuan);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        itemCount: _items.length + 2,
        separatorBuilder: (_, i) => SizedBox(height: i == 0 ? 10 : 8),
        itemBuilder: (_, i) {
          if (i == 0) {
            return Row(
              children: [
                Expanded(
                  child: Text(
                    '本页 ${_items.length} 条 · 合计 ${money.toStringAsFixed(2)} 元',
                    style: TextStyle(
                      fontSize: AppTheme.fontSmall,
                      color: context.textTertiary,
                    ),
                  ),
                ),
                if (_pageNo < _totalPage)
                  Text(
                    '第 $_pageNo / $_totalPage 页',
                    style: TextStyle(
                      fontSize: AppTheme.fontSmall,
                      color: context.textTertiary,
                    ),
                  ),
              ],
            );
          }
          if (i == _items.length + 1) {
            if (_pageNo >= _totalPage) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Center(
                child: _loadingMore
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : TextButton(
                        onPressed: () => _load(more: true),
                        child: const Text('加载更多'),
                      ),
              ),
            );
          }
          return _recordCard(_items[i - 1]);
        },
      ),
    );
  }

  Widget _recordCard(CprintRecord r) {
    return AppCard(
      radius: AppTheme.radiusMd,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '${r.dateLabel} ${r.timeLabel}',
                      style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        fontWeight: FontWeight.w500,
                        color: context.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (r.paperLabel.isNotEmpty)
                      cprintPill(r.paperLabel, context.textSecondary),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  '${r.pages} 页 · ${r.settleLabel}',
                  style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    color: context.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          Text(
            r.moneyLabel,
            style: TextStyle(
              fontSize: AppTheme.fontBody,
              fontWeight: FontWeight.w600,
              color: context.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
