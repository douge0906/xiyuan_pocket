import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../constants/control_config.dart';
import 'campus/jwgl_client.dart' show CampusException;
import 'campus/web_campus_client.dart' show SessionProbe;

/// Web 端「电费查询 + 充值」的控制端客户端（2026-11-24）。
///
/// 为什么要有它：安卓端直接连校内平台 `10.3.100.110`（`dart:io` + 校园网），
/// 浏览器**连不到内网**、也不能跑 `dart:io`。于是整条链（CAS → TGT →
/// WebVPN 换票 → 网关 cookie → 平台 ST → 平台票 → oauth token →
/// getThirdData）整体搬到控制端（公网 `ControlConfig.baseUrl`），
/// 只有 WebVPN 网关能进内网。
///
/// 约定（与 [campus/web_campus_client.dart] 一致）：
/// - 全部 POST + JSON body；
/// - 20 秒超时；
/// - 错误体统一 `{"error":{"code","message"}}` → 抛 [CampusException]，
///   `code == 'session_expired'` 时带 `needRelogin: true`；
/// - **不打印任何账密 / token / 票据**（只抛不含凭据的中文文案）。
class DormWebClient {
  DormWebClient._();

  static String get _base => ControlConfig.baseUrl;

  /// 端点前缀（与控制端 `app/dorm_proxy.py` 对拍）。
  static const String prefix = '/api/v1/campus/dorm';

  static const Duration _timeout = Duration(seconds: 20);

  /// 测试接缝：注入假客户端即可离线跑契约测试（生产恒为 null）。
  @visibleForTesting
  static http.Client? debugClient;

  /// 会话建立结果。
  ///
  /// - [loggedIn] = true：服务端已登录完成，可直接用；
  /// - [loggedIn] = false：服务端三轮自动识别验证码失败，需要人工回填
  ///   [captchaB64]（图片 base64）。
  static Future<DormSessionStart> startSession(
    String username,
    String password,
  ) async {
    final data = await _post('session/start', {
      'username': username,
      'password': password,
    });
    final sid = (data['session_id'] ?? '').toString();
    if (sid.isEmpty) {
      throw CampusException('登录会话建立失败，请稍后重试');
    }
    final captcha = (data['captcha_b64'] ?? '').toString();
    return DormSessionStart(
      sessionId: sid,
      captchaB64: captcha,
      loggedIn: data['ok'] == true || captcha.isEmpty,
    );
  }

  /// 人工回填验证码。失败时抛 [CampusException]（`captcha_failed` 等）。
  static Future<void> submitCaptcha(String sessionId, String code) async {
    await _post('session/submit', {
      'session_id': sessionId,
      'code': code,
    });
  }

  /// 查电费：返回控制端**原样透传**的 `getThirdData` map。
  ///
  /// 解析（金额 / 电量 / 单价）留在 Dart 侧（`DormService.parseMoney` 等），
  /// 这样 Web 与安卓的结果完全一致，服务端不做任何二次加工。
  static Future<Map<String, dynamic>> query(
    String sessionId, {
    required int feeitemid,
    required String campus,
    required String building,
    required String room,
  }) async {
    final data = await _post('query', {
      'session_id': sessionId,
      'feeitemid': feeitemid,
      'campus': campus,
      'building': building,
      'room': room,
    });
    final map = data['map'];
    if (map is Map) return map.cast<String, dynamic>();
    // 兼容只回文本的形态（服务端直传 showData 文案）。
    final text = (data['text'] ?? '').toString();
    if (text.isNotEmpty) {
      return <String, dynamic>{
        'showData': <String, dynamic>{'信息': text},
      };
    }
    throw CampusException('查询失败，请稍后重试');
  }

  /// 电费充值地址（浏览器新标签页打开）。
  ///
  /// - [url]：包装过的官方 H5（自带 `?token=`，打开即登录）；
  /// - [gatewayLoginUrl]：网关登录地址（浏览器先开它拿自己的网关票据 cookie）。
  static Future<DormRechargeUrl> rechargeUrl(
    String sessionId,
    int feeitemid,
  ) async {
    final data = await _post('recharge-url', {
      'session_id': sessionId,
      'feeitemid': feeitemid,
    });
    final url = (data['url'] ?? '').toString();
    if (url.isEmpty) {
      throw CampusException('充值页准备失败，请稍后重试');
    }
    return DormRechargeUrl(
      url: url,
      gatewayLoginUrl: (data['gateway_login_url'] ?? '').toString(),
      expiresIn: int.tryParse((data['expires_in'] ?? '').toString()) ?? 0,
    );
  }

