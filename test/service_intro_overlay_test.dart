import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/models/tool_model.dart';
import 'package:xiyuan_pocket/services/service_catalog.dart';
import 'package:xiyuan_pocket/widgets/service_intro_overlay.dart';

/// 「新功能叠层卡片」的行为契约：
///   1. 一次最多展示 3 张（再多就不是眼前一亮，是要读的清单）；
///   2. 往左滑过阈值 → 当前卡片走人、回调一次、下一张顶上来；
///   3. 全部滑完 → onFinished 恰好调用一次（页面靠它写「已看过」标记）。
void main() {
  List<ToolModel> pick() => mainServices.take(3).toList();

  testWidgets('最多只展示 3 张，且第一张的名字在最上面', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final tools = pick();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          ServiceIntroOverlay(
            tools: [...tools, ...mainServices.skip(3).take(3)],
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

  testWidgets('左滑一张记一次，滑完第三张才算结束', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final tools = pick();
    final dismissed = <String>[];
    var finished = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          ServiceIntroOverlay(
            tools: tools,
            onCardDismissed: (t) => dismissed.add(t.id),
            onFinished: () => finished++,
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();

    for (final t in tools) {
      expect(find.text(t.name), findsOneWidget);
      await tester.drag(find.text(t.name), const Offset(-320, 0));
      await tester.pumpAndSettle();
    }

    expect(dismissed, tools.map((e) => e.id).toList());
    expect(finished, 1);
  });
}
