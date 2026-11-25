import 'package:flutter/material.dart';

/// 服务页的功能块（分组）。
///
/// 2026-11-25 用户要求「功能块必须按照网页端分块，比如几个功能入口」——
/// 网页端首页是「从这里开始 / 常用章节」这种带标题的分块网格，
/// App 的 12 个服务平铺成一条长列表读起来没有层次，找东西只能靠滑。
///
/// 分块的依据是**用户来干什么**，不是数据从哪来：
/// - 查自己的教务数据（成绩 / 考试 / 学业 / 空教室）
/// - 课表与学习安排（在线课表 / 学习通 / 教材 / 校历）
/// - 找资料与工具（资源中心 / 手册 / 地图 / 云打印）
///
/// ⚠️ 新增服务时**必须**在 [ToolModel.group] 上指定归属，否则会落到默认组
/// 末尾 —— 不会丢，但会出现在「校园与生活」里，读起来别扭。
class ServiceGroup {
  ServiceGroup._();

  static const String academic = 'academic';
  static const String study = 'study';
  static const String tools = 'tools';
  static const String campus = 'campus';

  /// 展示顺序（顺序即页面上从上到下的次序）。
  static const List<String> order = [academic, study, tools, campus];

  static String titleOf(String id) => switch (id) {
        academic => '教务与成绩',
        study => '课程与学习',
        tools => '资料与工具',
        campus => '校园与生活',
        _ => '其他',
      };

  /// 分组标题右侧的一句话说明（只在必要时出现，避免每块都堆小字）。
  static String? hintOf(String id) => switch (id) {
        study => '课表、作业与教材',
        _ => null,
      };

  static IconData iconOf(String id) => switch (id) {
        academic => Icons.assessment_outlined,
        study => Icons.calendar_month_outlined,
        tools => Icons.folder_open_outlined,
        campus => Icons.location_city_outlined,
        _ => Icons.apps_rounded,
      };
}
