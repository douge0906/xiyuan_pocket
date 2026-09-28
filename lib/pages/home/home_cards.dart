import 'package:flutter/material.dart';
import '../../services/campus_net_service.dart';
import '../../services/exam_storage.dart';
import '../../theme/app_theme.dart';

// 首页的三张状态/概览卡片（v1.0.0 从 home_page.dart 剥离）。
//
// 原本是 HomePageState 的成员方法，依赖页面字段。Dart 私有成员是文件级的，
// 搬出后改为「数据经构造函数传入 + 交互经回调上报」的 StatelessWidget，
// 渲染逻辑逐行保留。

/// 今日概览卡片：今天课程数 / 待办完成情况 / 最近考试倒计时。
class HomeTodayOverview extends StatelessWidget {
  const HomeTodayOverview({
    super.key,
    required this.isDark,
    required this.loaded,
    required this.todayCourseCount,
    required this.todoDone,
    required this.todoTotal,
    required this.nextExam,
  });

  final bool isDark;
  final bool loaded;
  final int todayCourseCount;
  final int todoDone;
  final int todoTotal;

  /// 最近一场考试（无则显示「暂无考试」）。
  final ExamCountdown? nextExam;

  @override
  Widget build(BuildContext context) {
    if (!loaded) return const SizedBox.shrink();
    final surface = context.surfaceColor;
    final subColor = context.textSecondary;
    final titleColor = context.textPrimary;

    String examMain;
    String examSub;
    if (nextExam == null) {
      examMain = '—';
      examSub = '暂无考试';
    } else if (nextExam!.daysLeft == 0) {
      examMain = '今天';
      examSub = nextExam!.name;
    } else {
      examMain = '${nextExam!.daysLeft} 天';
      examSub = nextExam!.name;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12), // v1.5.1 压缩：原 bottom 16
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 8), // v1.5.1 压缩：原 18
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(20),
          boxShadow: AppTheme.cardShadow,
          // v2.4.3：补灰线边框，与「服务」页卡片观感统一
          border: Border.all(color: context.borderColor, width: 1),
        ),
        child: Row(
          children: [
            Expanded(
              child: _OverviewItem(
                icon: Icons.menu_book_rounded,
                iconColor: const Color(0xFF3B82F6),
                main: '$todayCourseCount',
                sub: '今天课程',
                titleColor: titleColor,
                subColor: subColor,
              ),
            ),
            _overviewDivider(isDark),
            Expanded(
              child: _OverviewItem(
                icon: Icons.checklist_rounded,
                iconColor: const Color(0xFF10B981),
                main: '$todoDone/$todoTotal',
                sub: '待办完成',
                titleColor: titleColor,
                subColor: subColor,
              ),
            ),
            _overviewDivider(isDark),
            Expanded(
              child: _OverviewItem(
                icon: Icons.event_available_rounded,
                iconColor: const Color(0xFFF59E0B),
                main: examMain,
                sub: examSub,
                titleColor: titleColor,
                subColor: subColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _overviewDivider(bool isDark) => Container(
        width: 1,
        height: 40,
        color: isDark ? Colors.grey.shade800 : const Color(0xFFF3F4F6),
      );
}

class _OverviewItem extends StatelessWidget {
  const _OverviewItem({
    required this.icon,
    required this.iconColor,
    required this.main,
    required this.sub,
    required this.titleColor,
    required this.subColor,
  });

  final IconData icon;
  final Color iconColor;
  final String main;
  final String sub;
  final Color titleColor;
  final Color subColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: iconColor),
        const SizedBox(height: 4),
        Text(
          main,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: titleColor),
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: subColor),
          ),
        ),
      ],
    );
  }
}


/// 校园网连接状态指示（点按重新检测）。
class HomeCampusNetStatus extends StatelessWidget {
  const HomeCampusNetStatus({
    super.key,
    required this.isDark,
    required this.status,
    required this.onRefresh,
  });

  final bool isDark;
  final CampusNetStatus status;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    Color dot;
    String label;
    switch (status) {
      case CampusNetStatus.online:
        dot = const Color(0xFF10B981);
        label = '校园网已连接';
        break;
      case CampusNetStatus.captive:
        dot = const Color(0xFFF59E0B);
        label = '校园网未认证';
        break;
      case CampusNetStatus.offCampus:
        dot = isDark ? Colors.grey.shade600 : Colors.grey.shade400;
        label = '非校园网';
        break;
      default:
        dot = isDark ? Colors.grey.shade600 : Colors.grey.shade400;
        label = '校园网检测中…';
    }
    return GestureDetector(
      onTap: onRefresh,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: context.textTertiary),
          ),
        ],
      ),
    );
  }
}
