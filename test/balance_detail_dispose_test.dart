import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/pages/balance_detail_pages.dart';
import 'package:xiyuan_pocket/services/dorm_service.dart';

/// 一卡通明细页「进页面立刻按返回」回归测试。
///
/// 钉住一个真实的崩溃路径：
///   `_init()` 里 `await ensureFresh()` 与 `await loadTurnoverCache()` 之间
///   有几秒的异步间隙（网络模式探测），用户在这期间返回，
///   随后 `_fetch(refresh: true)` 第一件事就是裸 `setState(...)` ——
///   落在已 dispose 的 State 上，报 `setState() called after dispose()`。
///
/// 修法：`_fetch` 入口加 `if (!mounted) return false;`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    // 每个用例后必须还原，否则会污染其它测试（它是全局 static 钩子）
    DormService.debugEnsureNetworkFresh = null;
  });

  testWidgets('网络探测还没回来就返回 → 不能崩', (tester) async {
    final gate = Completer<void>();
    DormService.debugEnsureNetworkFresh = () => gate.future;

    await tester.pumpWidget(
      const MaterialApp(home: CardBalancePage(balance: 12.34)),
    );

    // 首帧已画出，_init() 正挂在 ensureFresh() 上
    expect(tester.takeException(), isNull);

    // 用户在这个间隙里返回 —— 页面被换掉，State 被 dispose
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    // 让被挂起的探测完成，_init 继续往下跑到 _fetch
    gate.complete();
    await tester.pumpAndSettle();

    // 修复前这里会抛 setState() called after dispose()
    expect(tester.takeException(), isNull);
  });
}
