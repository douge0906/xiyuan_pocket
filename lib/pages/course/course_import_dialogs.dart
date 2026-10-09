import 'package:flutter/material.dart';

// 课程表单的共享字段组件。
//
// 本文件原先还负责「导入方式面板」（`showImportSheet`）—— 开源版只剩
// 「教务系统一键导入」一种方式，等于**点开一个只有一个选项的面板**，
// 白多一次点击。2026-10-08 起该按钮连同面板一起移除，同步改由
// `CourseSyncService` 在「登录成功后 / 进入 App（可关）/ 手动点刷新键」三个
// 时机自动完成，不再需要任何导入入口。
//
// 留在本文件里的 [courseField] 仍被 course_form_sheet.dart 复用
// （`import 'course_import_dialogs.dart' show courseField;`），所以文件保留。

/// 表单字段容器（标签 + 子控件）。课程表单与（已移除的）教务导入面板共用。
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
