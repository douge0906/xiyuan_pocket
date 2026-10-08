import 'package:flutter/material.dart';

import '../models/tool_model.dart';
import '../services/service_catalog.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import 'user/user_cards.dart';

/// 服务管理页（v1.9.0）：服务页右上角设置进入。
///
/// UI 与「我的」页的框框规范保持一致（复用 [userCard]）：
/// 圆角 20 + 1px 灰线边框 + 行高统一、分割线左右贯通到卡片边缘。
/// 每行一个开关 —— 关闭后该服务从服务页隐藏（功能与数据都保留，随时可再打开）。
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

  Future<void> _toggle(String id, bool show) async {
    setState(() => show ? _hidden.remove(id) : _hidden.add(id));
    await StorageService.saveHiddenServices(_hidden.toList());
  }

  @override
  Widget build(BuildContext context) {
    final visibleCount = mainServices.length - _hidden.length;
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('服务管理',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            '关闭开关后，该服务会从服务页隐藏（功能与数据都保留，随时可再打开）。',
            style: TextStyle(
                fontSize: 12.5, height: 1.5, color: context.textTertiary),
          ),
          const SizedBox(height: 10),
          userCard(
            context,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (int i = 0; i < mainServices.length; i++) ...[
                  _row(mainServices[i]),
                  if (i != mainServices.length - 1)
                    Divider(height: 1, color: context.borderColor),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '当前显示 $visibleCount / ${mainServices.length} 个服务',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: context.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _row(ToolModel tool) {
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
                      .withOpacity(context.isDark ? 0.20 : 0.10),
                  borderRadius: BorderRadius.circular(10),
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
                        fontSize: 14,
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
                      shown ? tool.description : '已隐藏',
                      style: TextStyle(
                          fontSize: 11.5, color: context.textTertiary),
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
            ],
          ),
        ),
      ),
    );
  }
}
