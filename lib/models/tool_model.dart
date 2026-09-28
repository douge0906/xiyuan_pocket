import 'package:flutter/material.dart';

class ToolModel {
  final String id;
  final String name;
  final IconData icon;
  final String description;
  final Color color;
  final bool isCloud; // true=调用云端接口，false=纯本地操作
  final bool needsNetwork; // true=需要联网，false=可离线使用
  final bool isNew; // true=在工具列表显示「新工具」标签
  final bool isMini; // true=归入「小工具箱」分组（2.0 重构）
  final String? badgeText; // 额外角标文字（如「测试」）；非空时显示在名称右侧

  const ToolModel({
    required this.id,
    required this.name,
    required this.icon,
    required this.description,
    required this.color,
    this.isCloud = true,
    this.needsNetwork = true,
    this.isNew = false,
    this.isMini = false,
    this.badgeText,
  });
}
