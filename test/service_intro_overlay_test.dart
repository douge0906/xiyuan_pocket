import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/models/tool_model.dart';
import 'package:xiyuan_pocket/services/service_catalog.dart';
import 'package:xiyuan_pocket/widgets/service_intro_overlay.dart';

/// 「新功能叠层卡片」的行为契约（2026-11-27 改版）：
///   1. 一次最多展示 3 张（再多就不是眼前一亮，是要读的清单）；
///   2. 往左滑过阈值 → 记成「启用」；往右滑 → 记成「不启用」；
///   3. 全部处理完 → onFinished 恰好一次（页面靠它把遮罩收掉）。
void main() {
  List<ToolModel> pick() => mainServices.take(3).toList();

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('最多只展示 3 张，且第一张的名字在最上面', (tester) async {
    phone(tester);
    final tools = pick();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          ServiceIntroOverlay(
            tools: [...tools, ...mainServices.skip(3).take(3)],
            onDecided: (_, __) {},
            onFinished: () {},
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text(tools.first.name), findsOneWidget);
    // 第 4 张及以后不该出现
    expect(find.text(mainServices[5].name), findsNothing);
  });

  testWidgets('左滑=启用、右滑=不启用，逐张记录且 finally 只结束一次', (tester) async {
    phone(tester);
    final tools = pick();
    final decided = <(String, bool)>[];
    var finished = 0;
    await tester.pumpWidget(_Host(
      tools: tools,
      onDecided: (t, enabled) => decided.add((t.id, enabled)),
      onFinished: () => finished++,
    ));
    await tester.pumpAndSettle();

    // 前两张往左滑（启用），第三张往右滑（不启用）。
    for (var i = 0; i < tools.length; i++) {
      expect(find.text(tools[i].name), findsOneWidget);
      final dx = i == tools.length - 1 ? 320.0 : -320.0;
      await tester.drag(find.text(tools[i].name), Offset(dx, 0));
      await tester.pumpAndSettle();
    }

    expect(decided, [
      (tools[0].id, true),
      (tools[1].id, true),
      (tools[2].id, false),
    ]);
    expect(finished, 1);
  });

  testWidgets('两张淡按钮也能做决定（不依赖手势）', (tester) async {
    phone(tester);
    final tools = pick().take(1).toList();
    final decided = <(String, bool)>[];
    await tester.pumpWidget(_Host(
      tools: tools,
      onDecided: (t, enabled) => decided.add((t.id, enabled)),
      onFinished: () {},
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('不启用'));
    await tester.pumpAndSettle();

    expect(decided, [(tools.first.id, false)]);
  });
}

/// 父级（toolbox_page）的真实行为：决定一张就从列表里摘一张，摘空了就收摊。
/// 叠层卡片自己不改 tools，否则它和父级会各持一份真相。
class _Host extends StatefulWidget {
  const _Host({
    required this.tools,
    required this.onDecided,
    required this.onFinished,
  });

  final List<ToolModel> tools;
  final void Function(ToolModel tool, bool enabled) onDecided;
  final VoidCallback onFinished;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late List<ToolModel> _tools = List<ToolModel>.of(widget.tools);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          ServiceIntroOverlay(
            tools: _tools,
            onDecided: (tool, enabled) {
              widget.onDecided(tool, enabled);
              setState(() {
                _tools = _tools.where((e) => e.id != tool.id).toList();
              });
            },
            onFinished: widget.onFinished,
          ),
        ]),
      ),
    );
  }
}
