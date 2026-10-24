import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

// 「我的」页的各张卡片。
//
// 这些组件都是无状态展示件：数据经构造函数传入、交互经回调上报，
// 本身不持有任何状态。

/// 卡片通用外壳。
///
/// [padding] 默认 16；身份卡这类「行内自带内边距」的卡片传 [EdgeInsets.zero]，
/// 这样行与行之间的分割线才能**左右贯通到卡片边缘**。
Widget userCard(
  BuildContext context, {
  required Widget child,
  EdgeInsetsGeometry padding = const EdgeInsets.all(16),
}) =>
    Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF1E1E1E)
            : Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: context.borderColor),
        boxShadow: AppTheme.cardShadow,
      ),
      child: child,
    );

/// 「我的」页顶部：**居中加粗的「掌上锡院」** + 右上角设置齿轮。
///
/// 布局说明：用 `SizedBox(48) + Expanded(Center) + IconButton(48)` 三栏，
/// 让标题在**整屏**居中（若只用 Stack，标题会随右图标偏左）。
class UserTitleHeader extends StatelessWidget {
  const UserTitleHeader({super.key, required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, MediaQuery.of(context).padding.top + 10, 8, 4),
      child: Row(
        children: [
          const SizedBox(width: 48), // 与右侧齿轮等宽，保证标题真正居中
          Expanded(
            child: Center(
              child: Text(
                '掌上锡院',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 3,
                  color: context.textPrimary,
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: onOpenSettings,
            tooltip: '设置',
            icon: Icon(Icons.settings_rounded,
                color: isDark ? Colors.white70 : const Color(0xFF6B7280)),
          ),
        ],
      ),
    );
  }
}

/// 身份卡：姓名 / 学号。
///
/// 版式（仿掌上徐工）：**行首小图标** + 标签在左、**值右对齐**，
/// 两行之间一条**左右贯通到卡片边缘**的分割线；
/// 单行高度统一 [rowHeight]，与页面其余「框框」保持一致。
class UserInfoCard extends StatelessWidget {
  const UserInfoCard({
    super.key,
    required this.name,
    required this.studentId,
    required this.dormText,
    required this.onDormTap,
  });

  final String name;
  final String studentId;

  /// 宿舍显示文本（楼栋 + 房号）；空 = 未填写。
  final String dormText;
  final VoidCallback onDormTap;

  /// 统一的单行高度 —— 用户页所有行都用这个值，保证框框高度一致。
  static const double rowHeight = 52;

  /// 行内容的左右内边距（卡片自身不加内边距 → 分割线才能贯通到边缘）。
  static const double rowPadding = 16;

  @override
  Widget build(BuildContext context) {
    return userCard(
      context,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          _infoRow(context, Icons.account_circle_outlined, '姓名', name),
          Divider(height: 1, color: context.borderColor),
          _infoRow(context, Icons.badge_outlined, '学号', studentId),
          Divider(height: 1, color: context.borderColor),
          _dormRow(context),
        ],
      ),
    );
  }

  Widget _infoRow(
      BuildContext context, IconData icon, String label, String value) {
    final display = value.trim().isEmpty ? '—' : value.trim();
    return SizedBox(
      height: rowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: rowPadding),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppTheme.primaryColor),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.left,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: context.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 宿舍行：值 + 淡灰 `>`，整行可点。
  Widget _dormRow(BuildContext context) {
    final text = dormText.trim().isEmpty ? '未填写' : dormText.trim();
    return InkWell(
      onTap: onDormTap,
      child: SizedBox(
        height: 64,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: rowPadding),
          child: Row(
            children: [
              Icon(Icons.bed_outlined, size: 20, color: AppTheme.primaryColor),
              const SizedBox(width: 12),
              Text('宿舍',
                  style:
                      TextStyle(fontSize: 14, color: Colors.grey.shade500)),
              const Spacer(),
              Flexible(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.left,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: text == '未填写'
                        ? Colors.grey.shade400
                        : context.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: Colors.grey.shade400),
            ],
          ),
        ),
      ),
    );
  }
}
