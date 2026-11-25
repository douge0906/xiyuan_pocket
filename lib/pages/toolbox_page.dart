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
import '../widgets/service_tile.dart';
import 'balance_detail_pages.dart';
import 'service_settings_page.dart';

/// 服务页：顶部居中标题，竖列卡片展示校园服务。
///
/// ⚠️ 这里仅保留**客户端能独立完成**的服务（服务清单见 service_catalog.dart）。
///
/// 两种形态（2026-11-25 用户 m11197）：
/// - **单列平铺**（默认，跟历史版本一致）：一行一个服务，图标 + 名称 + 箭头。
/// - **按用途分组**：四块两列格子。这是「值得保留但应该让用户自己选」的形态，
///   所以开关放在服务管理页，默认关。
///
/// 收藏与排序对两种形态都生效：收藏钉在最上面；排序可选手动或按使用次数。
class ToolboxPage extends StatefulWidget {
  const ToolboxPage({super.key});

  @override
  State<ToolboxPage> createState() => _ToolboxPageState();
}

class _ToolboxPageState extends State<ToolboxPage> {
  /// 被用户隐藏的服务 id（来自服务管理页）。
  List<String> _hidden = [];

  /// 收藏的服务 id：钉在列表最上面。
  List<String> _favorites = [];

  /// 是否按用途分组（默认 false = 原样的单列平铺）。
  bool _grouped = false;

  /// 'manual' 用用户拖出来的 _order；'usage' 按使用次数。
  String _sortMode = 'manual';

  /// 使用次数（只在 'usage' 模式下读）。
  Map<String, int> _counts = const {};

  /// 用户拖出来的服务顺序（2026-11-03）。空 = 从未排过，按 mainServices 原序。
  List<String> _order = [];

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

