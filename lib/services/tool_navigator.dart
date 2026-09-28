import 'package:flutter/material.dart';

import 'auth_gate.dart';
import 'tool_usage_storage.dart';
import '../pages/tools/grade_query_page.dart';
import '../pages/tools/exam_query_page.dart';
import '../pages/tools/xyl_calendar_page.dart';
import '../pages/tools/textbook_page.dart';
import '../pages/tools/campus_map_page.dart';

/// 全 App 共用的工具跳转逻辑（服务页复用）。
class ToolNavigator {
  /// **需要登录**（本机已存统一认证账号）才能使用的工具。
  ///
  /// 校历与地图不在此列 —— 前者是纯离线数据，后者是纯内置图片。
  /// 教材要登录（走教务「选课 → 教材预订」，未登录拿不到数据）。
  static const Set<String> loginRequired = {
    'grade_push',
    'exam_query',
    'textbook',
  };

  static Future<void> open(
    BuildContext context,
    String toolId, {
    bool isCloud = false,
  }) async {
    // ① 需要登录的先过闸门：未登录 → 下方弹横条「请登录后才能使用」，**不跳转**
    if (loginRequired.contains(toolId)) {
      final ok = await AuthGate.ensureLoggedIn(context);
      if (!ok) return;
    }
    if (!context.mounted) return;

    // ② 记一次使用（只统计真正打开了的）
    ToolUsageStorage.increment(toolId, isCloud: isCloud);

    switch (toolId) {
      case 'grade_push':
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const GradeQueryPage()));
        break;
      case 'exam_query':
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const ExamQueryPage()));
        break;
      case 'xyl_calendar':
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const XylCalendarPage()));
        break;
      // 地图不需要登录（纯内置图片）；教材已在上面过闸门
      case 'textbook':
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const TextbookPage()));
        break;
      case 'campus_map':
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const CampusMapPage()));
        break;
      default:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('该工具正在开发中')),
        );
    }
  }
}
