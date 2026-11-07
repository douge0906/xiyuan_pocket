import 'package:flutter/material.dart';
import '../app.dart';
import '../models/tool_model.dart';
import '../widgets/service_tile.dart';
import '../services/current_tab.dart';
import '../services/dorm_service.dart';
import '../services/tool_navigator.dart';
import 'balance_detail_pages.dart';
import '../services/service_catalog.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/balance_cards.dart';
import 'service_settings_page.dart';

/// 服务页：顶部居中标题，竖列卡片展示校园服务。
///
/// ⚠️ 这里仅保留**客户端能独立完成**的服务（服务清单见 service_catalog.dart）：
///    成绩查询 / 考试安排（需先登录统一认证）、无锡学院校历、我的教材、校园地图。
///    食堂速览、试卷库、自动推送、建议反馈都依赖服务端，已移除。
///
/// v1.9.0：右上角新增**服务管理**入口 —— 可逐项开关服务的显示 / 隐藏，
///         设置即时保存，返回本页立即生效。
class ToolboxPage extends StatefulWidget {
  const ToolboxPage({super.key});

  @override
  State<ToolboxPage> createState() => _ToolboxPageState();
}

class _ToolboxPageState extends State<ToolboxPage> {
  /// 被用户隐藏的服务 id（来自服务管理页）。
  List<String> _hidden = [];

  @override
  void initState() {
    super.initState();
    _loadHidden();
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
    // `DormService.loadCardCache()` 直接返回 `double?`（余额本身），
    // 不是带 savedAt 的缓存对象 —— 带时间戳的那份在
    // `StorageService.loadCardBalanceCache()`，组件显示的是它。
    final balance = await DormService.loadCardCache();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CardBalancePage(balance: balance),
      ),
    );
  }

  /// 用户拖出来的服务顺序（2026-11-03）。空 = 从未排过，按 mainServices 原序。
  List<String> _order = [];

  Future<void> _loadHidden() async {
    final hidden = await StorageService.loadHiddenServices();
    final order = await StorageService.loadServiceOrder();
    if (!mounted) return;
    setState(() {
      _hidden = hidden;
      _order = order;
    });
  }

  /// 按用户顺序排好的全量服务（与服务管理页同一套合并规则）。
  List<ToolModel> get _sortedTools {
    if (_order.isEmpty) return mainServices;
    final byId = {for (final t in mainServices) t.id: t};
    final merged = <ToolModel>[];
    for (final id in _order) {
      final t = byId.remove(id);
      if (t != null) merged.add(t);
    }
    merged.addAll(mainServices.where((t) => byId.containsKey(t.id)));
    return merged;
  }

  /// 可见服务（服务清单唯一数据源见 service_catalog.dart）。
  List<ToolModel> get _visibleTools =>
      _sortedTools.where((t) => !_hidden.contains(t.id)).toList();

  /// 打开服务管理页；返回后重读配置（页内已即时保存，这里只需刷新列表）。
  Future<void> _openServiceSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ServiceSettingsPage(hidden: _hidden),
      ),
    );
    await _loadHidden();
  }

  @override
  Widget build(BuildContext context) {
    final tools = _visibleTools;
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
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), // v1.7.1 统一页面边距：原 18
                itemCount: tools.isEmpty ? 2 : tools.length + 1,
                itemBuilder: (context, index) {
                  // 第 0 项：一卡通 / 电费余额（由「我的」页移到这里，查看更顺手）
                  if (index == 0) {
                    return const Padding(
                      padding: EdgeInsets.only(bottom: 14),
                      child: BalanceCardsSection(),
                    );
                  }
                  // 全部服务被隐藏时的空态（有明确出路，不是死胡同）
                  if (tools.isEmpty) return _emptyState();
                  final tool = tools[index - 1];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ServiceTile(
                      tool: tool,
                      onTap: () => _onTap(context, tool),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: Column(
        children: [
          Icon(Icons.visibility_off_outlined,
              size: 40, color: context.textTertiary),
          const SizedBox(height: 12),
          Text('所有服务已隐藏',
              style: TextStyle(fontSize: AppTheme.fontTitle, color: context.textSecondary)),
          const SizedBox(height: 6),
          Text('点右上角设置图标可重新开启',
              style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
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
    );
  }

  Future<void> _onTap(BuildContext context, ToolModel tool) async {
    // open 内部会先过「登录闸门」：未登录则下方弹横条并中止跳转
    await ToolNavigator.open(context, tool.id, isCloud: tool.isCloud);
  }
}
