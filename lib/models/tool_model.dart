import 'package:flutter/material.dart';

import 'service_group.dart';

class ToolModel {
  final String id;
  final String name;
  final IconData icon;
  final Color color;
  final bool isCloud; // true=调用云端接口，false=纯本地操作
  final bool needsNetwork; // true=需要联网，false=可离线使用
  final bool isMini; // true=归入「小工具箱」分组（2.0 重构）
  final String? badgeText; // 额外角标文字（如「测试」）；非空时显示在名称右侧

  /// 归属的功能块 id（见 `models/service_group.dart` 的 [serviceGroups]）。
  ///
  /// 2026-11-25：服务从 5 个涨到 12 个之后，一整条长列表滑起来找东西很累。
  /// 改成按用途分块（教务与学业 / 课程与学习 / 资源与工具 / 校园与生活），
  /// 每块自带标题，和网页端「常用章节」那种分块网格是同一套读法。
  final String group;

  const ToolModel({
    required this.id,
    required this.name,
    required this.icon,
    required this.color,
    this.isCloud = true,
    this.needsNetwork = true,
    this.isMini = false,
    this.badgeText,
    this.group = ServiceGroup.campus,
  });
}
