import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/service_group.dart';
import 'package:xiyuan_pocket/models/tool_model.dart';
import 'package:xiyuan_pocket/pages/service_settings_page.dart';
import 'package:xiyuan_pocket/services/service_catalog.dart';
import 'package:xiyuan_pocket/services/storage_service.dart';

/// 「设置页 → 服务管理」空白异常的回归测试。
///
/// 这个页面 2026-11-03 加了拖动排序（`ReorderableListView.builder` 放进
/// `ListView` 的一格里）。只要布局约束给错，整页就会白屏 —— 而 `analyze`
/// 和 `flutter test` 的其它用例都发现不了，因为没人真的把它 build 出来。
///
/// 2026-11-25 又加了「收藏星标 + 排序模式选择」，所以这里同时钉住：
/// 加星、切排序模式都不能把行挤掉。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('服务管理页必须真的渲染出全部服务，不能白屏', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ServiceSettingsPage(hidden: <String>[]),
    ));
    // 首帧 + _loadOrder() 的异步回填。
    await tester.pumpAndSettle();

    // 🟥 白屏断言：一个服务名都找不到就是空白。
    for (final tool in mainServices) {
      expect(
        find.text(tool.name),
        findsOneWidget,
        reason: '服务管理页没有渲染出「${tool.name}」——页面空白',
      );
    }

    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(find.byType(Switch), findsNWidgets(mainServices.length));
    // 每个服务一颗收藏星（2026-11-25 新增）。
    expect(find.byIcon(Icons.star_border_rounded),
        findsNWidgets(mainServices.length));
    // 没有任何一条布局异常逃出来。
    expect(tester.takeException(), isNull);
  });

  testWidgets('隐藏过的服务仍然渲染，只是开关是关的', (tester) async {
    final hiddenId = mainServices.first.id;
    await tester.pumpWidget(MaterialApp(
      home: ServiceSettingsPage(hidden: <String>[hiddenId]),
    ));
    await tester.pumpAndSettle();

    expect(find.text(mainServices.first.name), findsOneWidget);
    expect(find.text('已隐藏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已收藏的服务显示实心星', (tester) async {
    final favId = mainServices.first.id;
    await tester.pumpWidget(MaterialApp(
      home: ServiceSettingsPage(
        hidden: const <String>[],
        favorites: <String>[favId],
      ),
    ));
    await tester.pumpAndSettle();

    // 一颗实心 + 其余全是空心。
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    expect(find.byIcon(Icons.star_border_rounded),
        findsNWidgets(mainServices.length - 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('点星标会落盘，并且不影响显示开关', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ServiceSettingsPage(hidden: <String>[]),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.star_border_rounded).first);
    await tester.pumpAndSettle();

    final saved = await StorageService.loadFavoriteServices();
    expect(saved, <String>[mainServices.first.id]);
    // 显示开关仍然全开（点星标不该顺手把服务隐藏）。
    expect(await StorageService.loadHiddenServices(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切到「按使用次数」后拖动把手消失，且模式落盘', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ServiceSettingsPage(hidden: <String>[]),
    ));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.drag_handle_rounded),
        findsNWidgets(mainServices.length));

    await tester.tap(find.text('按使用次数'));
    await tester.pumpAndSettle();

    // 使用模式下顺序由次数决定，拖动无意义 —— 把手必须收起来，
    // 否则用户拖了半天发现没反应，会以为坏了。
    expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);
    expect(await StorageService.loadServiceSortMode(), 'usage');
    expect(tester.takeException(), isNull);
  });

  group('分组与排序（纯函数，不依赖 UI）', () {
    test('每个服务都必须有合法分组，不能落到默认里', () {
      final ids = mainServices.map((t) => t.id).toSet();
      expect(ids.length, mainServices.length, reason: '服务 id 不能重复');
      for (final tool in mainServices) {
        expect(
          ServiceGroup.order.contains(tool.group),
          isTrue,
          reason: '${tool.name} 的 group「${tool.group}」不在 ServiceGroup.order 里，'
              '它会被兜到「校园与生活」组，读起来别扭',
        );
      }
    });

    test('四组都有服务，分组标题不会是空的', () {
      for (final g in ServiceGroup.order) {
        final count = mainServices.where((t) => t.group == g).length;
        expect(count, greaterThan(0), reason: '分组「${ServiceGroup.titleOf(g)}」一个服务都没有');
        expect(ServiceGroup.titleOf(g).isNotEmpty, isTrue);
      }
    });

    test('分组顺序稳定，标题不重复', () {
      expect(ServiceGroup.order, <String>[
        ServiceGroup.academic,
        ServiceGroup.study,
        ServiceGroup.tools,
        ServiceGroup.campus,
      ]);
      final titles = ServiceGroup.order.map(ServiceGroup.titleOf).toList();
      expect(titles.toSet().length, titles.length, reason: '分组标题重复');
    });

    test('按使用次数排序：次数降序，同次数保持原序', () {
      // 复刻 _ToolboxPageState._sortedTools 的排序规则（它就是这几行）。
      final manual = List<ToolModel>.of(mainServices);
      final counts = <String, int>{
        manual[5].id: 9,
        manual[2].id: 4,
      };
      final indexed = <String, int>{
        for (var i = 0; i < manual.length; i++) manual[i].id: i
      };
      final sorted = List<ToolModel>.of(manual);
      sorted.sort((a, b) {
        final ca = counts[a.id] ?? 0;
        final cb = counts[b.id] ?? 0;
        if (ca != cb) return cb.compareTo(ca);
        return (indexed[a.id] ?? 0).compareTo(indexed[b.id] ?? 0);
      });
      // 前两名是点过的那两个，按次数降序。
      expect(sorted[0].id, manual[5].id);
      expect(sorted[1].id, manual[2].id);
      // 其余保持清单原序（把前两位剔掉后应完全一致）。
      final rest = manual
          .where((t) => t.id != manual[5].id && t.id != manual[2].id)
          .map((t) => t.id)
          .toList();
      expect(sorted.skip(2).map((t) => t.id).toList(), rest);
    });
  });
}
