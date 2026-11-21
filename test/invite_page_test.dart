import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiyuan_pocket/pages/invite/invite_page.dart';

/// 邀请页加载链路回归：
/// - 页面必须能正常构建，不抛未捕获异常；
/// - 未登录 / 无网络环境下，加载态必须收敛到降级内容，不能一直转圈。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  testWidgets('邀请页可构建并从加载态收敛', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: InvitePage()),
    ));

    // 首帧：AppBar 与页面骨架必须在。
    expect(find.text('邀请同学'), findsOneWidget);

    // 跑真实微任务（本地存储读取、被捕获的插件/网络异常）后再推进帧。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();

    // 加载态必须收敛：不能只剩转圈。
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // 绑定卡位于 ListView 底部，离屏也应已构建。
    expect(find.text('我有邀请码', skipOffstage: false), findsOneWidget);

    // 内容不足一屏时仍要能下拉刷新，否则降级后用户没有重试手势。
    final listView = tester.widget<ListView>(find.byType(ListView));
    expect(listView.physics, isA<AlwaysScrollableScrollPhysics>());
  });
}
