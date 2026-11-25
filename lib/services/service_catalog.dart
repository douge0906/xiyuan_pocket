import 'package:flutter/material.dart';
import '../models/service_group.dart';
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
    color: Color(0xFF1F2937),
    needsNetwork: true,
    group: ServiceGroup.academic,
  ),
  ToolModel(
    id: 'exam_query',
    name: '考试安排',
    icon: Icons.event_note_rounded,
    color: Color(0xFF1F2937),
    needsNetwork: true,
    group: ServiceGroup.academic,
  ),
  ToolModel(
    id: 'empty_classroom',
    name: '空教室查询',
    icon: Icons.meeting_room_rounded,
    color: Color(0xFF1F2937),
    needsNetwork: true,
    group: ServiceGroup.academic,
  ),
  ToolModel(
    id: 'my_study',
    name: '我的学业',
    icon: Icons.school_rounded,
    color: Color(0xFF1F2937),
    needsNetwork: true,
    group: ServiceGroup.academic,
  ),
  ToolModel(
    id: 'library',
    name: '资源中心',
    icon: Icons.folder_special_rounded,
    color: Color(0xFF1F2937),
    needsNetwork: false,
    group: ServiceGroup.tools,
  ),
  ToolModel(
    id: 'xyl_calendar',
    name: '无锡学院校历',
    icon: Icons.calendar_month_rounded,
    color: Color(0xFF1F2937),
    needsNetwork: false,
    group: ServiceGroup.study,
  ),
  ToolModel(
    id: 'textbook',
    name: '我的教材',
    icon: Icons.menu_book_rounded,
    color: Color(0xFF1F2937),
    needsNetwork: false,
    group: ServiceGroup.study,
  ),
  ToolModel(
    id: 'campus_map',
    name: '校园地图',
    icon: Icons.map_rounded,
    color: Color(0xFF1F2937),
    needsNetwork: false,
    group: ServiceGroup.campus,
  ),
  ToolModel(
    id: 'student_handbook',
    name: '锡院学生手册',
    icon: Icons.auto_stories_rounded,
    color: Color(0xFF1F2937),
    needsNetwork: false,
    group: ServiceGroup.tools,
  ),
  // 2026-11-23：学习通（超星）作业与考试同步。
  //
  // 它需要**两套凭证**：学校统一认证（进 App）+ 学习通账号（自己一份），
  // 所以 `needsNetwork: true` 且进页面后自己再要一次绑定。
  // 写出去的东西只有待办与考试安排，不碰课表/成绩/一卡通。
  ToolModel(
    id: 'chaoxing_sync',
    name: '学习通同步',
    icon: Icons.sync_rounded,
    color: Color(0xFF1F2937),
    needsNetwork: true,
    group: ServiceGroup.study,
  ),
  // 2026-11-25：图书馆云打印的扫描件。
  //
  // 它**不需要另一个账号**，用的是 App 已有的统一认证身份再换一张
  // 云打印会话票（校外自动套 WebVPN），所以对用户来说就是「点进去就有」。
  ToolModel(
    id: 'cprint_scan',
    name: '云打印扫描件',
    icon: Icons.document_scanner_rounded,
    color: Color(0xFF1F2937),
    needsNetwork: true,
    group: ServiceGroup.tools,
  ),
  // 2026-11-25：同学们自己上传、审核通过的班级课表。
  //
  // 主入口在课表页的导入面板里（那里才是「我想换一份课表」发生的地方），
  // 这一项是给「在服务页顺手看一眼」的人留的次入口。
  ToolModel(
    id: 'timetable_library',
    name: '锡院在线课表',
    icon: Icons.school_rounded,
    color: Color(0xFF1F2937),
    needsNetwork: true,
    group: ServiceGroup.study,
  ),
];
