import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/pages/message_settings_page.dart';
import 'package:xiyuan_pocket/services/message_repository.dart';
import 'package:xiyuan_pocket/services/storage_service.dart';

/// 「我的 → 设置 → 消息设置」这条入口**不带** repository（消息页的实例拿不到），
/// 走的是 `repo == null` 分支：只写盘 + 广播信号。
///
/// 这条测试锁的是那个漏洞：此前只写盘、不广播，消息页仓库里的 `_autoRefresh`
/// 内存镜像仍是旧值 —— 用户关掉开关、退出去进消息页，照样联网；要杀进程重启
/// 才生效。现在消息页订阅 `MessageSettingsSignals.autoRefreshChanged` 并重读。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MessageSettingsSignals.autoRefreshChanged.value = 0;
  });

  testWidgets('不带 repository 拨开关：写盘 + 广播信号', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MessageSettingsPage()));
    await tester.pumpAndSettle();

    expect(await StorageService.loadMessageAutoRefresh(), isTrue,
        reason: '默认是开');
    expect(MessageSettingsSignals.autoRefreshChanged.value, 0);

    // 开关是页面里唯一一个 Switch 控件
    final sw = find.byType(Switch);
    expect(sw, findsOneWidget, reason: '消息设置首屏只有一个开关');
    expect(tester.widget<Switch>(sw).value, isTrue);

    await tester.tap(sw);
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(await StorageService.loadMessageAutoRefresh(), isFalse,
        reason: '必须写盘，否则下次启动读回旧值');
    expect(MessageSettingsSignals.autoRefreshChanged.value, 1,
        reason: '必须广播，否则消息页的内存镜像仍是旧值');
  });

  test('消息页收到信号后重读，仓库的内存镜像跟着变', () async {
    final repo = MessageRepository();
    await repo.initSettings();
    expect(repo.autoRefresh, isTrue, reason: '默认是开');

    // 模拟「另一个入口改了设置」：写盘 + 广播；消息页的监听回调做的事就是
    // 再调一次 `initSettings()`（幂等，只读存储 + notify）。
    await StorageService.saveMessageAutoRefresh(false);
    await repo.initSettings();

    expect(repo.autoRefresh, isFalse, reason: '重读之后必须跟盘走');
    repo.dispose();
  });
}