  /// 一卡通充值地址（两步：先预热建平台会话，再进充值页）。
  static Future<DormCardRechargeUrl> cardRechargeUrl(String sessionId) async {
    final data = await _post('card-recharge-url', {'session_id': sessionId});
    final url = (data['url'] ?? '').toString();
    if (url.isEmpty) {
      throw CampusException('充值页准备失败，请稍后重试');
    }
    return DormCardRechargeUrl(
      warmupUrl: (data['warmup_url'] ?? '').toString(),
      url: url,
      gatewayLoginUrl: (data['gateway_login_url'] ?? '').toString(),
    );
  }

  /// 一卡通余额（控制端 D10）。服务端未部署时抛 [CampusException]。
  static Future<double> cardBalance(String sessionId) async {
    final data = await _post('card-balance', {'session_id': sessionId});
    final balance = data['balance'];
    if (balance is num) return balance.toDouble();
    final parsed = double.tryParse((balance ?? '').toString());
    if (parsed != null) return parsed;
    throw CampusException('暂不可用');
  }

  /// 控制端是否可达（Web 端的「隧道可用性」判定，见 spec R11）。
  ///
  /// 浏览器没有「校园网」这回事：能不能查电费只取决于控制端在不在线。
  /// 2xx / 3xx / 401 都算「在」（401 只说明该接口要鉴权）。
  static Future<bool> controlReachable() async {
    final uri = Uri.parse('$_base${ControlConfig.pathHealth}');
    final client = debugClient;
    try {
      if (client != null) {
        final resp = await client.get(uri).timeout(_timeout);
        return _isReachable(resp.statusCode);
      }
      final owned = http.Client();
      try {
        final resp = await owned.get(uri).timeout(_timeout);
        return _isReachable(resp.statusCode);
      } finally {
        owned.close();
      }
    } catch (_) {
      return false;
    }
  }

  static bool _isReachable(int statusCode) =>
      statusCode == 401 || (statusCode >= 200 && statusCode < 400);

  /// 探活 + 静默续期。
  ///
  /// 服务端 [app/dorm_proxy.py] 的 `session/refresh` 会先探网关票据与平台
  /// token：还活着只滑动续期（返回 `refreshed: false`）；死了就用登录时留下
  /// 的 TGT / 平台凭据免验证码重铸。
  ///
  /// ⚠️ 旧实现写成 `data['ok'] == true && data['refreshed'] != false`，
  /// 于是「会话本来就好好的、只是滑动续期」被当成**已过期**，用户平白被要求
  /// 重新登录 —— 这是电费链「一段时间后提示登录状态不在」的直接原因。
  ///
  /// 返回三态（见 [SessionProbe]）：只有 [SessionProbe.expired] 才代表会话
  /// 真的没了；控制端不可达 / 5xx 归为 [SessionProbe.unreachable]，**不能**
  /// 当成过期。
  static Future<SessionProbe> refresh(String sessionId) async {
    try {
      final resp = await _postRaw('session/refresh', {'session_id': sessionId});
      if (resp.statusCode == 401) return SessionProbe.expired;
      if (resp.statusCode >= 500) return SessionProbe.unreachable;
      final data = _decode(resp);
      return data['ok'] == true ? SessionProbe.alive : SessionProbe.expired;
    } on CampusException catch (e) {
      if (e.needRelogin) return SessionProbe.expired;
      return SessionProbe.unreachable;
    } catch (_) {
      return SessionProbe.unreachable;
    }
  }

