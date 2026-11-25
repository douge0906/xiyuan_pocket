import 'package:flutter/material.dart';

import '../models/service_group.dart';
import '../models/tool_model.dart';
import '../services/service_catalog.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import 'user/user_cards.dart';

/// 服务管理页（v1.9.0，2026-11-03 加拖动排序，2026-11-25 加收藏与排序模式）。
///
/// UI 与「我的」页的框框规范保持一致（复用 [userCard]）：
/// 圆角 20 + 1px 灰线边框 + 行高统一、分割线左右贯通到卡片边缘。
///
/// 三件事都在这一页：
/// - **显示 / 隐藏**：关闭后该服务从服务页消失（功能与数据都保留）。
/// - **收藏**：点左侧星标。收藏项在服务页固定在最上面，不受排序模式影响。
/// - **排序**：两种模式二选一
///     · 手动（默认）：长按右侧手柄拖动；
///     · 按使用次数：最近用得多的排前面（收藏仍然钉在最上）。
///
/// 修改**即时保存**，返回服务页自动生效。
class ServiceSettingsPage extends StatefulWidget {
  const ServiceSettingsPage({
    super.key,
    required this.hidden,
    this.favorites = const <String>[],
    this.sortMode = 'manual',
    this.grouped = false,
  });

  /// 进入时的隐藏服务 id（服务页传入，避免重复读存储）。
  final List<String> hidden;

  /// 进入时的收藏 id。
  final List<String> favorites;

  /// 进入时的排序模式：`manual` / `usage`。
  final String sortMode;

  /// 进入时是否已打开「按用途分组」（默认关 —— 默认是单列平铺）。
  final bool grouped;

  @override
  State<ServiceSettingsPage> createState() => _ServiceSettingsPageState();
}

class _ServiceSettingsPageState extends State<ServiceSettingsPage> {
  /// 单行高度（两行文字：名称 + 描述）。
  static const double _rowHeight = 56;

  late final Set<String> _hidden = widget.hidden.toSet();
  late final Set<String> _favorites = widget.favorites.toSet();
  late String _sortMode = widget.sortMode;
  late bool _grouped = widget.grouped;

  /// 按用户拖出来的顺序排好的服务清单。加载完成后替换。
  ///
  /// 初始值用 [mainServices] 原序，避免首帧空白；`_loadOrder()` 回来再覆盖。
  late List<ToolModel> _ordered = List<ToolModel>.of(mainServices);

  @override
  void initState() {
    super.initState();
    _loadOrder();
  }

  /// 把存储里的 id 顺序套到 [mainServices] 上。
  ///
  /// 落盘顺序与当前清单可能对不上（老用户没存过 / 以后加了新服务），
  /// 所以这里按「存储顺序优先，缺的按原序补到末尾，多的丢掉」合并 ——
  /// 直接拿存储当准会让新加的服务永远不显示。
  Future<void> _loadOrder() async {
    final stored = await StorageService.loadServiceOrder();
    if (!mounted) return;
    final byId = {for (final t in mainServices) t.id: t};
    final merged = <ToolModel>[];
    for (final id in stored) {
      final t = byId.remove(id);
      if (t != null) merged.add(t);
    }
    // 🔴 必须写 `containsKey(t.id)`，不能写 `containsKey`。
    //   这是 `Map<String, ToolModel>`，`containsKey` 的形参是 `Object?`，
    //   直接传方法引用会把整个 `ToolModel` 当 key 去查 —— 永远 false。
    //   后果不是「少几条」而是 **merged 变成空列表，整页空白**
    //   （2026-11-03 修「设置页服务管理空白异常」，见
    //    test/service_settings_render_test.dart）。
    merged.addAll(mainServices.where((t) => byId.containsKey(t.id)));
    setState(() => _ordered = merged);
  }

  Future<void> _toggle(String id, bool show) async {
    setState(() => show ? _hidden.remove(id) : _hidden.add(id));
    await StorageService.saveHiddenServices(_hidden.toList());
  }

  Future<void> _toggleFavorite(String id) async {
    setState(() => _favorites.contains(id) ? _favorites.remove(id) : _favorites.add(id));
    await StorageService.saveFavoriteServices(_favorites.toList());
  }

  Future<void> _setSortMode(String mode) async {
    if (_sortMode == mode) return;
    setState(() => _sortMode = mode);
    await StorageService.saveServiceSortMode(mode);
  }

  Future<void> _setGrouped(bool value) async {
    if (_grouped == value) return;
    setState(() => _grouped = value);
    await StorageService.saveServicesGrouped(value);
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    // 手动模式下才有意义。使用模式时列表按次数排，拖动会立刻被覆盖，
    // 所以那种模式下直接不响应拖动（拖动把手也隐藏）。
    if (_sortMode != 'manual') return;
    // ReorderableListView 语义：向下拖时 newIndex 多算了一格。
    if (newIndex > oldIndex) newIndex -= 1;
    setState(() {
      final item = _ordered.removeAt(oldIndex);
      _ordered.insert(newIndex, item);
    });
    await StorageService.saveServiceOrder(_ordered.map((e) => e.id).toList());
  }

