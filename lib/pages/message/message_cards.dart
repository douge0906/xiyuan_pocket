import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../theme/app_theme.dart';
import 'msg_style.dart';

/// 消息列表卡片 —— **所有消息源共用的一种行**。
///
/// 重构前有两套：`SchoolNoticeCard`（教务处）与页面内联拼的资讯行，
/// 各写各的很快就漂了（圆角 / 描边都不一致）—— 现在只剩这一份。
///
/// 两种样式由 [MsgStyle.card] 切换（消息设置页可改）：
/// * `false` 纯白无缝：左右不留页边距，行内 20/15，行间一条 1px 细线
///   （分割线由列表绘制，见 notification_page.dart）。
/// * `true`  圆角卡片：浅色纯白 / 深色表面色底 + 1px `context.borderColor`
///   细边框 + `AppTheme.radiusLg`(20) 圆角，无阴影，卡间距 `AppTheme.gapSm`。
class MessageCard extends StatelessWidget {
  final Message message;

  /// 是否显示未读红点（直接收 `isUnread`，调用方不必取反）。
  final bool isUnread;

  /// 是否在日期前显示来源标签。
  ///
  /// 默认 `false`：同一个页签下**所有行的来源都一样**，每行都挂一个
  /// 「教务处」纯属噪音。保留这个开关是为了将来出现「跨来源混合列表」时
  /// 能直接打开，而不是到时候再复制一份卡片。
  final bool showBadge;

  final VoidCallback onTap;

  const MessageCard({
    super.key,
    required this.message,
    required this.onTap,
    this.isUnread = false,
    this.showBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    // 2026-11-07：卡片样式按最新口径收紧 —— 浅色强制纯白、去掉淡阴影，
    // 只留 1px 细边框 + 20 圆角；上下内边距与卡间距一并压缩，列表更紧凑。
    // 深色仍用深色表面色，避免纯白在暗背景上刺眼。
    final rowBg = isDark ? context.surfaceColor : Colors.white;

    return Padding(
      padding: MsgStyle.card
          ? const EdgeInsets.only(bottom: AppTheme.gapSm)
          : EdgeInsets.zero,
      child: Material(
        color: rowBg,
        borderRadius: MsgStyle.card ? AppTheme.radiusLgAll : null,
        clipBehavior: MsgStyle.card ? Clip.antiAlias : Clip.none,
        child: InkWell(
          onTap: onTap,
          // 圆角裁剪：墨迹沿 20 圆角扩散，不会溢出成方角；无缝行则铺满整行。
          borderRadius: MsgStyle.card ? AppTheme.radiusLgAll : null,
          // 按压 / 点击反馈：splash 负责点下扩散、highlight 负责按住态，
          // 都用主题色低透明，明暗主题一致且不盖住文字。
          splashColor: AppTheme.primaryColor.withValues(alpha: 0.12),
          highlightColor: AppTheme.primaryColor.withValues(alpha: 0.08),
          child: Container(
            padding: MsgStyle.card
                ? const EdgeInsets.symmetric(
                    horizontal: AppTheme.gapLg, vertical: 10)
                : const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            decoration: MsgStyle.card
                ? BoxDecoration(
                    // ⚠️ 这里**不能再铺不透明底色**（会盖死墨迹）。
                    //    圆角 / 描边保留，底色交给上层 Material。
                    borderRadius: AppTheme.radiusLgAll,
                    // 1px 细边框：浅色 / 深色统一用 context.borderColor，
                    // 在各自底色上都看得清（对齐 UI_GUIDE「1px 细边框 + 20 圆角」）。
                    // 刻意不加阴影：浅色淡投影会让白卡「发灰」，不符合纯白要求。
                    border: Border.all(color: context.borderColor, width: 1),
                  )
                : null,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        message.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          // 标题：fontTitle / 主文字色；未读加粗一档，区分更清晰。
                          fontSize: AppTheme.fontTitle,
                          fontWeight:
                              isUnread ? FontWeight.w700 : FontWeight.w600,
                          height: 1.4,
                          color: context.textPrimary,
                        ),
                      ),
                      const SizedBox(height: AppTheme.gapSm),
                      Row(
                        children: [
                          if (showBadge && (message.badge ?? '').isNotEmpty) ...[
                            _badge(context, message.badge!),
                            const SizedBox(width: AppTheme.gapSm),
                          ],
                          Text(
                            message.date.isNotEmpty ? message.date : '日期未知',
                            style: TextStyle(
                              // 日期：fontSmall / 次级文字色（与标题主色、
                              // 箭头弱色形成「主 - 次 - 弱」三层对比）。
                              fontSize: AppTheme.fontSmall,
                              color: context.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (isUnread)
                  Container(
                    width: 9,
                    height: 9,
                    margin: const EdgeInsets.only(left: AppTheme.gapSm),
                    decoration: BoxDecoration(
                      // 未读圆点用 dangerColor 语义红，深色下自动降饱和。
                      color: context.dangerColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                Icon(
                  Icons.chevron_right_rounded,
                  // 箭头：最弱层级，不抢标题。
                  color: context.textTertiary,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 来源标签（默认不显示，见 [showBadge]）。
  Widget _badge(BuildContext context, String text) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.gapSm,
          vertical: AppTheme.gapXs,
        ),
        decoration: BoxDecoration(
          color: context.subtleFill,
          borderRadius: AppTheme.radiusSmAll,
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: AppTheme.fontCaption,
            color: context.textSecondary,
          ),
        ),
      );
}
