import 'package:flutter/material.dart';
import '../../models/school_notice.dart';
import '../../theme/app_theme.dart';
import 'msg_style.dart';

/// 消息中心列表卡片。
///
/// 开源版说明：原文件还含「系统公告」用的 `messageCategoryStyles` /
/// 站内消息相关的样式表与富卡片已整体移除，此处只保留**学校公告**
/// （教务处直抓）的卡片。

/// 学校公告列表卡片：只显示标题和发布日期（微边框，仿消息卡片风格）。
class SchoolNoticeCard extends StatelessWidget {
  final SchoolNotice notice;
  final int index;
  final bool isDark;
  final bool isRead;
  final VoidCallback onTap;

  const SchoolNoticeCard({
    super.key,
    required this.notice,
    required this.index,
    required this.isDark,
    this.isRead = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // v1.1.0：改为「无缝白底行」外壳（与频道列表统一，用户要求两版一致）：
    // 去掉卡片圆角/边框/阴影与卡片之间的外边距，行内只留左右 20 / 上下 15 内边距，
    // 行与行之间由列表的 1px 灰线分隔（见 notification_page 的 _buildSchoolNotices）。
    return Padding(
      // card 样式：四周留边距 + 圆角外壳；plain：纯白无缝（默认）
      padding: MsgStyle.card
          ? const EdgeInsets.fromLTRB(14, 0, 14, 12)
          : EdgeInsets.zero,
      child: Material(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: MsgStyle.card ? BorderRadius.circular(20) : null,
        clipBehavior: MsgStyle.card ? Clip.antiAlias : Clip.none,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: MsgStyle.card
                ? const EdgeInsets.all(16)
                : const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            decoration: MsgStyle.card
                ? BoxDecoration(
                    // 显式纯白：之前没给底色，叠在页面底色上看起来「整体发灰」
                    color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: context.borderColor),
                    boxShadow: [
                      BoxShadow(
                        // v2.5.2/v1.1.1 复刻「内部纯白」那版：阴影要很淡（原来 0.04/18/4 偏灰）
                        color: const Color(0x0A000000),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
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
                        notice.title,
                        style: TextStyle(
                          // v1.1.1 字体对齐在线版：15 / w600 / 行高 1.4（原来 14）
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                          color: context.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            notice.date.isNotEmpty ? notice.date : '日期未知',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.grey.shade500,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Icon(Icons.visibility_rounded,
                              size: 13, color: Colors.grey.shade500),
                          const SizedBox(width: 3),
                          Text(
                            '${notice.views}',
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
                if (!isRead)
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
}
