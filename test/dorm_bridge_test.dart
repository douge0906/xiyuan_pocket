import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:xiyuan_pocket/services/campus/jwgl_client.dart'
    show CampusException;
import 'package:xiyuan_pocket/services/dorm_bridge.dart';
import 'package:xiyuan_pocket/services/dorm_web_client.dart';

/// Web 端「浏览器内网桥接」的单测（2026-11-25）。
///
/// 桥接的三条硬约束都用假 driver 钉死：
///  ① 占位窗必须**同步**开在最前面（弹窗拦截只看用户手势）；
///  ② 导航顺序必须是 网关登录页 →（等 settle）→ 桥页；
///  ③ 结果只认网关 origin 回传的 `xiyuan-bridge / dorm-result` 结构。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
    DormWebClient.debugClient = null;
    DormBridge.driver = const RealBridgeDriver();
    DormBridge.resultTimeout = const Duration(seconds: 30);
  });

  const ticketBody = <String, dynamic>{
    'ok': true,
    'gateway_origin': 'https://webvpn.cwxu.edu.cn',
    'bridge_path': '/https/deadbeef/api/v1/campus/dorm/bridge',
    'st_gw': 'ST-gw-1',
    'st_plat': 'plat-ticket-1',
    'hex_plat': '7772647670',
    'expires_in': 300,
  };

  final realMap = <String, dynamic>{
    'showData': {'信息': '当前余额394.67元,当前剩余电量730.87度'},
    'data': {'building': 'A5', 'room': '516'},
  };

  Future<Map<String, dynamic>> run({
    required _FakeDriver driver,
    Map<String, dynamic> body = ticketBody,
    Map<String, dynamic>? payload,
  }) async {
    DormWebClient.debugClient = _FakeClient(body);
    DormBridge.driver = driver;
    if (payload != null) {
      driver.onBridgeOpen = () {
        scheduleMicrotask(() => driver.emit(payload));
      };
    }
    return DormBridge.query(
      sessionId: 'sid-1',
      feeitemid: 448,
      campus: '1',
      building: 'A5&李园壹號A5',
      room: '516',
    );
  }

  setUp(() {
    DormBridge.resetWarm();
    DormBridge.resultTimeout = const Duration(seconds: 30);
  });

  group('DormBridge', () {
    test('成功链路：占位窗 → 网关登录页 → 桥页，返回 map', () async {
      final driver = _FakeDriver();
      final map = await run(
        driver: driver,
        payload: {
          'source': 'xiyuan-bridge',
          'type': 'dorm-result',
          'payload': {'ok': true, 'code': 200, 'map': realMap},
        },
      );

      expect(map, realMap);
      // ① 第一枪必须是占位窗（同步、先于任何网络请求）。
      expect(driver.opened.first, 'about:blank');
      // ② 网关登录页带票。
      expect(driver.opened[1], contains('/login?cas_login=true&ticket=ST-gw-1'));
      // ③ 桥页：origin + bridge_path + fragment 参数。
      final bridge = driver.opened[2];
      expect(bridge,
          startsWith('https://webvpn.cwxu.edu.cn/https/deadbeef/api/v1/campus/dorm/bridge#'));
      expect(bridge, contains('st_plat=plat-ticket-1'));
      expect(bridge, contains('feeitemid=448'));
      expect(bridge, contains('room=516'));
      // building 要整段转义（含 `&`），否则 fragment 会被截断。
      expect(
          bridge,
          contains(
              'building=A5%26%E6%9D%8E%E5%9B%AD%E5%A3%B9%E8%99%9FA5'));
      // 窗口留着复用（下次查询不再新开），但要复位成空白页。
      expect(driver.closed, isFalse);
      expect(driver.opened.last, 'about:blank');
    });

    test('弹窗被拦截：第一枪就失败，不再发网络请求', () async {
      final driver = _FakeDriver()..blockOpen = true;
      await expectLater(
        run(driver: driver),
        throwsA(isA<CampusException>().having(
            (e) => e.message, 'message', DormBridge.popupBlockedMessage)),
      );
      expect(driver.opened, isEmpty);
      expect(driver.closed, isFalse);
    });

    test('桥页回 ok=false：透出桥页的 error 文案', () async {
      final driver = _FakeDriver();
      await expectLater(
        run(
          driver: driver,
          payload: {
            'source': 'xiyuan-bridge',
            'type': 'dorm-result',
            'payload': {'ok': false, 'error': '平台未授权，请重新登录'},
          },
        ),
        throwsA(isA<CampusException>()
            .having((e) => e.message, 'message', '平台未授权，请重新登录')),
      );
      expect(driver.closed, isFalse);
    });

    test('桥页超时：抛超时文案，窗口仍会关', () async {
      final driver = _FakeDriver();
      DormBridge.resultTimeout = const Duration(milliseconds: 30);
      await expectLater(
        run(driver: driver),
        throwsA(isA<CampusException>()
            .having((e) => e.message, 'message', DormBridge.timeoutMessage)),
      );
      expect(driver.closed, isFalse);
    });

    test('忽略非本桥来源的消息（防止别处 postMessage 串味）', () async {
      final driver = _FakeDriver();
      DormBridge.resultTimeout = const Duration(milliseconds: 60);
      await expectLater(
        run(
          driver: driver,
          payload: {
            'source': 'someone-else',
            'type': 'dorm-result',
            'payload': {'ok': true, 'map': realMap},
          },
        ),
        throwsA(isA<CampusException>()),
      );
    });

    test('第二次查询复用桥窗：不再开占位窗、不再登网关', () async {
      final driver = _FakeDriver();
      final payload = {
        'source': 'xiyuan-bridge',
        'type': 'dorm-result',
        'payload': {'ok': true, 'code': 200, 'map': realMap},
      };
      DormWebClient.debugClient = _FakeClient(ticketBody);
      DormBridge.driver = driver;
      driver.onBridgeOpen = () {
        scheduleMicrotask(() => driver.emit(payload));
      };

      Future<Map<String, dynamic>> once() => DormBridge.query(
            sessionId: 'sid-1',
            feeitemid: 448,
            campus: '1',
            building: 'A5&李园壹號A5',
            room: '516',
          );

      await once();
      final firstCall = driver.opened.length;
      expect(driver.opened[1], contains('/login?cas_login=true'));

      // 假 driver 的 onBridgeOpen 是一次性的，第二次要重新挂。
      driver.onBridgeOpen = () {
        scheduleMicrotask(() => driver.emit(payload));
      };
      await once();
      final secondCall = driver.opened.sublist(firstCall);
      // 第二次：只有导航桥页 + 复位空白页，没有占位窗、没有再登网关。
      expect(secondCall.length, 2);
      expect(secondCall.first, contains('/api/v1/campus/dorm/bridge#'));
      expect(secondCall.last, 'about:blank');
    });

    test('bridge-ticket 缺字段：明确报票据失败，不导航桥页', () async {
      final driver = _FakeDriver();
      await expectLater(
        run(
          driver: driver,
          body: {'ok': true, 'gateway_origin': '', 'bridge_path': ''},
        ),
        throwsA(isA<CampusException>()
            .having((e) => e.message, 'message', contains('票据'))),
      );
      // 只开了占位窗，没走到网关登录页。
      expect(driver.opened, ['about:blank']);
      expect(driver.closed, isFalse);
    });
  });

  group('DormBridge.turnover', () {
    test('成功链路：action=turnover，分页参数照客户端给的原样带过去', () async {
      final driver = _FakeDriver();
      DormWebClient.debugClient = _FakeClient(ticketBody);
      DormBridge.driver = driver;
      driver.onBridgeOpen = () {
        scheduleMicrotask(() => driver.emit({
              'source': 'xiyuan-bridge',
              'type': 'dorm-result',
              'payload': {
                'ok': true,
                'code': 200,
                'records': [
                  {'tranamt': 35, 'resume': '电子账户消费', 'typeFrom': '2'},
                ],
                'total': 204,
                'current': 2,
                'pages': 21,
              },
            }));
      };

      final payload = await DormBridge.turnover(
        session: () async => 'sid-1',
        page: 2,
        size: 10,
        type: '1',
      );

      expect(driver.opened.first, 'about:blank');
      final bridgeUrl = driver.opened[2];
      expect(bridgeUrl, contains('action=turnover'));
      // 服务端只认 `current`（传 pageNum 会恒回第 1 页）。
      expect(bridgeUrl, contains('current=2'));
      expect(bridgeUrl, contains('pageSize=10'));
      expect(bridgeUrl, contains('type=1'));
      expect((payload['records'] as List).length, 1);
      expect(payload['total'], 204);
      // 流水只是取数据：同样复用窗口，不关。
      expect(driver.closed, isFalse);
    });

    test('弹窗被拦截：直接抛拦截文案，不发网络请求', () async {
      final driver = _FakeDriver()..blockOpen = true;
      DormWebClient.debugClient = _FakeClient(ticketBody);
      DormBridge.driver = driver;

      await expectLater(
        DormBridge.turnover(session: () async => 'sid-1'),
        throwsA(isA<CampusException>().having(
          (e) => e.message,
          'message',
          DormBridge.popupBlockedMessage,
        )),
      );
    });
  });

  group('DormBridge.openRecharge', () {
    Future<String?> runRecharge({
      required _FakeDriver driver,
      required Map<String, dynamic> payload,
      bool card = false,
    }) {
      DormWebClient.debugClient = _FakeClient(ticketBody);
      DormBridge.driver = driver;
      driver.onBridgeOpen = () {
        scheduleMicrotask(() => driver.emit({
              'source': 'xiyuan-bridge',
              'type': 'dorm-result',
              'payload': payload,
            }));
      };
      return DormBridge.openRecharge(
        session: () async => 'sid-1',
        feeitemid: card ? null : 448,
        card: card,
      );
    }

    test('电费充值：桥页拼出的地址在同一个命名窗口打开，窗口留着', () async {
      final driver = _FakeDriver();
      const url = 'https://webvpn.cwxu.edu.cn/http/7772/charge-app'
          '?name=pays&id=448&token=tok-1';
      final err = await runRecharge(
        driver: driver,
        payload: {'ok': true, 'kind': 'recharge', 'url': url},
      );

      expect(err, isNull);
      expect(driver.opened.first, 'about:blank');
      // 桥页要求带 action=recharge（否则桥页会去查电费）。
      expect(driver.opened[2], contains('action=recharge'));
      // 最后一步才是充值页本身。
      expect(driver.opened.last, url);
      expect(driver.opened.length, 4);
      // 成功时不能关窗，否则用户看不到充值页。
      expect(driver.closed, isFalse);
    });

    test('一卡通充值：先预热再进充值页', () async {
      final driver = _FakeDriver();
      const warmup = 'https://webvpn.cwxu.edu.cn/http/7772/plat/?name=loginTransit';
      const url = 'https://webvpn.cwxu.edu.cn/http/7772/campus-card/cardRecharge';
      final err = await runRecharge(
        driver: driver,
        card: true,
        payload: {
          'ok': true,
          'kind': 'card',
          'warmup_url': warmup,
          'url': url,
        },
      );

      expect(err, isNull);
      expect(driver.opened[2], contains('action=card'));
      expect(driver.opened[3], warmup);
      expect(driver.opened[4], url);
      expect(driver.closed, isFalse);
    });

    test('桥页没给地址：返回充值失败文案并关窗', () async {
      final driver = _FakeDriver();
      final err = await runRecharge(
        driver: driver,
        payload: {'ok': true, 'kind': 'recharge'},
      );

      expect(err, DormBridge.rechargeFailureMessage);
      expect(driver.closed, isTrue);
    });

    test('桥页报错：透出桥页文案并关窗', () async {
      final driver = _FakeDriver();
      final err = await runRecharge(
        driver: driver,
        payload: {'ok': false, 'error': '校园网认证失败'},
      );

      expect(err, '校园网认证失败');
      expect(driver.closed, isTrue);
    });
  });
}

