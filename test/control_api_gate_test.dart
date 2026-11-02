import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiyuan_pocket/constants/control_config.dart';
import 'package:xiyuan_pocket/services/control_api.dart';

/// 控制端门禁的回归测试。
///
/// 这一层是"看不见的联网"的唯一开关。它坏掉的后果比功能缺失严重得多：
/// 未登录的用户会在毫不知情的情况下产生网络请求。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    // 安全存储是平台插件，单测里用内存假实现顶替（read 一律返回 null）。
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

  group('ControlApi 门禁', () {
    test('未登录本机账号时：门禁关闭，任何请求直接返回 null', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await ControlApi.allowed(), isFalse);
      expect(await ControlApi.getJson(ControlConfig.pathMessages), isNull);
      expect(
        await ControlApi.postJson(ControlConfig.pathDeviceRegister, {}),
        isNull,
      );
    });

    test('已登录时门禁打开，但服务不可达要静默返回 null（不抛异常）', () async {
      SharedPreferences.setMockInitialValues({
        'user_username': 'tester',
        'user_remember_password': false, // 免去读密码，避免依赖安全存储
      });
      expect(await ControlApi.allowed(), isTrue);

      // 只断言"不抛异常且返回 null"，不依赖网络是否真的可用。
      await expectLater(
        ControlApi.getJson(ControlConfig.pathHealth),
        completion(isNull),
      );
    });
  });
}
