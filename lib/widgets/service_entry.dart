import 'package:flutter/material.dart';

import '../models/tool_model.dart';
import '../theme/app_theme.dart';

/// 服务页的**单个功能入口**（网页端「常用章节」那种格子，不是整行列表）。
///
/// 为什么改格子：服务从 5 个涨到 12 个之后，整行卡片一屏只能放 6 个，
/// 「云打印扫描件」「锡院在线课表」这种新功能要滑很久才看得到。
/// 换成两列格子后一屏能放 4 行 8 个，配合分组标题，找东西是「看区块」
/// 而不是「逐行扫」—— 这也和网页端 fast-grid 的读法一致。
class ServiceEntry extends StatelessWidget {
  const ServiceEntry({
    super.key,
    required this.tool,
    required this.onTap,
    this.onLongPress,
    this.favorite = false,
  });

  final ToolModel tool;
  final VoidCallback onTap;

  /// 长按：服务页用它切换收藏（收藏项固定在最上面）。
  final VoidCallback? onLongPress;

  /// 是否已收藏（显示实心星）。
  final bool favorite;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final tint = AppTheme.primaryColor;
    return Material(
      color: isDark ? const Color(0xFF1A1A1A) : Colors.white,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            border: Border.all(color: context.borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: isDark ? 0.20 : 0.10),
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    ),
                    child: Icon(tool.icon, size: 17, color: tint),
                  ),
                  const Spacer(),
                  if (favorite)
                    Icon(Icons.star_rounded, size: 15, color: context.warningColor),
                ],
              ),
              const SizedBox(height: 9),
              Text(
                tool.name,
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  height: 1.25,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (tool.badgeText != null && tool.badgeText!.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  tool.badgeText!,
                  style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    fontWeight: FontWeight.w600,
                    color: context.warningColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