  @override
  Widget build(BuildContext context) {
    // _hidden 里可能残留已从 mainServices 移除的旧 id（历史数据），
    // 直接相减会让「当前显示 N / M」偏小；按实际存在的 id 交集算。
    final ids = mainServices.map((e) => e.id).toSet();
    final hiddenCount = _hidden.where(ids.contains).length;
    final visibleCount = mainServices.length - hiddenCount;
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('服务管理',
            style: TextStyle(
                fontSize: AppTheme.fontHeading, fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        // 2026-11-03：底部 padding 叠上系统手势条高度。
        // 原来是死值 32，targetSdk 35 强制 edge-to-edge 之后，
        // 末行（例如设置页的备案号）会被导航条压住。
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          MediaQuery.of(context).padding.bottom + 32,
        ),
        children: [
          Text(
            '关闭开关后，该服务会从服务页隐藏（功能与数据都保留，随时可再打开）。点左侧星标可以把它钉在服务页最上面。',
            style: TextStyle(
                fontSize: AppTheme.fontSmall,
                height: 1.5,
                color: context.textTertiary),
          ),
          const SizedBox(height: 14),
          _sortModeCard(context),
          const SizedBox(height: 10),
          _groupedCard(context),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            child: userCard(
              context,
              padding: EdgeInsets.zero,
              child: ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: _ordered.length,
                onReorder: _onReorder,
                proxyDecorator: (child, index, animation) =>
                    Material(color: Colors.transparent, child: child),
                itemBuilder: (ctx, i) {
                  final tool = _ordered[i];
                  return Column(
                    key: ValueKey<String>(tool.id),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _row(tool, index: i),
                      if (i != _ordered.length - 1)
                        Divider(height: 1, color: context.borderColor),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '当前显示 $visibleCount / ${mainServices.length} 个服务',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: AppTheme.fontSmall, color: context.textTertiary),
          ),
        ],
      ),
    );
  }

  /// 排序模式选择：两个整宽选项，选中打勾。
  ///
  /// 用自绘而不是 `RadioListTile`：全 App 的选择器都是「选中行底色 + 对勾」
  /// 这一套语言（学期选择、筛选弹窗），这里保持一致。
  Widget _sortModeCard(BuildContext context) {
    Widget option(String mode, String title, String desc) {
      final on = _sortMode == mode;
      return InkWell(
        onTap: () => _setSortMode(mode),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                        color: on ? context.textPrimary : context.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      desc,
                      style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          color: context.textTertiary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                on ? Icons.check_circle_rounded : Icons.circle_outlined,
                size: 19,
                color: on ? AppTheme.primaryColor : context.textTertiary,
              ),
            ],
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      child: userCard(
        context,
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            option('manual', '手动排序', '长按右侧手柄拖动，放到你顺手的位置'),
            Divider(height: 1, color: context.borderColor),
            option('usage', '按使用次数', '最近用得多的排前面；收藏永远在最上面'),
          ],
        ),
      ),
    );
  }

  /// 是否按用途分组。默认关，因为默认形态必须是用户熟悉的那一列。
  Widget _groupedCard(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      child: userCard(
        context,
        padding: EdgeInsets.zero,
        child: InkWell(
          onTap: () => _setGrouped(!_grouped),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '按用途分组',
                        style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: _grouped ? FontWeight.w600 : FontWeight.w500,
                          color:
                              _grouped ? context.textPrimary : context.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '打开后服务页分成教务与成绩 / 课程与学习 / 资料与工具 / 校园与生活四块',
                        style: TextStyle(
                            fontSize: AppTheme.fontCaption,
                            color: context.textTertiary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Transform.scale(
                  scale: 0.85,
                  child: Switch(
                    value: _grouped,
                    onChanged: _setGrouped,
                    activeColor: Colors.white,
                    activeTrackColor: AppTheme.primaryColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(ToolModel tool, {required int index}) {
    final shown = !_hidden.contains(tool.id);
    final fav = _favorites.contains(tool.id);
    return InkWell(
      onTap: () => _toggle(tool.id, !shown),
      child: SizedBox(
        height: _rowHeight,
        child: Padding(
          padding: const EdgeInsets.only(left: 4, right: 16),
          child: Row(
            children: [
              // 收藏星：独立点击区，与「点整行切显示」分开。
              IconButton(
                onPressed: () => _toggleFavorite(tool.id),
                tooltip: fav ? '取消收藏' : '收藏',
                iconSize: 19,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  fav ? Icons.star_rounded : Icons.star_border_rounded,
                  color: fav ? context.warningColor : context.textTertiary,
                ),
              ),
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor
                      .withValues(alpha: context.isDark ? 0.20 : 0.10),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: Icon(tool.icon, size: 19, color: AppTheme.primaryColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      tool.name,
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle,
                        fontWeight: FontWeight.w500,
                        color: shown ? context.textPrimary : context.textTertiary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      // 副标题把「分组」也带出来：用户在这里能看懂
                      // 这个服务在服务页会落到哪一块，不用回去找。
                      shown
                          ? '显示中 · ${ServiceGroup.titleOf(tool.group)}'
                          : '已隐藏',
                      style: TextStyle(
                          fontSize: AppTheme.fontSmall,
                          color: context.textTertiary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: shown,
                  onChanged: (v) => _toggle(tool.id, v),
                  activeColor: Colors.white,
                  activeTrackColor: AppTheme.primaryColor,
                ),
              ),
              // 拖动把手：只有手动模式才给。使用模式下拖动不生效，
              // 留着把手会让人以为坏了。
              if (_sortMode == 'manual')
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.drag_handle_rounded,
                      size: 20,
                      color: context.textTertiary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
