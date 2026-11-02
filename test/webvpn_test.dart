import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/campus/campus_session.dart';
import 'package:xiyuan_pocket/services/campus/webvpn.dart';

/// WebVPN 协议层对拍。
///
/// 向量来源分两类：
///  - `my/wxcas.cwxu.edu.cn`、`10.3.100.110` = 本校实测样本（参考仓库
///    `Wxxy-CampusHub/crates/campus-webvpn/src/crypto.rs` 的 golden 向量）；
///  - 其余为社区通行的深澜 WebVPN 向量，用来防「只对本校几个串碰巧对上」。
///
/// `10.3.100.110` 是我们电费/一卡通的内网地址，这条必须过。
void main() {
  group('AES-128-CFB host 加解密', () {
    const cases = <String, String>{
      'my.cwxu.edu.cn':
          '77726476706e69737468656265737421fdee0f9f30287d1e7b0c9ce29b5b',
      'wxcas.cwxu.edu.cn':
          '77726476706e69737468656265737421e7ef429d347e6b47661dc7a99c406d3676',
      '10.3.100.110':
          '77726476706e69737468656265737421a1a70fcf696138003059d8fc',
      '202.204.48.66':
          '77726476706e69737468656265737421a2a713d275603c1e2a50c7face',
      '219.216.96.4':
          '77726476706e69737468656265737421a2a618d275613e1e275ec7f8',
      'space.bilibili.com':
          '77726476706e69737468656265737421e3e7409f227e6a5972018ba5945c6d36db05',
    };

    cases.forEach((host, want) {
      test('加密 $host', () {
        expect(WebVpn.encryptHost(host), want);
      });
      test('解密 $host', () {
        expect(WebVpn.decryptHost(want), host);
      });
    });

    test('密文长度 = 明文长度（CFB 无 padding）', () {
      expect(WebVpn.encryptHost('my.cwxu.edu.cn').length, 32 + 14 * 2);
      expect(WebVpn.encryptHost('10.3.100.110').length, 32 + 12 * 2);
    });
  });

  group('URL 包装', () {
    const hex103 =
        '77726476706e69737468656265737421a1a70fcf696138003059d8fc';

    test('内网地址 + path + query', () {
      expect(
        WebVpn.wrapUrl('http://10.3.100.110/charge/feeitem?a=1&b=2'),
        '${WebVpn.gateway}/http/$hex103/charge/feeitem?a=1&b=2',
      );
    });

    test('根路径补斜杠', () {
      expect(
        WebVpn.wrapUrl('http://10.3.100.110'),
        '${WebVpn.gateway}/http/$hex103/',
      );
    });

    test('非默认端口写成 scheme-port', () {
      expect(
        WebVpn.wrapUrl('http://10.3.100.110:8080/x'),
        '${WebVpn.gateway}/http-8080/$hex103/x',
      );
    });

    test('公网地址不包装', () {
      const raw = 'https://wxcas.cwxu.edu.cn/lyuapServer/login';
      expect(WebVpn.wrapUrl(raw), raw);
    });

    test('幂等：已包装的再包一次原样返回', () {
      final once = WebVpn.wrapUrl('http://10.3.100.110/a');
      expect(WebVpn.wrapUrl(once), once);
    });

    test('needsWrap 只认内网段', () {
      expect(WebVpn.needsWrap('http://10.3.100.110/x'), isTrue);
      expect(WebVpn.needsWrap('http://192.168.1.2/x'), isTrue);
      expect(WebVpn.needsWrap('http://172.20.0.1/x'), isTrue);
      expect(WebVpn.needsWrap('http://172.32.0.1/x'), isFalse);
      expect(WebVpn.needsWrap('https://jwgl.cwxu.edu.cn/x'), isFalse);
    });
  });

  group('重定向下一跳（VPN 换票链的关键一跳）', () {
    const hex103 =
        '77726476706e69737468656265737421a1a70fcf696138003059d8fc';
    const rawLogin =
        'http://10.3.100.110/berserker-auth/cas/login/lyCas?targetUrl=x';

    test('相对 Location 相对原始内网地址解析', () {
      expect(
        CampusSession.nextHop(rawLogin, '/plat/?ticket=ABCD'),
        'http://10.3.100.110/plat/?ticket=ABCD',
      );
    });

    test('解析后再包装，/http/<hex> 前缀不会丢', () {
      final next = CampusSession.nextHop(rawLogin, '/plat/?ticket=ABCD');
      expect(
        WebVpn.wrapUrl(next),
        '${WebVpn.gateway}/http/$hex103/plat/?ticket=ABCD',
      );
    });

    test('绝对 Location（含网关域）原样保留', () {
      const abs = 'https://webvpn.cwxu.edu.cn/login?cas_login=true';
      expect(CampusSession.nextHop(rawLogin, abs), abs);
      expect(WebVpn.wrapUrl(abs), abs);
    });
  });
}
