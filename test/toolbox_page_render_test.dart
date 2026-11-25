import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/service_group.dart';
import 'package:xiyuan_pocket/pages/toolbox_page.dart';
import 'package:xiyuan_pocket/services/service_catalog.dart';
import 'package:xiyuan_pocket/services/storage_service.dart';
import 'package:xiyuan_pocket/widgets/service_entry.dart';

/// 服务页（2026-11-25 改成按功能块分组 + 两列网格）的渲染回归。
///
/// 为什么值得测：这一页现在有三层「谁该出现」的判断
/// （隐藏 / 收藏 / 分组兜底），任何一层算错都会让某个服务**从页面上消失**，
/// 而 analyze 和纯 unit test 都看不出来 —— 用户在服务页找不到入口，
/// 只会以为自己手机坏了。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // 测试视口默认 800x600，而这一页是 12 个两列格子 + 四段分组标题 +
    // 余额卡，远超一屏。`ListView(children:)` 走 `SliverChildListDelegate`，
    // 屏外的孩子**根本不 build** —— 用默认视口测「12 个服务都在」会假失败
    // （实测：失败点正是 find.text 找不到第 8 个以后的服务）。
    // 所以这里把视口撑高，让整页一次性建完，测的是「渲染逻辑对不对」，
    // 而不是「ListView 省不省内存」。
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: ToolboxPage()));
    // 首帧 + _loadAll() 的异步回填。
    await tester.pumpAndSettle();
  }

  testWidgets('默认状态下 12 个服务全部可见，且分成了四个块', (tester) async {
    await pumpPage(tester);

    for (final tool in mainServices) {
      expect(
        find.text(tool.name),
        findsOneWidget,
        reason: '服务页没有渲染出「${tool.name}」',
      );
      expect(find.byType(ServiceEntry), findsWidgets);
    }

    // 四个分组标题都要在（每个组都至少有一个服务，见 service_catalog）。
    for (final g in ServiceGroup.order) {
      expect(
        find.text(ServiceGroup.titleOf(g)),
        findsOneWidget,
        reason: '缺少分组标题「${ServiceGroup.titleOf(g)}」',
      );
    }
    // 默认没有收藏，不该出现「我的收藏」块。
    expect(find.text('我的收藏'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('收藏的服务被单独提到「我的收藏」块，且不再重复出现在原组', (tester) async {
    // 拿一个非首位的服务，才能证明「提上去」而不是「本来就在最上面」。
    final target = mainServices[6];
    await StorageService.saveFavoriteServices(<String>[target.id]);
    await pumpPage(tester);

    expect(find.text('我的收藏'), findsOneWidget);
    // 关键：只出现一次。如果原组里还留着，就会出现两个同名格子，
    // 用户点哪一个都进得去，但页面看着像重复了。
    expect(
      find.text(target.name),
      findsOneWidget,
      reason: '「${target.name}」被收藏后应该在收藏块里出现一次，不能同时留在原组',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('隐藏的服务不出现，其余照常', (tester) async {
    final hidden = mainServices[3];
    await StorageService.saveHiddenServices(<String>[hidden.id]);
    await pumpPage(tester);

    expect(find.text(hidden.name), findsNothing);
    // 其它服务不受影响。
    expect(find.text(mainServices[2].name), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全部隐藏时给的是有出路的空态，不是白屏', (tester) async {
    await StorageService.saveHiddenServices(
      mainServices.map((t) => t.id).toList(),
    );
    await pumpPage(tester);

    expect(find.text('所有服务已隐藏'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
    expect(find.byType(ServiceEntry), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏（320dp）两列格子不能溢出', (tester) async {
    // 全 App 最窄的真机是 320dp（老机型 / 分屏）。两列格子在这种宽度下
    // 每格只有 135dp，扣掉 padding 剩 111dp —— 如果哪天有人给格子加了
    // 固定宽度或者塞了第三个元素，这里会先炸，而不是等用户截图。
    tester.view.physicalSize = const Size(320, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: ToolboxPage()));
    await tester.pumpAndSettle();

    // RenderFlex overflow 会以 FlutterError 记在 takeException 里。
    expect(tester.takeException(), isNull, reason: '320dp 下出现了布局溢出');
    expect(find.byType(ServiceEntry), findsNWidgets(mainServices.length));
  });

  testWidgets('按使用次数模式：用过的那项排到它所在组的第一位', (tester) async {
    await StorageService.saveServiceSortMode('usage');
    // 给同组最后一名刷 20 次。
    const groupId = ServiceGroup.academic;
    final inGroup =
        mainServices.where((t) => t.group == groupId).toList(growable: false);
    expect(inGroup.length, greaterThan(1));
    final boosted = inGroup.last;
    await StorageService.saveServiceOrder(<String>[]);

    // 直接写计数（与 ToolUsageStorage.increment 落的是同一个 key）。
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'tool_usage_cloud',
      '{"${boosted.id}": 20}',
    );

    await pumpPage(tester);

    // 位置比较：把两列的格子按出现顺序取出来，boosted 应排在原第一名之前。
    final entries = tester
        .widgetList<ServiceEntry>(find.byType(ServiceEntry))
        .map((w) => w.tool.id)
        .toList();
    final iBoosted = entries.indexOf(boosted.id);
    final iFirst = entries.indexOf(inGroup.first.id);
    expect(iBoosted, isNonNegative);
    expect(iFirst, isNonNegative);
    expect(
      iBoosted < iFirst,
      isTrue,
      reason: '使用 20 次的「${boosted.name}」应该排在「${inGroup.first.name}」前面',
    );
    expect(tester.takeException(), isNull);
  });
}