  /// 探活（不续期）。三态语义见 [refresh]。
  static Future<SessionProbe> ping(String sessionId) async {
    try {
      final resp = await _postRaw('session/ping', {'session_id': sessionId});
      if (resp.statusCode == 401) return SessionProbe.expired;
      if (resp.statusCode >= 500) return SessionProbe.unreachable;
      final data = _decode(resp);
      return data['ok'] == true ? SessionProbe.alive : SessionProbe.expired;
    } on CampusException catch (e) {
      if (e.needRelogin) return SessionProbe.expired;
      return SessionProbe.unreachable;
    } catch (_) {
      return SessionProbe.unreachable;
    }
  }

  /// 探活（布尔版）。**网络故障也返回 false**，要区分请用 [ping]。
  static Future<bool> pingOk(String sessionId) async =>
      await ping(sessionId) == SessionProbe.alive;

  /// 续期（布尔版）。**网络故障也返回 false**，要区分请用 [refresh]。
  static Future<bool> refreshOk(String sessionId) async =>
      await refresh(sessionId) == SessionProbe.alive;

  /// 注销服务端会话（尽力而为，不抛异常）。
  static Future<void> logout(String sessionId) async {
    try {
      await _post('session/logout', {'session_id': sessionId});
    } catch (_) {
      // 注销失败无所谓：服务端会话有 TTL（12h），且同账号新登录会踢掉旧会话。
    }
  }

  // ---------------- 内部 ----------------

  static Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final resp = await _postRaw(path, body);
    return _decode(resp);
  }

  /// 原始响应出口：探活类端点需要先看 HTTP 状态码再决定三态结论，
  /// 所以不能在这里就把错误体解成异常。
  static Future<http.Response> _postRaw(
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('$_base$prefix/$path');
    final client = debugClient;
    return client == null
        ? http.post(
            uri,
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(body),
          ).timeout(_timeout)
        : client
            .post(uri,
                headers: const {'content-type': 'application/json'},
                body: jsonEncode(body))
            .timeout(_timeout);
  }

  /// 解包控制端响应：出错统一抛 [CampusException]（中文文案）。
  static Map<String, dynamic> _decode(http.Response resp) {
    final Object? decoded;
    try {
      decoded = jsonDecode(resp.body);
    } catch (_) {
      if (resp.statusCode >= 500) {
        throw CampusException('访问学校系统失败，请稍后重试');
      }
      throw CampusException('服务器返回了非预期内容');
    }
    if (decoded is! Map) {
      throw CampusException('服务器返回了非预期内容');
    }
    final data = decoded.cast<String, dynamic>();
    final err = data['error'];
    if (err is Map && err['message'] != null) {
      final code = (err['code'] ?? '').toString();
      throw CampusException(
        err['message'].toString(),
        needRelogin: code == 'session_expired' || code == 'unauthorized',
      );
    }
    if (resp.statusCode >= 500) {
      throw CampusException('访问学校系统失败，请稍后重试');
    }
    return data;
  }
}

/// [DormWebClient.startSession] 的结果。
class DormSessionStart {
  const DormSessionStart({
    required this.sessionId,
    required this.captchaB64,
    required this.loggedIn,
  });

  final String sessionId;

  /// 需要人工识别的验证码图片（base64）；为空表示不需要。
  final String captchaB64;

  /// 服务端是否已完成登录。
  final bool loggedIn;
}

/// 电费充值地址。
class DormRechargeUrl {
  const DormRechargeUrl({
    required this.url,
    required this.gatewayLoginUrl,
    required this.expiresIn,
  });

  /// 包装过的官方充值页（自带 token）。
  final String url;

  /// 网关登录地址（浏览器先开它，才能拿到自己的网关票据 cookie）。
  final String gatewayLoginUrl;

  /// 有效期（秒）。
  final int expiresIn;
}

/// 一卡通充值地址。
class DormCardRechargeUrl {
  const DormCardRechargeUrl({
    required this.warmupUrl,
    required this.url,
    this.gatewayLoginUrl = '',
  });

  /// 预热地址（先建立平台会话）。
  final String warmupUrl;

  /// 充值页地址。
  final String url;

  /// 网关登录地址（浏览器先在这里用自己的票据登录网关）。
  ///
  /// 浏览器有自己的 cookie 罐，拿不到服务端在网关上的票据；所以一卡通那条
  /// 链也得先让浏览器在**网关 origin** 下登一次，再开 [warmupUrl]。
  final String gatewayLoginUrl;
}
