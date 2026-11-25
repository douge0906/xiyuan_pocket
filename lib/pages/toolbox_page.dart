import 'package:flutter/material.dart';

import '../app.dart';
import '../models/service_group.dart';
import '../models/tool_model.dart';
import '../services/current_tab.dart';
import '../services/dorm_service.dart';
import '../services/service_catalog.dart';
import '../services/storage_service.dart';
import '../services/tool_navigator.dart';
import '../services/tool_usage_storage.dart';
import '../theme/app_theme.dart';
import '../widgets/balance_cards.dart';
import '../widgets/service_entry.dart';
import 'balance_detail_pages.dart';
import 'service_settings_page.dart';

/// 服务页：顶部居中标题 + 按功能块分组的入口网格。
///
/// ## 2026-11-25 重做（用户实机反馈）
///
/// **问题**：服务从 5 个涨到 12 个之后，一整条竖列卡片滑起来找东西很累，
/// 每条长得一样、没有层次。用户原话是「功能块必须按照网页端分块，
/// 比如几个功能入口」。
///
/// **改法**（对齐网页端 fast-grid 的读法）：
/// 1. 按用途分成四块（教务与成绩 / 课程与学习 / 资料与工具 / 校园与生活），
///    每块自带标题 + 条数；
/// 2. 块内是**两列格子**，不再是整行卡片 —— 一屏能放 8 个；
/// 3. **收藏钉在最上面**（单独的「我的收藏」块），不参与分组；
/// 4. 排序支持两种模式：手动拖动（默认，老行为）/ 按使用次数。
///    收藏永远优先于两者 —— 收藏不是排序，是「钉住」。
class ToolboxPage extends StatefulWidget {
  const ToolboxPage({super.key});

  @override
  State<ToolboxPage> createState() => _ToolboxPageState();
}

class _ToolboxPageState extends State<ToolboxPage> {
  /// 被用户隐藏的服务 id（来自服务管理页）。
  List<String> _hidden = [];

  /// 用户拖出来的顺序（2026-11-03）。空 = 从未排过，按 mainServices 原序。
  List<String> _order = [];

  /// 收藏的服务 id（2026-11-25）。收藏项固定在最上面，不受排序模式影响。
  List<String> _favorites = [];

  /// 'manual' | 'usage'（2026-11-25）。
  String _sortMode = 'manual';

  /// 使用次数（只有 usage 模式才读，读一次缓存住）。
  Map<String, int> _counts = const {};

  @override
  void initState() {
    super.initState();
    _loadAll();
    // 2026-11-04：桌面「倒数日」组件点击 → route() 置位 → 切到本页 → 这里消费。
    // 必须挂在 CurrentTab 而不是 initState：App 启动会预热所有 Tab，
    // 预热阶段就把页面推出来，用户还没看到服务页就被弹一脸。
    _unsubEntered = CurrentTab.addListener(_onEntered);
  }

  void Function()? _unsubEntered;

  @override
  void dispose() {
    _unsubEntered?.call();
    super.dispose();
  }

