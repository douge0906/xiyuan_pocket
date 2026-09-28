import 'package:flutter/material.dart';
import '../models/tool_model.dart';
import '../theme/app_theme.dart';

/// 服务页竖列卡片（2.0.1：仿校园 App 格式）——细边框 + 图标 + 名称 + 超小描述 + 右箭头。
class ServiceTile extends StatelessWidget {
  final ToolModel tool;
  final VoidCallback onTap;

  const ServiceTile({super.key, required this.tool, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = context.textPrimary;
    final subColor = isDark ? Colors.grey.shade500 : const Color(0xFF9CA3AF);
    final borderColor = context.borderColor;
    final bgColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    // v2.1.0：图标改为跟随主题色 —— 原来用 textPrimary（正文色），
    // 导致切主题色时服务页毫无变化，用户感知不到主题生效。
    final iconColor = AppTheme.primaryColor;
    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(isDark ? 0.20 : 0.10),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(tool.icon, size: 21, color: iconColor),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            tool.name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: titleColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (tool.isNew) ...[
                          const SizedBox(width: 6),
                          const Text(
                            '新',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF10B981)),
                          ),
                        ],
                        if (tool.badgeText != null && tool.badgeText!.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF4E0),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: const Color(0xFFF59E0B), width: 0.8),
                            ),
                            child: Text(
                              tool.badgeText!,
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFFB45309)),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (tool.description.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        tool.description,
                        style: TextStyle(fontSize: 11, color: subColor),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, size: 20, color: subColor),
            ],
          ),
        ),
      ),
    );
  }
}
