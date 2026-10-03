import 'package:flutter/material.dart';
import '../models/tool_model.dart';
import '../widgets/service_tile.dart';
import '../services/tool_navigator.dart';
import '../services/service_catalog.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/balance_cards.dart';
import 'service_settings_page.dart';

/// 服务页：顶部居中标题，竖列卡片展示校园服务。
///
/// ⚠️ 这里仅保留**客户端能独立完成**的服务（服务清单见 service_catalog.dart）：
///    成绩查询 / 考试安排（需先登录统一认证）、无锡学院校历、我的教材、校园地图。
///    食堂速览、试卷库、自动推送、建议反馈都依赖服务端，已随开源版移除。
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
  }

  Future<void> _loadHidden() async {
    final hidden = await StorageService.loadHiddenServices();
    if (!mounted) return;
    setState(() => _hidden = hidden);
  }

  /// 可见服务（服务清单唯一数据源见 service_catalog.dart）。
  List<ToolModel> get _visibleTools =>
      mainServices.where((t) => !_hidden.contains(t.id)).toList();

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tools = _visibleTools;
    return Scaffold(
      backgroundColor:
          isDark ? AppTheme.scaffoldDark : const Color(0xFFF5F6F8),
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
                          fontSize: 20,
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
                      padding: EdgeInsets.only(bottom: 20),
                      child: BalanceCardsSection(),
                    );
                  }
                  // 全部服务被隐藏时的空态（有明确出路，不是死胡同）
                  if (tools.isEmpty) return _emptyState();
                  final tool = tools[index - 1];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
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
              style: TextStyle(fontSize: 15, color: context.textSecondary)),
          const SizedBox(height: 6),
          Text('点右上角设置图标可重新开启',
              style: TextStyle(fontSize: 12.5, color: context.textTertiary)),
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
