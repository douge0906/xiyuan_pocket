import 'package:flutter/material.dart';
import '../../models/school_notice.dart';
import '../../theme/app_theme.dart';

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
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: context.borderColor,
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 18,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
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
                          fontSize: 14,
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
