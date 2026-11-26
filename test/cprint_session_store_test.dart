import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:xiyuan_pocket/services/campus/cprint_session_store.dart';

/// 云打印会话缓存的回归测试。
///
/// 这一层 2026-11-25 出过一次真事故：只缓存 `OSESSIONID`，而校外走 WebVPN 时
/// 站点 cookie 被网关吞掉 → 授权明明成功却判成「站点没有下发会话」。
/// 改成缓存整份罐之后，这几个不变量必须锁死：
///   · 换了网络模式不能拿旧罐去试（校内 OSESSIONID 与网关票不通用）
///   · 换了账号必须清，绝不能把上一个人的会话给下一个人
///   · 空罐不落盘、坏数据当未命中，都不许抛异常
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    await CprintSessionStore.clear();
  });

  Map<String, String> jarOf(String value) => <String, String>{
        'OSESSIONID': value,
        'SESSIONID': 'sess-$value',
      };

  test('存进去的整份罐能原样读回来', () async {
    await CprintSessionStore.save('25350103',
        mode: 'direct', cookies: jarOf('abc123'));
    final got = await CprintSessionStore.load('25350103', mode: 'direct');
    expect(got, isNotNull);
    expect(got!['OSESSIONID'], 'abc123');
    expect(got['SESSIONID'], 'sess-abc123');
  });

  test('校外存的是网关票，同样能读回来（这就是当初救不回来的那种罐）', () async {
    await CprintSessionStore.save('25350103', mode: 'webvpn', cookies: {
      'wengine_vpn_ticketwebvpn_cwxu_edu_cn': 'deadbeef',
      'refresh': '1',
    });
    final got = await CprintSessionStore.load('25350103', mode: 'webvpn');
    expect(got, isNotNull);
    expect(got!['wengine_vpn_ticketwebvpn_cwxu_edu_cn'], 'deadbeef');
  });

  test('换了网络模式就不命中：校内的罐不能拿去校外试', () async {
    await CprintSessionStore.save('25350103',
        mode: 'direct', cookies: jarOf('abc123'));
    final got = await CprintSessionStore.load('25350103', mode: 'webvpn');
    expect(got, isNull);
  });

  test('换了账号必须清空，绝不串号', () async {
    await CprintSessionStore.save('25350103',
        mode: 'direct', cookies: jarOf('abc123'));
    final got = await CprintSessionStore.load('99999999', mode: 'direct');
    expect(got, isNull);
    // 旧账号的罐已经被删掉
    final back = await CprintSessionStore.load('25350103', mode: 'direct');
    expect(back, isNull);
  });

  test('空罐不落盘', () async {
    await CprintSessionStore.save('25350103',
        mode: 'direct', cookies: const <String, String>{});
    expect(await CprintSessionStore.load('25350103', mode: 'direct'), isNull);
  });

  test('全是空值的罐也不落盘', () async {
    await CprintSessionStore.save('25350103',
        mode: 'direct', cookies: const <String, String>{'OSESSIONID': '   '});
    expect(await CprintSessionStore.load('25350103', mode: 'direct'), isNull);
  });

  test('学号为空时不写、也不读', () async {
    await CprintSessionStore.save('   ',
        mode: 'direct', cookies: jarOf('abc'));
    expect(await CprintSessionStore.load('', mode: 'direct'), isNull);
  });

  test('清空之后读不到，并且旧版本的 OSESSIONID 键也一起删掉', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'cprint_osession': 'old',
      'cprint_osession_at': '2026-11-01T00:00:00.000',
      'cprint_osession_owner': '25350103',
    });
    await CprintSessionStore.save('25350103',
        mode: 'direct', cookies: jarOf('abc123'));
    await CprintSessionStore.clear();

    expect(await CprintSessionStore.load('25350103', mode: 'direct'), isNull);
    const secure = FlutterSecureStorage();
    expect(await secure.read(key: 'cprint_osession'), isNull);
    expect(await secure.read(key: 'cprint_osession_owner'), isNull);
    expect(await secure.read(key: 'cprint_cookies'), isNull);
  });

  test('罐里存的是坏 JSON 时当未命中处理，不抛异常', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'cprint_cookies': 'not-json',
      'cprint_cookies_at': DateTime.now().toIso8601String(),
      'cprint_cookies_owner': '25350103',
      'cprint_cookies_mode': 'direct',
    });
    expect(await CprintSessionStore.load('25350103', mode: 'direct'), isNull);
  });
}
