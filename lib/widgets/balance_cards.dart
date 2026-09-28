import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_gate.dart';
import '../services/storage_service.dart';
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

  /// 缓存有效期：超过才后台静默刷新一次（期间仍展示旧值，不转圈）。
  static const Duration _ttl = Duration(minutes: 30);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    if (_loading || _refreshing) return;

    // 未登录就不用查了（融合门户需要统一认证）
    if (!await AuthGate.isLoggedIn()) {
      if (mounted) setState(() => _error = '登录后查看');
      return;
    }

    // 1) 先读本地缓存：避免每次进页面都重新走一遍门户登录
    if (!force && _balance == null) {
      final cached = await StorageService.loadCardBalanceCache();
      if (!mounted) return;
      if (cached != null) {
        setState(() {
          _balance = cached.balance;
          _error = null;
        });
        if (DateTime.now().difference(cached.savedAt) < _ttl) return;
      }
    }

    final hasValue = _balance != null;
    if (mounted) {
      setState(() {
        if (hasValue) {
          _refreshing = true; // 有值：后台静默刷新，不打扰
        } else {
          _loading = true; // 无值：显示「获取中…」
        }
        _error = null;
      });
    }

    try {
      final res = await ApiService.fetchCardBalance();
      final data = (res['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final value = data['balance'];
      final balance = value is num ? value.toDouble() : null;
      if (balance != null) await StorageService.saveCardBalanceCache(balance);
      if (!mounted) return;
      setState(() {
        // 这次没取到值就保留旧值
        _balance = balance ?? _balance;
        _error = _balance == null ? '暂无数据' : null;
        _loading = false;
        _refreshing = false;
      });
    } catch (_) {
      // 拉不到就拉倒 —— 只是展示项，不弹报错吓唬用户
      if (!mounted) return;
      setState(() {
        _error = '暂无数据';
        _loading = false;
        _refreshing = false;
      });
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
      onRefreshCard:
          (_loading || _refreshing) ? null : () => _load(force: true),
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
    required this.onRefreshCard,
  });

  final bool isDark;
  final double? cardBalance;
  final bool balanceLoading;
  final bool balanceRefreshing;
  final String? balanceError;

  /// 点击一卡通卡片时的刷新回调（不可刷新时传 null）。
  final VoidCallback? onRefreshCard;

  @override
  Widget build(BuildContext context) {
    final String cardValue;
    final String cardHint;
    if (cardBalance != null) {
      cardValue = '¥ ${cardBalance!.toStringAsFixed(2)}';
      cardHint = balanceRefreshing ? '更新中…' : '点击刷新';
    } else if (balanceLoading) {
      cardValue = '¥ --';
      cardHint = '获取中…';
    } else {
      cardValue = '¥ --';
      cardHint = balanceError ?? '待接入';
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
            onTap: onRefreshCard,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _BalanceCard(
            isDark: isDark,
            icon: Icons.bolt_rounded,
            label: '电费余额',
            color: const Color(0xFFF59E0B),
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
    this.onTap,
  });

  final bool isDark;
  final IconData icon;
  final String label;
  final Color color;
  final String value;
  final String hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Widget content = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(20),
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
                  borderRadius: BorderRadius.circular(9),
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
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: context.textPrimary,
              letterSpacing: 0.5,
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