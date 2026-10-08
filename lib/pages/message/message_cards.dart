import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../../theme/app_theme.dart';
import 'msg_style.dart';

/// 消息列表卡片 —— **所有消息源共用的一种行**。
///
/// 重构前有两套：`SchoolNoticeCard`（教务处）与页面里内联拼的资讯行。
/// 两者本意是「看起来一样」，实际各写各的，很快就漂了 ——
/// 卡模式一个用 `radius 20 + 只描右边框`、另一个用 `radius 14 + 四边全框`，
/// 正是用户说的「各个列表不统一」。现在只剩这一份。
///
/// 【统一时取哪一版】取「圆角 14 + 四边 1px 灰线」那版 ——
/// 它是较新的实现（v1.1.1），且当时的注释就写着"与学校公告卡一致"，
/// 说明本意如此，只是那边没改到位。
///
/// 两种样式由 [MsgStyle.card] 切换（消息设置页可改）：
/// * `false` 纯白无缝：左右不留页边距，行内 20/15，行与行之间一条 1px 灰线
/// * `true`  圆角卡片：白色圆角卡片 + 极淡阴影 + 卡片间 12 间距
class MessageCard extends StatelessWidget {
  final Message message;

  /// 是否显示未读红点（传 `!isUnread` 的取反更易读，故直接收 `isUnread`）。
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final rowBg = isDark ? const Color(0xFF1E1E1E) : Colors.white;

    return Padding(
      padding: MsgStyle.card
          ? const EdgeInsets.only(bottom: 12)
          : EdgeInsets.zero,
      child: Material(
        color: rowBg,
        borderRadius: MsgStyle.card ? BorderRadius.circular(14) : null,
        clipBehavior: MsgStyle.card ? Clip.antiAlias : Clip.none,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: MsgStyle.card
                ? const EdgeInsets.all(16)
                : const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            decoration: MsgStyle.card
                ? BoxDecoration(
                    color: rowBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: context.borderColor),
                    boxShadow: const [
                      BoxShadow(
                        // 很淡：在浅色底上不能糊出灰边（复刻「内部纯白」那版）
                        color: Color(0x0A000000),
                        blurRadius: 10,
                        offset: Offset(0, 2),
                      ),
                    ],
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
                          // 15 / w600 / 行高 1.4（与在线版、其它列表一致）
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                          color: context.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          if (showBadge && (message.badge ?? '').isNotEmpty) ...[
                            _badge(message.badge!, isDark),
                            const SizedBox(width: 8),
                          ],
                          Text(
                            message.date.isNotEmpty ? message.date : '日期未知',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.grey.shade500,
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
                    margin: const EdgeInsets.only(left: 8),
                    decoration: const BoxDecoration(
                      color: Color(0xFFEF4444),
                      shape: BoxShape.circle,
                    ),
                  ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.grey.shade400,
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
  Widget _badge(String text, bool isDark) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF1F3F7),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
          ),
        ),
      );
}
