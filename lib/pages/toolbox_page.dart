import 'package:flutter/material.dart';
import '../models/tool_model.dart';
import '../widgets/service_tile.dart';
import '../services/tool_navigator.dart';
import '../theme/app_theme.dart';
import '../widgets/balance_cards.dart';

/// 服务页：顶部居中标题，竖列卡片展示校园服务。
///
/// ⚠️ 这里仅保留**客户端能独立完成**的服务：
///    成绩查询 / 考试安排（需先登录统一认证）、无锡学院校历、我的教材、校园地图。
///    食堂速览、试卷库、自动推送、建议反馈都依赖服务端，已随开源版移除。
class ToolboxPage extends StatefulWidget {
  const ToolboxPage({super.key});

  @override
  State<ToolboxPage> createState() => _ToolboxPageState();
}

class _ToolboxPageState extends State<ToolboxPage> {

  @override
  void initState() {
    super.initState();
  }

  /// 主服务列表（竖列展示）
  static const List<ToolModel> _mainTools = [
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = context.textPrimary;
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : const Color(0xFFF5F6F8),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),
            // 顶部居中标题（取代原大黑额头）
            Center(
              child: Text(
                '服务',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: titleColor,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), // v1.7.1 统一页面边距：原 18
                itemCount: _mainTools.length + 1,
                itemBuilder: (context, index) {
                  // 第 0 项：一卡通 / 电费余额（由「我的」页移到这里，查看更顺手）
                  if (index == 0) {
                    return const Padding(
                      padding: EdgeInsets.only(bottom: 20),
                      child: BalanceCardsSection(),
                    );
                  }
                  final tool = _mainTools[index - 1];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: ServiceTile(
                      tool: tool,
                      onTap: () => _onTap(context, tool),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onTap(BuildContext context, ToolModel tool) async {
    // open 内部会先过「登录闸门」：未登录则下方弹横条并中止跳转
    await ToolNavigator.open(context, tool.id, isCloud: tool.isCloud);
  }
}