  Future<void> _openCardDetail() async {
    final balance = await DormService.loadCardCache();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CardBalancePage(balance: balance)),
    );
  }

  Future<void> _loadAll() async {
    final hidden = await StorageService.loadHiddenServices();
    final order = await StorageService.loadServiceOrder();
    final favorites = await StorageService.loadFavoriteServices();
    final grouped = await StorageService.loadServicesGrouped();
    final sortMode = await StorageService.loadServiceSortMode();
    // 只有按使用次数排序时才去读计数，免得每次进页面都白读一遍 SP。
    final counts =
        sortMode == 'usage' ? await ToolUsageStorage.loadCounts() : const <String, int>{};
    if (!mounted) return;
    setState(() {
      _hidden = hidden;
      _order = order;
      _favorites = favorites;
      _grouped = grouped;
      _sortMode = sortMode;
      _counts = counts;
    });
  }

  /// 全量服务，按「用户顺序 → 使用次数 → 收藏置顶」三层排好。
  ///
  /// 注意收藏放在最后一步：它不是排序规则，是「钉住」——所以两种排序模式下
  /// 收藏都必须在最上面，且收藏内部保持前一层的相对顺序。
  List<ToolModel> get _sortedTools {
    var list = List<ToolModel>.of(mainServices);

    // ① 用户手拖的顺序（与服务管理页同一套合并规则）。
    if (_order.isNotEmpty) {
      final byId = <String, ToolModel>{for (final t in mainServices) t.id: t};
      final merged = <ToolModel>[];
      for (final id in _order) {
        final t = byId.remove(id);
        if (t != null) merged.add(t);
      }
      merged.addAll(mainServices.where((t) => byId.containsKey(t.id)));
      list = merged;
    }

    // ② 按使用次数：次数降序，同次数保持 ① 的顺序（稳定）。
    if (_sortMode == 'usage') {
      final indexed = list.indexed.toList();
      indexed.sort((a, b) {
        final ca = _counts[a.$2.id] ?? 0;
        final cb = _counts[b.$2.id] ?? 0;
        if (ca != cb) return cb.compareTo(ca);
        return a.$1.compareTo(b.$1);
      });
      list = [for (final item in indexed) item.$2];
    }

    // ③ 收藏置顶。
    if (_favorites.isNotEmpty) {
      final fav = <ToolModel>[];
      final rest = <ToolModel>[];
      for (final t in list) {
        (_favorites.contains(t.id) ? fav : rest).add(t);
      }
      list = [...fav, ...rest];
    }
    return list;
  }

  /// 可见服务（服务清单唯一数据源见 service_catalog.dart）。
  List<ToolModel> get _visibleTools =>
      _sortedTools.where((t) => !_hidden.contains(t.id)).toList();

  List<ToolModel> get _visibleFavorites =>
      _visibleTools.where((t) => _favorites.contains(t.id)).toList();

  /// 分组形态下按用途切桶；收藏单独一块，不重复出现在用途分组里。
  ///
  /// group 写错（比如新增服务忘了填）时兜到最后一组而不是丢弃 —— 丢了的话
  /// 用户在服务页就再也找不到它了。
  Map<String, List<ToolModel>> _groupOf(List<ToolModel> tools) {
    final out = <String, List<ToolModel>>{
      for (final g in ServiceGroup.order) g: <ToolModel>[],
    };
    for (final t in tools) {
      if (_favorites.contains(t.id)) continue;
      final bucket = out[t.group] ?? out[ServiceGroup.campus]!;
      bucket.add(t);
    }
    return out;
  }

  Future<void> _openServiceSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ServiceSettingsPage(
          hidden: _hidden,
          favorites: _favorites,
          grouped: _grouped,
          sortMode: _sortMode,
        ),
      ),
    );
    await _loadAll();
  }

  @override
  Widget build(BuildContext context) {
    final tools = _visibleTools;
    final favorites = _visibleFavorites;
    return Scaffold(
      // 🔴 2026-11-04 审查 P1：这里原来写死 `isDark ? scaffoldDark : 0xFFF5F6F8`。
      //    用户在「外观 → 背景色」里选了米黄 / 淡蓝 / 石墨 / 冷灰之后，首页、
      //    消息、课表、我的、以及全部设置子页都跟着变了，唯独「服务」页永远
      //    是那块灰 —— 切 Tab 时是一道明显的色带，看起来像设置没生效。
      //    `context.scaffoldColor` 会读 backgroundNotifier / backgroundDarkNotifier。
      backgroundColor: context.scaffoldColor,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 12),
            // 标题居中 + 右上角服务管理入口。
            // 用「等宽左占位 + Expanded(Center) + 图标」三栏，标题才真正居中（对齐「我的」页头部）；
            // Stack + Positioned 方案下 Stack 宽度会被标题文字撑成"文字宽"，图标看起来卡在中间。
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
              child: Row(
                children: [
                  const SizedBox(width: 48), // 与右侧图标等宽
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
              child: tools.isEmpty
                  ? _emptyScroll()
                  : _grouped
                      ? _groupedList(tools, favorites)
                      : _flatList(tools),
            ),
          ],
        ),
      ),
    );
  }

  /// 默认形态：单列平铺（历史版本的样子）。
  Widget _flatList(List<ToolModel> tools) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), // v1.7.1 统一页面边距：原 18
      itemCount: tools.length + 1,
      itemBuilder: (context, index) {
        // 第 0 项：一卡通 / 电费余额
        if (index == 0) {
          return const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: BalanceCardsSection(),
          );
        }
        final tool = tools[index - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ServiceTile(
            tool: tool,
            onTap: () => _onTap(context, tool),
          ),
        );
      },
    );
  }

  /// 分组形态：用户自己打开才走这里。四块两列格子。
  Widget _groupedList(List<ToolModel> tools, List<ToolModel> favorites) {
    final groups = _groupOf(tools);
    return ListView(
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
          const SizedBox(height: 16),
        ],
        for (final g in ServiceGroup.order)
          if ((groups[g] ?? const <ToolModel>[]).isNotEmpty) ...[
            _groupHeader(
              ServiceGroup.titleOf(g),
              ServiceGroup.hintOf(g),
              groups[g]!.length,
              icon: ServiceGroup.iconOf(g),
            ),
            _grid(groups[g]!),
            const SizedBox(height: 16),
          ],
      ],
    );
  }

  Widget _groupHeader(String title, String? hint, int count, {IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 2, right: 2),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: context.textTertiary),
            const SizedBox(width: 5),
          ],
          Text(
            title,
            style: TextStyle(
              fontSize: AppTheme.fontSmall,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: context.textSecondary,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(
              fontSize: AppTheme.fontCaption,
              color: context.textTertiary,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: context.textTertiary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 两列格子。用 Wrap 而不是 GridView：服务名可能是两行，
  /// childAspectRatio 固定高度会把字裁掉或留出难看的下边距。
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
                  onLongPress: () => _toggleFavorite(t.id),
                ),
              ),
          ],
        );
      },
    );
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

  /// 全部服务被隐藏时的空态：给明确出路，不是死胡同。
  Widget _emptyScroll() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 14),
          child: BalanceCardsSection(),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
          child: Column(
            children: [
              Icon(Icons.visibility_off_outlined,
                  size: 40, color: context.textTertiary),
              const SizedBox(height: 12),
              Text('所有服务已隐藏',
                  style: TextStyle(
                      fontSize: AppTheme.fontTitle, color: context.textSecondary)),
              const SizedBox(height: 6),
              Text('点右上角设置图标可重新开启',
                  style: TextStyle(
                      fontSize: AppTheme.fontSmall, color: context.textTertiary)),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: _openServiceSettings,
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: const Text('去设置'),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.primaryColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _onTap(BuildContext context, ToolModel tool) async {
    // open 内部会先过「登录闸门」：未登录则下方弹横条并中止跳转
    await ToolNavigator.open(context, tool.id, isCloud: tool.isCloud);
    // 按使用次数排序时，回来要把刚点过的这一下算进去。
    if (!mounted || _sortMode != 'usage') return;
    final counts = await ToolUsageStorage.loadCounts();
    if (!mounted) return;
    setState(() => _counts = counts);
  }
}
