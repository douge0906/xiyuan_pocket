import 'package:flutter/material.dart';

import '../../services/campus/cprint_models.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';

/// 文件类型图标（40×40 方块）。与「我的下载」「资源中心」同一套配色。
Widget cprintTypeIcon(CprintDocType type, {double size = 40}) {
  final (icon, color) = switch (type.classType) {
    'pdf' => (Icons.picture_as_pdf_rounded, const Color(0xFFDC2626)),
    'img' => (Icons.image_rounded, const Color(0xFF059669)),
    'word' => (Icons.description_rounded, const Color(0xFF2563EB)),
    'excel' => (Icons.table_chart_rounded, const Color(0xFF15803D)),
    'ppt' => (Icons.slideshow_rounded, const Color(0xFFEA580C)),
    'txt' => (Icons.article_rounded, const Color(0xFF6B7280)),
    _ => (Icons.insert_drive_file_rounded, const Color(0xFF6B7280)),
  };
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
    ),
    child: Icon(icon, size: size * .52, color: color),
  );
}

/// 小胶囊标签（已过期 / 已下载 / 空闲 …）。
Widget cprintPill(String text, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: AppTheme.fontCaption,
        height: 1.2,
        color: color,
      ),
    ),
  );
}

/// 字节数 → `12 KB` / `1.2 MB`。
String cprintSize(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 五页签统一的「还没授权」占位。
///
/// 每个页签都可能独立撞上会话过期（用户可能在页签里停留很久），所以这块
/// 不能只放在外层 —— 外层只负责首屏那次授权。
class CprintNeedAuthView extends StatelessWidget {
  const CprintNeedAuthView({
    super.key,
    required this.message,
    required this.onLogin,
    this.busy = false,
  });

  final String message;
  final Future<void> Function() onLogin;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 40, 16, 24),
      children: [
        AppCard(
          radius: AppTheme.radiusLg,
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lock_outline_rounded,
                      size: 18, color: AppTheme.primaryColor),
                  const SizedBox(width: 8),
                  Text(
                    // 不叫「需要授权」—— 用户不知道要授权给谁、为什么。
                    // 这一屏唯一要做的事就是「登录一次」，标题直接说这件事。
                    '登录一次图书馆云打印',
                    style: TextStyle(
                      fontSize: AppTheme.fontTitle,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                message.isEmpty ? '登录状态已失效，请重新授权' : message,
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  height: 1.55,
                  color: context.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: busy ? null : () => onLogin(),
                  child: Text(busy ? '正在登录…' : '用统一认证登录'),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '用你登录掌上锡院的统一认证账号，不用另外注册。'
                '不在校园网时会自动走学校的 WebVPN。',
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  height: 1.5,
                  color: context.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 五页签统一的加载态。
Widget cprintLoading() =>
    const Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.4)));

/// 五页签统一的「一行说明」。
Widget cprintHint(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppTheme.fontSmall,
          height: 1.5,
          color: context.textTertiary,
        ),
      ),
    );
