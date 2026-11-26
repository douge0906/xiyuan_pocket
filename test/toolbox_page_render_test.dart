import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/service_group.dart';
import 'package:xiyuan_pocket/pages/toolbox_page.dart';
import 'package:xiyuan_pocket/services/service_catalog.dart';
import 'package:xiyuan_pocket/services/storage_service.dart';
import 'package:xiyuan_pocket/widgets/service_entry.dart';
import 'package:xiyuan_pocket/widgets/service_tile.dart';

/// 服务页的渲染回归。
///
/// 两种形态（2026-11-25 用户 m11197）：
/// - **默认 = 单列平铺**（`ServiceTile`），跟历史版本一致；
/// - **打开「按用途分组」后 = 四块两列格子**（`ServiceEntry`）。
///
/// 这一页有三层「谁该出现」的判断（隐藏 / 收藏 / 分组兜底），任何一层算错
/// 都会让某个服务**从页面上消失** —— analyze 和纯 unit test 都看不出来，
/// 用户在服务页找不到入口只会以为手机坏了，所以这里有渲染回归。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // 测试视口默认 800x600，而这一页是余额卡 + 12 个服务，远超一屏。
    // `ListView` 屏外的孩子**根本不 build** —— 用默认视口测「12 个都在」
    // 会假失败（实测失败点正是 find.text 找不到第 8 个以后的服务）。
    // 所以把视口撑高，测的是「渲染逻辑对不对」而不是「ListView 省不省内存」。
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: ToolboxPage()));
    // 首帧 + _loadAll() 的异步回填。
    await tester.pumpAndSettle();
  }

  Future<void> enableGrouped() async {
    await StorageService.saveServicesGrouped(true);
  }

  testWidgets('默认是单列平铺：12 个服务全部可见，且没有分组标题', (tester) async {
    await pumpPage(tester);

    for (final tool in mainServices) {
      expect(
        find.text(tool.name),
        findsOneWidget,
        reason: '服务页没有渲染出「${tool.name}」',
      );
    }
    // 默认形态是用户熟悉的一列卡片，不是格子。
    expect(find.byType(ServiceTile), findsNWidgets(mainServices.length));
    expect(find.byType(ServiceEntry), findsNothing);
    // 分组标题不该出现（用户要「改回原样」）。
    for (final g in ServiceGroup.order) {
      expect(find.text(ServiceGroup.titleOf(g)), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开「按用途分组」后才变成四块两列格子', (tester) async {
    await enableGrouped();
    await pumpPage(tester);

    for (final tool in mainServices) {
      expect(find.text(tool.name), findsOneWidget);
    }
    expect(find.byType(ServiceEntry), findsNWidgets(mainServices.length));
    expect(find.byType(ServiceTile), findsNothing);
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

  testWidgets('收藏在两种形态下都钉在最上面', (tester) async {
    // 拿一个非首位的服务，才能证明「提上去」而不是「本来就在最上面」。
    final target = mainServices[6];
    await StorageService.saveFavoriteServices(<String>[target.id]);

    // ① 单列形态：目标服务应该排在第一条服务的位置。
    await pumpPage(tester);
    final tiles = tester
        .widgetList<ServiceTile>(find.byType(ServiceTile))
        .map((w) => w.tool.id)
        .toList();
    expect(tiles.first, target.id, reason: '收藏的「${target.name}」没有排到最前面');
    expect(find.text(target.name), findsOneWidget);

    // ② 分组形态：进「我的收藏」块，且不能重复出现在原组。
    //
    // ⚠️ 必须先卸载再重挂：`pumpWidget(const MaterialApp(home: ToolboxPage()))`
    //    两次传入的是**同一个 const 实例**，Flutter 会复用 Element、不重跑
    //    initState，`_loadAll()` 就不会再读一次存储 —— 于是 _grouped 还是 false，
    //    这里会假失败（"我的收藏" 找不到）。先 pump 一个别的 widget 强制 dispose。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    await enableGrouped();
    await pumpPage(tester);
    expect(find.text('我的收藏'), findsOneWidget);
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
    expect(find.text(mainServices[2].name), findsOneWidget);
    expect(find.byType(ServiceTile), findsNWidgets(mainServices.length - 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('全部隐藏时给的是有出路的空态，不是白屏', (tester) async {
    await StorageService.saveHiddenServices(
      mainServices.map((t) => t.id).toList(),
    );
    await pumpPage(tester);

    expect(find.text('所有服务已隐藏'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
    expect(find.byType(ServiceTile), findsNothing);
    expect(find.byType(ServiceEntry), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏（320dp）分组形态的两列格子不能溢出', (tester) async {
    // 全 App 最窄的真机是 320dp（老机型 / 分屏）。两列格子在这种宽度下
    // 每格只有 135dp，扣掉 padding 剩 111dp —— 如果哪天有人给格子加了
    // 固定宽度或者塞了第三个元素，这里会先炸，而不是等用户截图。
    await enableGrouped();
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

  testWidgets('按使用次数模式：用过的那项排到最前面', (tester) async {
    await StorageService.saveServiceSortMode('usage');
    final boosted = mainServices.last;
    await StorageService.saveServiceOrder(<String>[]);

    // 直接写计数（与 ToolUsageStorage.increment 落的是同一个 key）。
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tool_usage_cloud', '{"${boosted.id}": 20}');

    await pumpPage(tester);

    final tiles = tester
        .widgetList<ServiceTile>(find.byType(ServiceTile))
        .map((w) => w.tool.id)
        .toList();
    expect(
      tiles.first,
      boosted.id,
      reason: '使用 20 次的「${boosted.name}」应该排在最前面',
    );
    expect(tester.takeException(), isNull);
  });
}
