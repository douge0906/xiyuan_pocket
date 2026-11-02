import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/device_identity.dart';

/// 伪名算法必须与服务端一致，否则断言登录会被判 `invalid_alias`。
///
/// 期望值来自服务端 tools/smoke.py 的实际输出（学号 20260001），
/// 属于跨语言对拍，改任何一侧都会让这条测试失败。
void main() {
  test('学号伪名与服务端一致', () {
    expect(
      DeviceIdentity.studentAlias('20260001'),
      '7c781e11a996ccbd5780edcf2fc8ab7aae7a4763dda67f114357df5f0c438f68',
    );
  });

  test('伪名是 64 位小写十六进制', () {
    final alias = DeviceIdentity.studentAlias('2026123456');
    expect(alias.length, 64);
    expect(RegExp(r'^[0-9a-f]+$').hasMatch(alias), isTrue);
  });
}
