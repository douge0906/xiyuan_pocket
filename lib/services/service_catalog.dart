import 'package:flutter/material.dart';
import '../models/tool_model.dart';

/// 服务页全部服务的**唯一数据源**（v1.9.0：原为 toolbox_page 内的私有常量）。
///
/// 服务页渲染 + 服务管理页开关都从这里取，避免两处各维护一份。
/// ⚠️ 这里仅保留**客户端能独立完成**的服务（无服务端依赖）。
const List<ToolModel> mainServices = [
  ToolModel(
    id: 'grade_push',
    name: '成绩查询',
    icon: Icons.assessment_rounded,
    description: '查看各学期成绩与统计',
    color: Color(0xFF1F2937),
    needsNetwork: true,
  ),
  ToolModel(
    id: 'exam_query',
    name: '考试安排',
    icon: Icons.event_note_rounded,
    description: '查询本学期考试时间与考场',
    color: Color(0xFF1F2937),
    needsNetwork: true,
  ),
  ToolModel(
    id: 'xyl_calendar',
    name: '无锡学院校历',
    icon: Icons.calendar_month_rounded,
    description: '2026-2027 学年校历：周次、假期与节假日安排',
    color: Color(0xFF1F2937),
    needsNetwork: false,
    isNew: true,
  ),
  ToolModel(
    id: 'textbook',
    name: '我的教材',
    icon: Icons.menu_book_rounded,
    description: '本学期教材清单',
    color: Color(0xFF1F2937),
    needsNetwork: false,
    isNew: true,
  ),
  ToolModel(
    id: 'campus_map',
    name: '校园地图',
    icon: Icons.map_rounded,
    description: '校园平面图，可双指缩放查看',
    color: Color(0xFF1F2937),
    needsNetwork: false,
    isNew: true,
  ),
];