/// 假浏览器：记录每次 open 的 url，可按需回放桥页消息。
class _FakeDriver extends BridgeDriver {
  final List<String> opened = <String>[];
  bool blockOpen = false;
  bool closed = false;

  /// 打开桥页（第三个窗）后的回调，用来模拟 postMessage 回执。
  void Function()? onBridgeOpen;

  void Function(Map<String, dynamic>)? _handler;
  String? _origin;

  void emit(Map<String, dynamic> data) => _handler?.call(data);

  @override
  bool open(String url) {
    if (blockOpen) return false;
    opened.add(url);
    if (onBridgeOpen != null && opened.length >= 3) {
      final cb = onBridgeOpen!;
      onBridgeOpen = null;
      cb();
    }
    return true;
  }

  @override
  void Function() listen(
    String origin,
    void Function(Map<String, dynamic> data) onMessage,
  ) {
    _origin = origin;
    _handler = onMessage;
    return () {
      _handler = null;
    };
  }

  @override
  void close() {
    closed = true;
  }

  @override
  Future<void> wait(Duration duration) async {}

  String? get listenedOrigin => _origin;
}

/// 回放固定 JSON 的 http 客户端。
class _FakeClient extends http.BaseClient {
  _FakeClient(this.body);

  final Map<String, dynamic> body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
      request: request,
    );
  }
}
