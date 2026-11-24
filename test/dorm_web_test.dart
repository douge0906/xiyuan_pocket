import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:xiyuan_pocket/services/campus/jwgl_client.dart';
import 'package:xiyuan_pocket/services/campus/web_campus_client.dart'
    show SessionProbe;
import 'package:xiyuan_pocket/services/dorm_web_client.dart';

/// Web 端「电费查询 + 充值」与控制端的契约测试（2026-11-24）。
///
/// 离线跑：用假 http.Client 顶住控制端，断言
///  ① 请求打到正确的路径与 body；
///  ② 响应按约定解析（session_id / ok / captcha / gateway_login_url）；
///  ③ 错误体统一抛 [CampusException]，且 needRelogin 标记正确。
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
  });

  /// 记录收到的请求，并回放 [body]。
  http.Client fakeClient(
    List<http.BaseRequest> log,
    Map<String, dynamic> body, {
    int status = 200,
  }) {
    return _RecordingClient(log, body, status);
  }

  group('DormWebClient 契约', () {
    test('session/start：带学号密码，返回 session_id 与已登录标记', () async {
      final log = <http.BaseRequest>[];
      DormWebClient.debugClient = fakeClient(log, {
        'session_id': 'sid-1',
        'ok': true,
        'captcha_b64': '',
      });

      final r = await DormWebClient.startSession('2026123456', 'pwd');

      expect(r.sessionId, 'sid-1');
      expect(r.loggedIn, isTrue);
      expect(log.length, 1);
      final req = log.first as http.Request;
      expect(req.url.path, contains('/api/v1/campus/dorm/session/start'));
      final sent = jsonDecode(req.body) as Map<String, dynamic>;
      expect(sent['username'], '2026123456');
      expect(sent['password'], 'pwd');
    });

    test('session/start：captcha 非空且 ok 缺省 → 需要人工回填', () async {
      final log = <http.BaseRequest>[];
      DormWebClient.debugClient = fakeClient(log, {
        'session_id': 'sid-2',
        'captcha_b64': 'aGk=',
      });

      final r = await DormWebClient.startSession('2026123456', 'pwd');

      expect(r.sessionId, 'sid-2');
      expect(r.loggedIn, isFalse);
      expect(r.captchaB64, 'aGk=');
    });

    test('query：原样透传服务器给的 map', () async {
      final log = <http.BaseRequest>[];
      DormWebClient.debugClient = fakeClient(log, {
        'ok': true,
        'code': '200',
        'map': {
          'showData': {'信息': '电费余额 12.34 元'},
        },
      });

      final map = await DormWebClient.query(
        'sid-1',
        feeitemid: 448,
        campus: '1&无锡学院',
        building: 'A5&李园壹號A5',
        room: '101',
      );

      expect(map['showData'], isNotNull);
      expect(((map['showData'] as Map)['信息']).toString(), contains('12.34'));
      final req = log.first as http.Request;
      expect(req.url.path, contains('/api/v1/campus/dorm/query'));
      final sent = jsonDecode(req.body) as Map<String, dynamic>;
      expect(sent['feeitemid'], 448);
      expect(sent['room'], '101');
    });

    test('query：只回文本时包成 showData 结构', () async {
      final log = <http.BaseRequest>[];
      DormWebClient.debugClient = fakeClient(log, {
        'ok': true,
        'code': '200',
        'text': '电费余额 8.00 元',
      });

      final map = await DormWebClient.query(
        'sid-1',
        feeitemid: 448,
        campus: 'c',
        building: 'b',
        room: 'r',
      );

      expect(((map['showData'] as Map)['信息']).toString(), contains('8.00'));
    });

    test('recharge-url：给出充值页 + 网关登录地址', () async {
      final log = <http.BaseRequest>[];
      DormWebClient.debugClient = fakeClient(log, {
        'ok': true,
        'url': 'https://webvpn.cwxu.edu.cn/http/aaa/charge-app?name=pays',
        'gateway_login_url':
            'https://webvpn.cwxu.edu.cn/login?cas_login=true&ticket=ST-1',
        'expires_in': 300,
      });

      final r = await DormWebClient.rechargeUrl('sid-1', 448);

      expect(r.url, contains('charge-app'));
      expect(r.gatewayLoginUrl, contains('cas_login=true'));
      expect(r.expiresIn, 300);
    });

    test('card-recharge-url：给出预热地址 + 充值页 + 网关登录地址', () async {
      final log = <http.BaseRequest>[];
      DormWebClient.debugClient = fakeClient(log, {
        'ok': true,
        'warmup_url': 'https://webvpn.cwxu.edu.cn/http/aaa/plat?ticket=T',
        'url': 'https://webvpn.cwxu.edu.cn/http/aaa/campus-card/cardRecharge',
        'gateway_login_url':
            'https://webvpn.cwxu.edu.cn/login?cas_login=true&ticket=ST-2',
      });

      final r = await DormWebClient.cardRechargeUrl('sid-1');

      expect(r.warmupUrl, contains('ticket=T'));
      expect(r.url, contains('cardRecharge'));
      expect(r.gatewayLoginUrl, contains('ST-2'));
    });

    test('错误体：抛 CampusException，session_expired 带 needRelogin', () async {
      final log = <http.BaseRequest>[];
      DormWebClient.debugClient = fakeClient(
        log,
        {
          'error': {
            'code': 'session_expired',
            'message': '登录已过期，请重新登录',
          },
        },
        status: 401,
      );

      await expectLater(
        DormWebClient.ping('sid-1'),
        completes,
      );
      // 三态探活：服务端明确回 401 才是「会话过期」；
      // 控制端不可达 / 5xx 属于「状态未知」，不能作废本地会话。
      expect(await DormWebClient.ping('sid-1'), SessionProbe.expired);
      expect(await DormWebClient.pingOk('sid-1'), isFalse);
    });

    test('错误体：query 抛 CampusException 且文案来自服务器', () async {
      final log = <http.BaseRequest>[];
      DormWebClient.debugClient = fakeClient(
        log,
        {
          'error': {
            'code': 'session_expired',
            'message': '登录已过期，请重新登录',
          },
        },
        status: 401,
      );

      await expectLater(
        DormWebClient.query(
          'sid-1',
          feeitemid: 448,
          campus: 'c',
          building: 'b',
          room: 'r',
        ),
        throwsA(
          isA<CampusException>().having(
            (e) => e.message,
            'message',
            '登录已过期，请重新登录',
          ),
        ),
      );
    });

    test('controlReachable：401 也算可达（说明服务在，只是要鉴权）', () async {
      final log = <http.BaseRequest>[];
      DormWebClient.debugClient = fakeClient(
        log,
        {'error': {'code': 'unauthorized', 'message': '需要登录'}},
        status: 401,
      );

      expect(await DormWebClient.controlReachable(), isTrue);
    });

    test('controlReachable：服务异常时返回 false', () async {
      final log = <http.BaseRequest>[];
      DormWebClient.debugClient = fakeClient(log, {}, status: 500);

      expect(await DormWebClient.controlReachable(), isFalse);
    });
  });
}

/// 假客户端：记录请求并回放固定 JSON。
class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.log, this.body, this.status);

  final List<http.BaseRequest> log;
  final Map<String, dynamic> body;
  final int status;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    log.add(request);
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  }
}
