import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/device_identity.dart';

/// 安装标识的派生规则（2026-11-01 设备去重）。
///
/// 背景：以前 installation_id 是纯随机 16 字节，卸载即失效 ——
/// 用户每重装一次，控制台就多一台「新设备」，还会累积多设备风控记录。
/// 现在改成优先从 ANDROID_ID 派生：重装后仍是同一个标识。
///
/// 这些测试锁住三件事：
/// 1. 有 ANDROID_ID 时，派生结果稳定且带 `xiyuan-` 前缀（能和老随机 id 区分）
/// 2. 同一 ANDROID_ID 永远得到同一结果（否则去重白做）
/// 3. 通道不可用 / 返回空时能退回随机，不把功能卡死
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('xiyuan/device_id');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  /// 装载一个假的 androidId 返回值（null = 通道返回空）。
  void mockAndroidId(String? value) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'androidId') return value;
      return null;
    });
  }

  /// 复刻 DeviceIdentity 里的派生算法，用于对拍。
  ///
  /// 这里刻意逐字重写而不是抽出公共方法：要验证的是「写进代码里的算法
  /// 到底产出什么」，如果两边都调同一个函数，测试就变成了同义反复。
  String expected(String androidId) {
    final digest = _sha256(utf8.encode('xiyuan-device|$androidId'));
    return 'xiyuan-${base64Url.encode(digest.sublist(0, 16)).replaceAll('=', '')}';
  }

  test('同一 ANDROID_ID 派生结果稳定，且带 xiyuan- 前缀', () async {
    mockAndroidId('9774d56d682e549c');
    final a = await DeviceIdentity.debugDeriveInstallId();
    final b = await DeviceIdentity.debugDeriveInstallId();

    expect(a, b, reason: '同样的输入必须得到同样的安装标识');
    expect(a, startsWith('xiyuan-'), reason: '要和历史随机 id 区分开');
    expect(a, expected('9774d56d682e549c'));
  });

  test('不同 ANDROID_ID 派生出不同标识', () async {
    mockAndroidId('9774d56d682e549c');
    final a = await DeviceIdentity.debugDeriveInstallId();
    mockAndroidId('0000000000000000');
    final b = await DeviceIdentity.debugDeriveInstallId();

    expect(a, isNot(b));
  });

  test('派生结果不包含明文 ANDROID_ID', () async {
    const androidId = '9774d56d682e549c';
    mockAndroidId(androidId);
    final id = await DeviceIdentity.debugDeriveInstallId();

    expect(id.contains(androidId), isFalse, reason: '原值不能出设备');
  });

  test('通道返回空时退回随机标识', () async {
    mockAndroidId(null);
    final a = await DeviceIdentity.debugDeriveInstallId();
    final b = await DeviceIdentity.debugDeriveInstallId();

    expect(a, isNotEmpty);
    expect(a.startsWith('xiyuan-'), isFalse, reason: '随机兜底不带前缀');
    expect(a, isNot(b), reason: '随机兜底每次都不一样');
  });

  test('通道抛异常时也能退回随机，不抛出', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'unavailable');
    });

    final id = await DeviceIdentity.debugDeriveInstallId();
    expect(id, isNotEmpty);
    expect(id.startsWith('xiyuan-'), isFalse);
  });
}

/// 与 DeviceIdentity 内部同一个 SHA-256（pointycastle），保持对拍一致。
List<int> _sha256(List<int> data) {
  // 直接复用业务实现暴露的摘要函数，避免在这里再引一份 pointycastle。
  return DeviceIdentity.debugSha256(data);
}
