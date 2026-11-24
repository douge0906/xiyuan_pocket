import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:xiyuan_pocket/services/campus/jwgl_client.dart';
import 'package:xiyuan_pocket/services/campus/web_campus_client.dart';

/// Web 端首次登录「自动识别验证码」链路的契约测试（2026-11-24）。
///
/// 背景：线上 Web 产物（1.0.9+23）无条件弹验证码，用户第一次登录必须手输。
/// 新版协议多了 `loggedIn` 字段：服务端自动识别成功时 `loggedIn=true`，
/// 前端直接进已登录态；识别失败才把图片交人工。
///
/// 本测试锁两件事：
///  ① 服务端返回 `ok=true` / 空 captcha 时 `loggedIn=true`（前端不弹验证码）；
///  ② 服务端把「学号不存在」（NOUSER）译成 401 bad_credential 时，
///     客户端把中文文案**原样透出**（而不是当成「验证码没过」让人手输）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    WebCampusProxy.debugClient = null;
  });

  /// 回放固定响应体的假 client。
  http.Client fakeClient(
    List<http.BaseRequest> log,
    Map<String, dynamic> body, {
    int status = 200,
  }) {
    return _RecordingClient(log, body, status);
  }

  group('WebCampusProxy 首次登录自动识别', () {
    test('session/start 返回 ok=true → loggedIn=true，不弹验证码', () async {
      final log = <http.BaseRequest>[];
      WebCampusProxy.debugClient = fakeClient(log, {
        'session_id': 'sid-1',
        'ok': true,
        'captcha_b64': '',
      });

      final start = await WebCampusProxy.startLogin('2026123456', 'pwd');

      expect(start.loggedIn, isTrue);
      expect(start.captchaB64, isEmpty);
      expect(start.sessionId, 'sid-1');
      expect(log.length, 1);
      final req = log.first as http.Request;
      expect(req.url.path, contains('/api/v1/campus/session/start'));
      final sent = jsonDecode(req.body) as Map<String, dynamic>;
      expect(sent['username'], '2026123456');
      expect(sent['password'], 'pwd');
    });

    test('session/start 只回验证码图 → loggedIn=false，交给人工回填', () async {
      final log = <http.BaseRequest>[];
      WebCampusProxy.debugClient = fakeClient(log, {
        'session_id': 'sid-2',
        'captcha_b64': 'aGVsbG8=',
      });

      final start = await WebCampusProxy.startLogin('2026123456', 'pwd');

      expect(start.loggedIn, isFalse);
      expect(start.captchaB64, 'aGVsbG8=');
      expect(start.sessionId, 'sid-2');
    });

    test('session/start 401 学号不存在 → 文案原样透出，不误判为验证码失败',
        () async {
      final log = <http.BaseRequest>[];
      WebCampusProxy.debugClient = fakeClient(
        log,
        {
          'error': {
            'code': 'bad_credential',
            'message': '学号不存在，请确认学号后重试',
          },
        },
        status: 401,
      );

      await expectLater(
        WebCampusProxy.startLogin('2026123456', 'wrongpass'),
        throwsA(
          isA<CampusException>()
              .having((e) => e.message, 'message', '学号不存在，请确认学号后重试')
              .having((e) => e.needRelogin, 'needRelogin', isFalse),
        ),
      );
    });

    test('session/start 401 会话失效 → needRelogin=true', () async {
      final log = <http.BaseRequest>[];
      WebCampusProxy.debugClient = fakeClient(
        log,
        {
          'error': {
            'code': 'session_expired',
            'message': '会话已失效，请重新登录',
          },
        },
        status: 401,
      );

      await expectLater(
        WebCampusProxy.startLogin('2026123456', 'pwd'),
        throwsA(
          isA<CampusException>()
              .having((e) => e.message, 'message', '会话已失效，请重新登录')
              .having((e) => e.needRelogin, 'needRelogin', isTrue),
        ),
      );
    });

    test('session/submit 回填验证码 → 成功返回', () async {
      final log = <http.BaseRequest>[];
      WebCampusProxy.debugClient = fakeClient(log, {'ok': true});

      await WebCampusProxy.submitCaptcha('sid-2', '1234');

      expect(log.length, 1);
      final req = log.first as http.Request;
      expect(req.url.path, contains('/api/v1/campus/session/submit'));
      final sent = jsonDecode(req.body) as Map<String, dynamic>;
      expect(sent['session_id'], 'sid-2');
      expect(sent['code'], '1234');
    });

    test('session/ping 会话有效 → true', () async {
      final log = <http.BaseRequest>[];
      WebCampusProxy.debugClient = fakeClient(log, {'ok': true});

      expect(await WebCampusProxy.ping('sid-1'), isTrue);
    });

    test('session/ping 401 → false（不抛异常）', () async {
      final log = <http.BaseRequest>[];
      WebCampusProxy.debugClient = fakeClient(
        log,
        {
          'error': {
            'code': 'session_expired',
            'message': '会话已失效',
          },
        },
        status: 401,
      );

      expect(await WebCampusProxy.ping('sid-1'), isFalse);
    });

    // ---- 三态探活：只有服务端明确 401 才算「过期」 ----
    // 旧实现把「控制端不可达 / 5xx / 超时」也折成 false，于是断网或服务端抖动
    // 会把用户的登录态作废，界面弹「登录已过期，请重新登录」——
    // 这正是用户反馈的「登录一段时间后突然提示登录状态不在」的成因之一。

    test('probe：会话有效 → alive', () async {
      final log = <http.BaseRequest>[];
      WebCampusProxy.debugClient = fakeClient(log, {'ok': true});

      expect(await WebCampusProxy.probe('sid-1'), SessionProbe.alive);
    });

    test('probe：401 → expired（会话确实没了）', () async {
      final log = <http.BaseRequest>[];
      WebCampusProxy.debugClient = fakeClient(
        log,
        {
          'error': {
            'code': 'session_expired',
            'message': '会话已失效',
          },
        },
        status: 401,
      );

      expect(await WebCampusProxy.probe('sid-1'), SessionProbe.expired);
    });

    test('probe：5xx → unreachable（状态未知，不能作废本地会话）', () async {
      final log = <http.BaseRequest>[];
      WebCampusProxy.debugClient = fakeClient(log, {}, status: 500);

      expect(await WebCampusProxy.probe('sid-1'), SessionProbe.unreachable);
    });

    test('refresh：服务端滑动续期（refreshed=false）→ alive', () async {
      final log = <http.BaseRequest>[];
      WebCampusProxy.debugClient = fakeClient(
        log,
        {'ok': true, 'refreshed': false},
      );

      expect(await WebCampusProxy.refresh('sid-1'), SessionProbe.alive);
      expect(await WebCampusProxy.refreshOk('sid-1'), isTrue);
    });

    test('refresh：401 → expired，5xx → unreachable', () async {
      final log = <http.BaseRequest>[];
      WebCampusProxy.debugClient = fakeClient(
        log,
        {
          'error': {
            'code': 'session_expired',
            'message': '会话已失效',
          },
        },
        status: 401,
      );
      expect(await WebCampusProxy.refresh('sid-1'), SessionProbe.expired);

      WebCampusProxy.debugClient = fakeClient(log, {}, status: 500);
      expect(await WebCampusProxy.refresh('sid-1'), SessionProbe.unreachable);
    });
  });
}

/// 记录收到的请求，并回放固定响应体。
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
      contentLength: bytes.length,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  }
}