  /// 用户真正切到服务页 → 消费桌面组件的一次性信号。
  ///
  /// 2026-11-05（用户 m24495 #2/#3）：从只有「倒数日」扩成三类 ——
  /// 倒数日 / 考试查询 / 一卡通详情。三条都用同一个 post-frame 通道，
  /// 优先级按 exam > card > countdown（同一次点击只会置一个）。
  void _onEntered(NavPageRef page) {
    if (page != NavPageRef.service || !mounted) return;
    final openExam = AppTabs.pendingOpenExam;
    final openCard = AppTabs.pendingOpenCard;
    final openCountdown = AppTabs.pendingOpenCountdown;
    if (!openExam && !openCard && !openCountdown) return;
    final slot = AppTabs.pendingCountdownSlot;
    AppTabs.pendingOpenExam = false;
    AppTabs.pendingOpenCard = false;
    AppTabs.pendingOpenCountdown = false;
    AppTabs.pendingCountdownSlot = -1;
    // 延后一帧：此刻正是 Tab 切换那一帧，直接 push 会和 setState 打架
    // （与课表页 _consumePendingSettings 同一处理）。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (openExam) {
        await ToolNavigator.open(context, 'exam_query');
        return;
      }
      if (openCard) {
        await _openCardDetail();
        return;
      }
      await ToolNavigator.open(context, 'countdown', arguments: slot);
    });
  }

  /// 桌面「校园卡」组件 → 卡片详情页。
  ///
  /// 余额从缓存读（组件显示的就是缓存值，两边必须一致）；
  /// 缓存为空也照样进详情页 —— 页内自己有一次刷新，比弹「请先登录」有用。
  Future<void> _openCardDetail() async {
    final balance = await DormService.loadCardCache();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CardBalancePage(balance: balance),
      ),
    );
  }

  Future<void> _loadAll() async {
    final hidden = await StorageService.loadHiddenServices();
    final order = await StorageService.loadServiceOrder();
    final favorites = await StorageService.loadFavoriteServices();
    final sortMode = await StorageService.loadServiceSortMode();
    final counts = sortMode == 'usage'
        ? await ToolUsageStorage.loadCounts()
        : const <String, int>{};
    if (!mounted) return;
    setState(() {
      _hidden = hidden;
      _order = order;
      _favorites = favorites;
      _sortMode = sortMode;
      _counts = counts;
    });
  }

  /// 按当前排序模式排好的全量服务。
  ///
  /// 顺序来源的优先级：**收藏**（单独一块，永远最上）→ 组内顺序。
  /// 组内顺序由 [_sortMode] 决定：手动模式按 `_order`，使用模式按次数降序
  /// （次数相同或没记录时回落到清单原序，保证稳定不乱跳）。
  List<ToolModel> get _sortedTools {
    final byId = {for (final t in mainServices) t.id: t};
    final manual = <ToolModel>[];
    for (final id in _order) {
      final t = byId.remove(id);
      if (t != null) manual.add(t);
    }
    manual.addAll(mainServices.where((t) => byId.containsKey(t.id)));

    if (_sortMode != 'usage') return manual;

    final indexed = <String, int>{
      for (var i = 0; i < manual.length; i++) manual[i].id: i
    };
    final sorted = List<ToolModel>.of(manual);
    sorted.sort((a, b) {
      final ca = _counts[a.id] ?? 0;
      final cb = _counts[b.id] ?? 0;
      if (ca != cb) return cb.compareTo(ca);
      return (indexed[a.id] ?? 0).compareTo(indexed[b.id] ?? 0);
    });
    return sorted;
  }

  /// 可见服务（服务清单唯一数据源见 service_catalog.dart）。
  List<ToolModel> get _visibleTools =>
      _sortedTools.where((t) => !_hidden.contains(t.id)).toList();

  /// 收藏且可见的服务（顺序沿用 [_sortedTools]，让排序模式也反映在里面）。
  List<ToolModel> get _favoriteTools =>
      _visibleTools.where((t) => _favorites.contains(t.id)).toList();

  /// 按分组切好的「非收藏」服务。
  Map<String, List<ToolModel>> get _grouped {
    final out = <String, List<ToolModel>>{
      for (final g in ServiceGroup.order) g: <ToolModel>[],
    };
    for (final t in _visibleTools) {
      if (_favorites.contains(t.id)) continue;
      final bucket = out[t.group];
      if (bucket != null) {
        bucket.add(t);
      } else {
        // 分组 id 写错（或新增服务忘了给 group）时兜到最后一组，
        // 不能静默丢掉 —— 丢了用户在服务页就找不到它了。
        out[ServiceGroup.campus]!.add(t);
      }
    }
    return out;
  }

  Future<void> _openServiceSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ServiceSettingsPage(
          hidden: _hidden,
          favorites: _favorites,
          sortMode: _sortMode,
        ),
      ),
    );
    await _loadAll();
  }

  Future<void> _toggleFavorite(String id) async {
    final next = List<String>.of(_favorites);
    if (next.contains(id)) {
      next.remove(id);
    } else {
      next.add(id);
    }
    setState(() => _favorites = next);
    await StorageService.saveFavoriteServices(next);
  }

  @override
  Widget build(BuildContext context) {
    final favorites = _favoriteTools;
    final grouped = _grouped;
    final anyVisible = _visibleTools.isNotEmpty;

    return Scaffold(
      backgroundColor: context.scaffoldColor,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 12),
            // 标题居中 + 右上角服务管理入口。
            // 用「等宽左占位 + Expanded(Center) + 图标」三栏，标题才真正居中。
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
              child: Row(
                children: [
                  const SizedBox(width: 48),
                  Expanded(
                    child: Center(
                      child: Text(
                        '服务',
                        style: TextStyle(
                          fontSize: AppTheme.fontDisplay,
                          fontWeight: FontWeight.bold,
                          color: context.textPrimary,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _openServiceSettings,
                    tooltip: '服务管理',
                    iconSize: 22,
                    icon: Icon(Icons.tune_rounded, color: context.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: !anyVisible
                  ? _emptyState()
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(bottom: 14),
                          child: BalanceCardsSection(),
                        ),
                        if (favorites.isNotEmpty) ...[
                          _groupHeader('我的收藏', null, favorites.length,
                              icon: Icons.star_rounded),
                          _grid(favorites),
                          const SizedBox(height: 18),
                        ],
                        for (var i = 0; i < ServiceGroup.order.length; i++)
                          if ((grouped[ServiceGroup.order[i]] ?? const <ToolModel>[])
                              .isNotEmpty) ...[
                            _groupHeader(
                              ServiceGroup.titleOf(ServiceGroup.order[i]),
                              ServiceGroup.hintOf(ServiceGroup.order[i]),
                              grouped[ServiceGroup.order[i]]!.length,
                              icon: ServiceGroup.iconOf(ServiceGroup.order[i]),
                            ),
                            _grid(grouped[ServiceGroup.order[i]]!),
                            if (i != ServiceGroup.order.length - 1)
                              const SizedBox(height: 18),
                          ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// 分组标题：图标 + 标题 + 条数，右侧可选说明。
  Widget _groupHeader(String title, String? hint, int count, {IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: context.textTertiary),
            const SizedBox(width: 6),
          ],
          Text(
            title,
            style: TextStyle(
              fontSize: AppTheme.fontSmall,
              fontWeight: FontWeight.w600,
              color: context.textSecondary,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(
                fontSize: AppTheme.fontCaption, color: context.textTertiary),
          ),
          if (hint != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hint,
                style: TextStyle(
                    fontSize: AppTheme.fontCaption, color: context.textTertiary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 两列网格。
  ///
  /// 用 Wrap 而不是 GridView：格子高度会随名称行数变化（「空教室查询」一行，
  /// 「锡院学生手册」可能两行），GridView 的 childAspectRatio 要么裁字要么留白边。
  Widget _grid(List<ToolModel> tools) {
    const gap = 10.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = (constraints.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final t in tools)
              SizedBox(
                width: w,
                child: ServiceEntry(
                  tool: t,
                  favorite: _favorites.contains(t.id),
                  onTap: () => _onTap(context, t),
                  // 长按钉住 / 取消钉住。为什么不用显式按钮：格子只有两列宽，
                  // 再放一颗星会把名称挤到两个字就换行；长按是这个 App 里
                  // 「我对这项有更多要求」的既有手势（课表卡片同款）。
                  onLongPress: () => _toggleFavorite(t.id),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _emptyState() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 24),
      children: [
        Icon(Icons.visibility_off_outlined, size: 40, color: context.textTertiary),
        const SizedBox(height: 12),
        Text(
          '所有服务已隐藏',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: AppTheme.fontTitle, color: context.textSecondary),
        ),
        const SizedBox(height: 6),
        Text(
          '点右上角设置图标可重新开启',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: AppTheme.fontSmall, color: context.textTertiary),
        ),
        const SizedBox(height: 16),
        Center(
          child: TextButton.icon(
            onPressed: _openServiceSettings,
            icon: const Icon(Icons.tune_rounded, size: 18),
            label: const Text('去设置'),
            style: TextButton.styleFrom(foregroundColor: AppTheme.primaryColor),
          ),
        ),
      ],
    );
  }

  Future<void> _onTap(BuildContext context, ToolModel tool) async {
    // open 内部会先过「登录闸门」：未登录则下方弹横条并中止跳转
    await ToolNavigator.open(context, tool.id, isCloud: tool.isCloud);
    // 打开过就重算一次：使用模式下列表不该在用户回来后还是老顺序。
    if (mounted && _sortMode == 'usage') {
      final counts = await ToolUsageStorage.loadCounts();
      if (mounted) setState(() => _counts = counts);
    }
  }
}
