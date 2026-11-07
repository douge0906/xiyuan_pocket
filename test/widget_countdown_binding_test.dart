import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiyuan_pocket/services/countdown_store.dart';
import 'package:xiyuan_pocket/services/widget_sync_service.dart';

/// 2026-11-05（用户 m24495 #3「两者都要」）：倒数日多实例绑定。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = <String, Object?>{};

  setUp(() {
    store.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('home_widget'),
            (call) async {
      switch (call.method) {
        case 'saveWidgetData':
          store['${call.arguments['id']}'] = call.arguments['data'];
          return true;
        case 'getWidgetData':
          return store['${call.arguments['id']}'];
        default:
          return null;
      }
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('wxxy/widget_status'),
            (call) async {
      if (call.method == 'renderNow') return <String, int>{};
      if (call.method == 'pinCountdown') return true;
      return null;
    });
  });

  test('没有绑定记录时返回空列表（跟随默认最近 3 条）', () async {
    expect(await WidgetSyncService.countdownBinding(101), isEmpty);
  });

  test('绑定写入后能按实例读回，互不影响', () async {
    await WidgetSyncService.setCountdownBinding(101, ['a', 'b']);
    await WidgetSyncService.setCountdownBinding(202, ['c']);
    expect(await WidgetSyncService.countdownBinding(101), ['a', 'b']);
    expect(await WidgetSyncService.countdownBinding(202), ['c']);
    // 存储键必须带 appWidgetId，否则两个实例会互相覆盖。
    expect(store.keys, containsAll(<String>['cd_binding_101', 'cd_binding_202']));
  });

  test('清空绑定 = 回到默认行为', () async {
    await WidgetSyncService.setCountdownBinding(101, ['a']);
    await WidgetSyncService.setCountdownBinding(101, <String>[]);
    expect(await WidgetSyncService.countdownBinding(101), isEmpty);
    expect(jsonDecode(store['cd_binding_101'] as String), isEmpty);
  });

  test('损坏的绑定 JSON 不会让整个组件崩掉', () async {
    store['cd_binding_101'] = '{ 这不是合法 JSON';
    expect(await WidgetSyncService.countdownBinding(101), isEmpty);
  });

  test('pinCountdownWidget 把选中的 id 传给原生', () async {
    expect(await WidgetSyncService.pinCountdownWidget(['x', 'y']), isTrue);
  });

  test('syncCountdownWidget 下发 slot0/slot1 两个固定条目', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final s = CountdownStore.instance;
    // 清成已知状态：Singleton 可能已被别的用例碰过。
    for (final e in List.of(s.items)) {
      await s.remove(e.id);
    }
    final d0 = DateTime(2026, 12, 1);
    final d1 = DateTime(2026, 12, 25);
    await s.add(CountdownItem(
        id: CountdownStore.slotId(0), title: '期末考试', date: d0));
    await s.add(CountdownItem(
        id: CountdownStore.slotId(1), title: '回家', date: d1));
    await WidgetSyncService.syncCountdownWidget();

    final raw = store['widget_countdown_data'] as String;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    expect((json['slot0'] as Map)['title'], '期末考试');
    expect((json['slot1'] as Map)['title'], '回家');
    expect((json['slot0'] as Map)['id'], 'cd_widget_slot_0');
    expect((json['slot1'] as Map)['id'], 'cd_widget_slot_1');
  });
}
