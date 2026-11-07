import 'package:flutter/material.dart';

import '../models/tool_model.dart';
import '../services/service_catalog.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import 'user/user_cards.dart';

/// 服务管理页（v1.9.0，2026-11-03 加拖动排序）：服务页右上角设置进入。
///
/// UI 与「我的」页的框框规范保持一致（复用 [userCard]）：
/// 圆角 20 + 1px 灰线边框 + 行高统一、分割线左右贯通到卡片边缘。
/// 每行一个开关 —— 关闭后该服务从服务页隐藏（功能与数据都保留，随时可再打开）。
/// **长按右侧拖动手柄可调整顺序**（2026-11-03 新增）。
/// 修改**即时保存**，返回服务页自动生效。
class ServiceSettingsPage extends StatefulWidget {
  const ServiceSettingsPage({super.key, required this.hidden});

  /// 进入时的隐藏服务 id（服务页传入，避免重复读存储）。
  final List<String> hidden;

  @override
  State<ServiceSettingsPage> createState() => _ServiceSettingsPageState();
}

class _ServiceSettingsPageState extends State<ServiceSettingsPage> {
  /// 单行高度（两行文字：名称 + 描述）。
  static const double _rowHeight = 56;

  late final Set<String> _hidden = widget.hidden.toSet();

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

  Future<void> _onReorder(int oldIndex, int newIndex) async {
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
            style: TextStyle(fontSize: AppTheme.fontHeading, fontWeight: FontWeight.w600)),
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
            '关闭开关后，该服务会从服务页隐藏（功能与数据都保留，随时可再打开）。',
            style: TextStyle(
                fontSize: AppTheme.fontSmall, height: 1.5, color: context.textTertiary),
          ),
          const SizedBox(height: 10),
          // 2026-11-03：改成可拖动排序。卡片圆角由外层的 ClipRRect 兜住
          // —— ReorderableListView 拖动时子项会被抬到列表之上，
          //   不裁剪的话会和卡片的圆角/阴影打架。
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
            style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _row(ToolModel tool, {required int index}) {
    final shown = !_hidden.contains(tool.id);
    return InkWell(
      onTap: () => _toggle(tool.id, !shown),
      child: SizedBox(
        height: _rowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
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
                        // 2026-11-03 #3：服务名从 fontBody(14) 提到 fontTitle(16)
                        // 并加 w500。服务页每行只有图标 + 名称，名称是唯一
                        // 识别信息，14 号在一屏 7 行里偏小、扫读吃力。
                        fontSize: AppTheme.fontTitle,
                        fontWeight: FontWeight.w500,
                        // 已隐藏的行名称变灰，与「显示中」一眼区分
                        color: shown
                            ? context.textPrimary
                            : context.textTertiary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      shown ? '显示中' : '已隐藏',
                      style: TextStyle(
                          fontSize: AppTheme.fontSmall, color: context.textTertiary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 选中色用主题色；主题色较深时靠「已隐藏行名称变灰」辅助区分。
              Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: shown,
                  onChanged: (v) => _toggle(tool.id, v),
                  activeColor: Colors.white,
                  activeTrackColor: AppTheme.primaryColor,
                ),
              ),
              // 拖动把手：只有按在这里才拖，避免和「点一行切开关」抢手势。
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
