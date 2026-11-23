import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart';

import 'chaoxing_logger.dart';
import 'chaoxing_models.dart';

/// Headless client for the 学习通 passport2 login protocol (official Android
/// client 7.0.2).
///
/// Flow (verified against the live service 2026-09-11):
///
/// 1. `POST /v11/loginregister?cx_xxt_passport=json` with
///    `logininfo = Base64(AES-128-ECB/PKCS5({"uname":<account>,"code":<pwd>}))`.
///    The 16-byte AES key is a constant embedded in the official client, so the
///    "encryption" only obfuscates the password in transit logs — it is not a
///    secret we can avoid handling.
/// 2. On `status=true` the response carries `url` (an SSO endpoint on
///    `sso.chaoxing.com`); POSTing it harvests the full cookie set. Skipping
///    this step leaves later API calls unauthenticated.
/// 3. Identity fields (`fid`, `_uid`, `_tid`, `sso_puid`) are read back out of
///    the cookie jar.
///
/// SMS login reuses step 1 with the code in the `code` field, after
/// `POST /api/sendcaptcha` (`enc = MD5(phone + salt + millis)`).
///
/// Captcha: when the server sets a non-empty `webUrl` it demands an interactive
/// verification page. There is no headless bypass; we surface
/// [ChaoxingCaptchaRequired] and let the UI explain.
class ChaoxingAuthService {
  /// Creates the login client, optionally injecting a [dio], a [logger], and a
  /// [userAgent]. The default UA is the Dalvik form the headless login was
  /// verified with; pass [ChaoxingUserAgent.build] to emit the official-format
  /// header carrying the device [uniqueId].
  ChaoxingAuthService({Dio? dio, this.logger, String? userAgent})
    : userAgent = userAgent ?? _defaultUserAgent,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              // The SSO follow returns 302 chains we want to walk ourselves.
              followRedirects: false,
              validateStatus: (status) => status != null && status < 500,
            ),
          );

  final Dio _dio;

  /// Optional sink for non-fatal diagnostics. See [ChaoxingLogger].
  final ChaoxingLogger? logger;

  /// The `User-Agent` header sent on every request.
  final String userAgent;

  void _log(String message) => logger?.call(message);

  static const _passportBase = 'https://passport2-api.chaoxing.com';

  /// The web host that serves the second-factor page and its `/num/*` endpoints.
  /// Distinct from [_passportBase]: the challenge lives on `passport2`, the API
  /// on `passport2-api`.
  static const _passportWebBase = 'https://passport2.chaoxing.com';

  /// Where the `tocheckmessage` page sends the client once the SMS code checks
  /// out (`endSuccessFunc` → `CLIENT_THIRD_LOGIN`). Same SSO endpoint a normal
  /// login's `url` points at.
  static const _ssoLoginUrl =
      'https://sso.chaoxing.com/apis/login/userLogin4Uname.do?ft=true';
  static const _defaultUserAgent =
      'Dalvik/2.1.0 (Linux; U; Android 14) ChaoXingStudy_3_7.0.2_android_phone_10993';

  /// AES key for `logininfo`, embedded in the official client
  /// (`com.chaoxing.study.account.e#m90143c`).
  static const _aesKey = 'z4ok6lu^oWp4_AES';

  /// Salt for the sendcaptcha `enc` parameter
  /// (`com.chaoxing.study.account.e#m90147g`).
  static const _captchaSalt = 'jsDyctOCnay7uotq';

  /// Salt for the extenduserinfo `enc` parameter (`ke.C32761m#e9`).
  static const _userInfoSalt = 'uWwjeEKsri';

  /// Cookie jar accumulated across the login + SSO calls of one attempt, keyed
  /// by the host that set each cookie.
  ///
  /// `passport2-api` and `passport2` both set a `JSESSIONID` and a `route`, but
  /// they are different sessions. Sending the API host's pair to the web host
  /// makes tengine answer `403 Forbidden` before the app ever runs, so each
  /// request must only carry the cookies of its own host.
  final Map<String, Map<String, String>> _cookies = {};

  /// `LoginResult.msg.clientId` harvested from the SSO follow, when present.
  String _clientId = '';

  // -------------------------------------------------------------------
  // Crypto primitives
  // -------------------------------------------------------------------

  /// Lowercase hex MD5 of [input] (UTF-8).
  static String md5Hex(String input) =>
      md5.convert(utf8.encode(input)).toString();

  /// AES-128-ECB + PKCS#7 (== PKCS#5 for a 16-byte block), matching
  /// `AES/ECB/PKCS5Padding` in the official client. ECB is deliberate: the
  /// server expects it. The payload is one short JSON object, so ECB's
  /// pattern leakage is not a practical concern here.
  static Uint8List aesEcbEncrypt(String key, Uint8List plaintext) {
    const blockSize = 16;
    final padLen = blockSize - (plaintext.length % blockSize);
    final padded = Uint8List(plaintext.length + padLen)
      ..setRange(0, plaintext.length, plaintext)
      ..fillRange(plaintext.length, plaintext.length + padLen, padLen);

    final cipher = AESEngine()
      ..init(true, KeyParameter(Uint8List.fromList(utf8.encode(key))));
    final output = Uint8List(padded.length);
    for (var offset = 0; offset < padded.length; offset += blockSize) {
      cipher.processBlock(padded, offset, output, offset);
    }
    return output;
  }

  /// Builds the `logininfo` form field.
  static String encryptLoginInfo(String account, String code) {
    // Key order matters only for readability; the server parses JSON.
    final payload = jsonEncode({'uname': account, 'code': code});
    final encrypted = aesEcbEncrypt(
      _aesKey,
      Uint8List.fromList(utf8.encode(payload)),
    );
    return base64Encode(encrypted);
  }

  // -------------------------------------------------------------------
  // Cookie handling
  // -------------------------------------------------------------------

  void _absorbCookies(String url, Headers headers) {
    final host = Uri.parse(url).host;
    if (host.isEmpty) return;
    final jar = _cookies.putIfAbsent(host, () => {});
    for (final raw in headers.map['set-cookie'] ?? const <String>[]) {
      final pair = raw.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      jar[pair.substring(0, eq)] = pair.substring(eq + 1);
    }
  }

  /// Copies [fromUrl]'s cookies onto [toUrl]'s host.
  ///
  /// Needed where a browser would send a parent-domain cookie to a sibling host
  /// and this jar, being keyed per host, would not. Existing cookies on the
  /// destination win, so a host never has its own session overwritten.
  void _carryCookies(String fromUrl, String toUrl) {
    final from = _cookies[Uri.parse(fromUrl).host];
    if (from == null || from.isEmpty) return;
    final to = _cookies.putIfAbsent(Uri.parse(toUrl).host, () => {});
    for (final entry in from.entries) {
      to.putIfAbsent(entry.key, () => entry.value);
    }
  }

  /// The cookie header for [url]'s host, or empty when that host set none.
  String _cookieHeaderFor(String url) {
    final jar = _cookies[Uri.parse(url).host];
    if (jar == null || jar.isEmpty) return '';
    return jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// Every cookie gathered so far, for the harvested session. Hosts are joined
  /// because the session is replayed against several `*.chaoxing.com` hosts.
  String get _cookieHeader => _cookies.values
      .expand((jar) => jar.entries)
      .map((e) => '${e.key}=${e.value}')
      .join('; ');

  String? _cookieValue(String name) {
    for (final jar in _cookies.values) {
      final value = jar[name];
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  Map<String, String> _headersFor(String url) {
    final cookie = _cookieHeaderFor(url);
    return {
      'User-Agent': userAgent,
      'Accept-Language': 'zh-CN,zh;q=0.9',
      if (cookie.isNotEmpty) 'Cookie': cookie,
    };
  }

  // -------------------------------------------------------------------
  // SMS captcha
  // -------------------------------------------------------------------

  /// Requests an SMS verification code for [phone].
  ///
  /// Throws [ChaoxingCaptchaSendFailure] when the server refuses (unregistered
  /// number, rate limit, …).
  Future<void> sendSmsCode(String phone) async {
    final millis = DateTime.now().millisecondsSinceEpoch.toString();
    final enc = md5Hex('$phone$_captchaSalt$millis');
    try {
      final response = await _dio.post<dynamic>(
        '$_passportBase/api/sendcaptcha',
        queryParameters: {'cx_xxt_passport': 'json'},
        options: Options(
          headers: _headersFor('$_passportBase/api/sendcaptcha'),
          contentType: Headers.formUrlEncodedContentType,
        ),
        data: {
          'to': phone,
          'countrycode': '86',
          'type': 'login',
          'time': millis,
          'enc': enc,
        },
      );
      _absorbCookies('$_passportBase/api/sendcaptcha', response.headers);

      var rawBody = response.data;
      if (rawBody is String) {
        try {
          rawBody = jsonDecode(rawBody);
        } catch (_) {}
      }
      final body = (rawBody as Map?)?.cast<String, dynamic>() ?? const {};
      final status = body['status'];
      if (status != true) {
        throw ChaoxingCaptchaSendFailure(
          (body['mes'] ?? body['msg'] ?? 'sendcaptcha failed').toString(),
        );
      }
    } on ChaoxingAuthFailure {
      rethrow;
    } on Object catch (error) {
      throw ChaoxingNetworkFailure(error.toString());
    }
  }

  // -------------------------------------------------------------------
  // Login
  // -------------------------------------------------------------------

  /// Runs the full login: loginregister → SSO follow → cookie harvest.
  ///
  /// [deviceInfo] is the `data=` form field the official client posts with the
  /// SSO call (`C22347e.m90144d`, fed by `CxDevice.getDeviceInfo`). Supplying
  /// it is what makes the server return a `clientId`, which in turn is the only
  /// route to the `cxcid`/`sc` device identity — see
  /// `ChaoxingSignService.buildDeviceInfoPayload` and `resolveDeviceIdentity`.
  /// When omitted the login still succeeds and yields cookies, but
  /// [ChaoxingSession.clientId] stays empty.
  ///
  /// Returns the persisted session on success.
  Future<ChaoxingSession> login(
    ChaoxingCredentials credentials, {
    String? deviceInfo,
  }) async {
    _cookies.clear();
    _clientId = '';
    final account = credentials.account.trim();
    if (account.isEmpty || credentials.password.isEmpty) {
      throw const ChaoxingBadCredentials('empty account or password');
    }

    final logininfo = encryptLoginInfo(account, credentials.password);
    final isSms = credentials.mode == ChaoxingLoginMode.sms;
    final loginType = isSms ? '2' : '1';

    Map<String, dynamic> body;
    try {
      final response = await _dio.post<dynamic>(
        '$_passportBase/v11/loginregister',
        queryParameters: {'cx_xxt_passport': 'json'},
        options: Options(
          headers: _headersFor('$_passportBase/v11/loginregister'),
          contentType: Headers.formUrlEncodedContentType,
        ),
        data: {
          'logininfo': logininfo,
          'cfid': '',
          'countrycode': '+86',
          'loginType': loginType,
          'roleSelect': 'true',
          'entype': loginType,
        },
      );
      _absorbCookies('$_passportBase/v11/loginregister', response.headers);

      body = _asMap(response.data);
    } on Object catch (error) {
      throw ChaoxingNetworkFailure(error.toString());
    }

    final status = body['status'] == true;
    final webUrl = (body['webUrl'] ?? '').toString();
    if (!status) {
      if (webUrl.isNotEmpty) throw ChaoxingCaptchaRequired(webUrl);
      throw ChaoxingBadCredentials(
        (body['mes'] ?? body['msg'] ?? '验证失败').toString(),
      );
    }

    final ssoUrl = (body['url'] ?? '').toString();

    // `status:true` with a `webUrl` but no SSO url means passport2 accepted the
    // password and is now demanding a second factor. Without this branch the
    // empty `ssoUrl` skips the SSO follow and the caller gets a misleading
    // "SSO did not return an identity" transport error instead.
    if (ssoUrl.isEmpty && webUrl.isNotEmpty) {
      throw ChaoxingSecondaryVerificationRequired.fromBody(body);
    }

    if (ssoUrl.isNotEmpty) {
      // The SSO host exchanges the passport2-api session for the identity
      // cookies, so it must see that session even though it lives on another
      // host. A browser sends it because the cookie is scoped to the parent
      // domain; the per-host jar does not.
      _carryCookies(_passportBase, ssoUrl);
      await _followSso(ssoUrl, deviceInfo);
    }

    final puid = _cookieValue('sso_puid') ?? _cookieValue('_tid') ?? '';
    final uid = _cookieValue('_uid') ?? _cookieValue('UID') ?? '';
    final fid = _cookieValue('fid') ?? '';
    if (puid.isEmpty) {
      throw const ChaoxingNetworkFailure('SSO did not return an identity');
    }
    return ChaoxingSession(
      cookieHeader: _cookieHeader,
      puid: puid,
      uid: uid,
      fid: fid,
      clientId: _clientId,
      savedAt: DateTime.now(),
    );
  }

  // -------------------------------------------------------------------
  // New-device SMS second factor
  // -------------------------------------------------------------------

  /// Downloads the numeric image code the second-factor page shows.
  ///
  /// `GET /num/code` returns a JPEG of a few digits. The page requires the user
  /// to read it back before it will send the SMS, and there is no headless way
  /// around that, so the bytes come back here for the caller to render.
  ///
  /// Must be called on the same service instance that hit the challenge: the
  /// image is keyed to the cookie just set.
  Future<Uint8List> fetchNumericCaptcha() async {
    try {
      final response = await _dio.get<List<int>>(
        '$_passportWebBase/num/code',
        queryParameters: {'t': '${DateTime.now().millisecondsSinceEpoch}'},
        options: Options(
          headers: _headersFor('$_passportWebBase/num/code'),
          responseType: ResponseType.bytes,
        ),
      );
      _absorbCookies('$_passportWebBase/num/code', response.headers);
      final data = response.data;
      if (data == null || data.isEmpty) {
        throw const ChaoxingNetworkFailure('numeric captcha came back empty');
      }
      return Uint8List.fromList(data);
    } on ChaoxingAuthFailure {
      rethrow;
    } on Object catch (error) {
      throw ChaoxingNetworkFailure(error.toString());
    }
  }

  /// Asks passport2 to text the SMS code for a new-device challenge.
  ///
  /// [phone] is the account phone, [numericCode] is what the user read off
  /// [fetchNumericCaptcha], and [captchaValidate] is the `validate` token from a
  /// solved CXCaptcha on the passport id
  /// (`captchaId = GcXX5vewqE7DezKGlyvleKCnkTglvGpL`) — the page asks for it as
  /// `textclick`, but the server does not pin `type`, so `solveSlide` answers it
  /// as `slide` and the token is accepted here (measured live). The page sends
  /// all three;
  /// the server rejects the request when any of them is missing or stale.
  Future<void> sendDeviceVerificationCode({
    required String phone,
    required String numericCode,
    required String captchaValidate,
    String countryCode = '86',
  }) async {
    try {
      final response = await _dio.get<dynamic>(
        '$_passportWebBase/num/phonecode',
        queryParameters: {
          'phone': phone,
          'code': numericCode,
          'type': '1',
          'countrycode': countryCode,
          'validate': captchaValidate,
        },
        options: Options(
          headers: {
            ..._headersFor('$_passportWebBase/num/phonecode'),
            'Referer': '$_passportWebBase/v11/tocheckmessage',
          },
        ),
      );
      _absorbCookies('$_passportWebBase/num/phonecode', response.headers);
      final body = _asMap(response.data);
      _log(
        '[chaoxing-auth] phonecode status=${response.statusCode} '
        'body=${response.data}',
      );
      if (body['result'] != true) {
        final reason = (body['msg'] ?? body['mes'] ?? '').toString();
        final raw = '${response.data}'.replaceAll(RegExp(r'\s+'), ' ');
        throw ChaoxingCaptchaSendFailure(
          reason.isEmpty
              ? 'phonecode refused (${response.statusCode}): '
                    '${raw.substring(0, raw.length.clamp(0, 180))}'
              : reason,
        );
      }
    } on ChaoxingAuthFailure {
      rethrow;
    } on Object catch (error) {
      throw ChaoxingNetworkFailure(error.toString());
    }
  }

  /// Submits the SMS [code] for [challenge] and finishes the login.
  ///
  /// `POST /v11/checkmessage?enc2=&time=&type=0`. On success the page hands off
  /// to `userLogin4Uname.do`, which is the same SSO endpoint a normal login
  /// follows, so this harvests the session the same way. [deviceInfo] is posted
  /// there so the server binds a `clientId` — that binding is the whole point of
  /// verifying the device.
  ///
  /// A `type == 1` success means the account's password was flagged weak and the
  /// server wants it reset before issuing a session; that comes back as
  /// [ChaoxingPasswordResetRequired] carrying the reset token, not a session.
  Future<ChaoxingSession> completeDeviceVerification(
    ChaoxingSecondaryVerificationRequired challenge, {
    required String phone,
    required String code,
    String? deviceInfo,
    String countryCode = '86',
  }) async {
    Map<String, dynamic> body;
    try {
      final response = await _dio.post<dynamic>(
        '$_passportWebBase/v11/checkmessage',
        queryParameters: {
          'enc2': challenge.enc2,
          'time': challenge.time,
          'type': '0',
        },
        options: Options(
          headers: {
            ..._headersFor('$_passportWebBase/v11/checkmessage'),
            'Referer': '$_passportWebBase/v11/tocheckmessage',
          },
          contentType: Headers.formUrlEncodedContentType,
        ),
        data: {
          'countrycode': countryCode,
          'phone': phone,
          'vcode': code,
          'fid': '',
          'loginTimeout': '0',
        },
      );
      _absorbCookies('$_passportWebBase/v11/checkmessage', response.headers);
      body = _asMap(response.data);
    } on ChaoxingAuthFailure {
      rethrow;
    } on Object catch (error) {
      throw ChaoxingNetworkFailure(error.toString());
    }

    if (body['status'] != true) {
      throw ChaoxingBadCredentials(
        (body['mes'] ?? body['msg'] ?? '验证码错误').toString(),
      );
    }
    if ('${body['type']}' == '1') {
      throw ChaoxingPasswordResetRequired(
        uid: (body['userid'] ?? challenge.uid).toString(),
        token: (body['token'] ?? '').toString(),
      );
    }

    // The web host's session is what the SSO hop exchanges for the identity
    // cookies. `sso.chaoxing.com` shares the parent domain, so a browser would
    // send it along; replicate that, since the jars are otherwise per host.
    _carryCookies(_passportWebBase, _ssoLoginUrl);
    await _followSso(_ssoLoginUrl, deviceInfo);

    final puid = _cookieValue('sso_puid') ?? _cookieValue('_tid') ?? '';
    final uid = _cookieValue('_uid') ?? _cookieValue('UID') ?? challenge.uid;
    final fid = _cookieValue('fid') ?? '';
    if (puid.isEmpty) {
      throw const ChaoxingNetworkFailure(
        'device verification did not return an identity',
      );
    }
    return ChaoxingSession(
      cookieHeader: _cookieHeader,
      puid: puid,
      uid: uid,
      fid: fid,
      clientId: _clientId,
      savedAt: DateTime.now(),
    );
  }

  /// Normalises a response body to a string-keyed map.
  ///
  /// dio decodes `application/json` itself, and the decoded map is
  /// `Map<dynamic, dynamic>` rather than `Map<String, dynamic>`, so a plain
  /// `as Map<String, dynamic>` cast throws. Endpoints such as `/num/phonecode`
  /// also answer with a raw JSON string, which has to be decoded first. Anything
  /// that is not an object becomes an empty map so the caller reports the
  /// server's refusal instead of a cast error.
  Map<String, dynamic> _asMap(dynamic raw) {
    var body = raw;
    if (body is String) {
      try {
        body = jsonDecode(body);
      } catch (_) {}
    }
    if (body is Map) return body.map((key, value) => MapEntry('$key', value));
    return const {};
  }

  /// POSTs the SSO url returned by loginregister, walking redirects by hand so
  /// every hop feeds the cookie jar.
  ///
  /// The official client posts `data=<deviceInfo>` here (`C22347e.m90144d` →
  /// `AccountManager.java:1176`) and deserialises the body into
  /// `LoginResult{result, errorCode, errorMsg, msg: Account{clientId, …}}`.
  /// That `clientId` is the encrypted device blob; without posting a deviceInfo
  /// the server has nothing to bind, so the field comes back empty.
  Future<void> _followSso(String url, String? deviceInfo) async {
    try {
      // Walk at most a handful of redirects manually: each hop may drop more
      // cookies, and dio's own redirect following would not feed our jar.
      var next = url;
      for (var hop = 0; hop < 5; hop++) {
        final response = await _dio.post<dynamic>(
          next,
          options: Options(
            headers: _headersFor(next),
            contentType: Headers.formUrlEncodedContentType,
          ),
          data: <String, String>{
            if (deviceInfo != null && deviceInfo.isNotEmpty) 'data': deviceInfo,
          },
        );
        _absorbCookies(next, response.headers);
        _harvestClientId(response.data);
        final location = response.headers.value('location');
        final code = response.statusCode ?? 0;
        if ((code == 301 || code == 302 || code == 303 || code == 307) &&
            location != null &&
            location.isNotEmpty) {
          next = Uri.parse(next).resolve(location).toString();
          continue;
        }
        break;
      }
    } on Object catch (error) {
      // A failed SSO follow still leaves the passport cookies; identity
      // extraction below decides whether the session is usable.
      _log('[chaoxing-auth] SSO follow failed: $error');
    }
  }

  /// Pulls `msg.clientId` out of a `LoginResult` body. Best-effort and silent:
  /// a missing clientId only costs the device identity, never the login.
  void _harvestClientId(dynamic rawBody) {
    if (_clientId.isNotEmpty) return;
    var body = rawBody;
    if (body is String) {
      try {
        body = jsonDecode(body);
      } on FormatException {
        return;
      }
    }
    if (body is! Map) return;
    final msg = body['msg'];
    if (msg is Map) {
      final clientId = (msg['clientId'] ?? '').toString();
      if (clientId.isNotEmpty) _clientId = clientId;
    }
  }

  // -------------------------------------------------------------------
  // Profile
  // -------------------------------------------------------------------

  /// Best-effort display name via extenduserinfo. Never throws: a failed
  /// lookup must not fail the login.
  Future<String?> fetchDisplayName(ChaoxingSession session) async {
    final uid = session.uid;
    if (uid.isEmpty) return null;
    try {
      final enc = md5Hex('$uid$_userInfoSalt');
      final response = await _dio.get<dynamic>(
        '$_passportBase/api/extenduserinfo',
        queryParameters: {'uid': uid, 'enc': enc, 'last': '1'},
        options: Options(
          headers: {
            'User-Agent': userAgent,
            'Accept-Language': 'zh-CN,zh;q=0.9',
            'Cookie': session.cookieHeader,
          },
        ),
      );
      var rawBody = response.data;
      if (rawBody is String) {
        try {
          rawBody = jsonDecode(rawBody);
        } catch (_) {}
      }
      final data = (rawBody as Map?)?['data'];
      if (data is Map<String, dynamic>) {
        final uname = (data['lastuname'] ?? '').toString();
        return uname.isEmpty ? null : uname;
      }
    } on Object catch (error) {
      _log('[chaoxing-auth] profile lookup failed: $error');
    }
    return null;
  }
}
