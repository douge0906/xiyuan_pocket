import 'package:flutter/material.dart';
import '../../models/course_model.dart';
import '../../theme/app_theme.dart';

// 课程导入弹窗（v1.0.0 从 course_table_home_page.dart 剥离）。
//
// 开源版变更（2026-09-22）：**只保留「教务系统一键导入」**，删除其余三种方式
// （PDF / 粘贴文本 / 表格文件）。理由：开源版走客户端直连教务系统，
// 一键导入最准、最省事；其余方式（PDF / 粘贴 / 表格）解析成功率低，已移除。
// 连带移除了 `course_pdf_parser` / `course_import_parser` / `text_decode_service`
// 三个独占依赖文件，以及 pubspec 的 `pdfrx`（它还会触发 NDK/CMake 原生构建）。
//
// 本文件现只负责「导入方式面板」+ 共享的图标项/字段组件。
//
// 抽取时发现的不对称，**刻意保留原样**：
//   · 教务一键导入（_showJwcImportSheet）与页面 Riverpod 深度耦合
//     （courseProvider.mergeServer / setSemesterStart、userConfigProvider、
//      _importTimer/_seconds/_selectedWeek），留在页面，不在此文件；
//   · 因此「教务导入」按钮走 [onOpenJwcImport] 回调，仍由页面实现。
//
// 解析出课程后统一交给 [onConfirmParsed]（= 页面的 _confirmParsedImport），
// 因为「合并进课表 + 落库 + 重排提醒」属于页面职责。

/// 导入方式选择面板（底部弹出）。
///
/// 开源版只剩「教务系统一键导入」一种方式 —— 走 [onOpenJwcImport] 回调，
/// 由页面实现（与 Riverpod 耦合）。
///
/// [onConfirmParsed] 保留形参：调用方仍会传，且后续若恢复其它导入方式可直接复用。
void showImportSheet(
  BuildContext context, {
  required void Function() onOpenJwcImport,
  required void Function(List<Course> parsed, {required String sourceLabel})
      onConfirmParsed,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 12),
            Text('导入课程',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : AppTheme.textPrimaryLight)),
            const SizedBox(height: 4),
            Text('选择一种导入方式，导入的教务课程会替换上次教务导入，保留你自主添加的课程。',
                style: TextStyle(
                    fontSize: 12.5,
                    color: isDark ? Colors.grey.shade500 : const Color(0xFF6B7280))),
            const SizedBox(height: 16),
            _importOption(
              ctx,
              isDark,
              icon: Icons.account_balance_rounded,
              color: AppTheme.primaryColor,
              title: '教务系统一键导入',
              subtitle: '用统一认证账号同步本学期课程（自动）',
              onTap: () {
                Navigator.of(ctx).pop();
                onOpenJwcImport();
              },
            ),
            const SizedBox(height: 8),
            const SizedBox(height: 4),
          ],
        ),
      ),
    ),
  );
}

Widget _importOption(
  BuildContext ctx,
  bool isDark, {
  required IconData icon,
  required Color color,
  required String title,
  required String subtitle,
  required VoidCallback onTap,
}) {
  return Material(
    color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF3F4F6),
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : AppTheme.textPrimaryLight)), // 顶层函数无 context
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11,
                          color: isDark
                              ? Colors.grey.shade500
                              : const Color(0xFF6B7280))),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: isDark ? Colors.grey.shade600 : const Color(0xFF9CA3AF)),
          ],
        ),
      ),
    ),
  );
}

/// 表单字段容器（标签 + 子控件）。课程表单与教务导入面板共用，故设为公开。
Widget courseField(String label, Widget child, bool isDark) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.grey.shade400 : const Color(0xFF374151))),
        ),
        child,
      ],
    );
