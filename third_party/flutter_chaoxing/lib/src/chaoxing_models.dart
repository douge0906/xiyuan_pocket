/// Domain models for the 学习通 (Chaoxing) account integration.
///
/// The login protocol was reverse-engineered from the official Android client
/// 7.0.2:
///
/// - Password login: `POST passport2-api.chaoxing.com/v11/loginregister` with
///   `logininfo = Base64(AES-128-ECB/PKCS5({"uname":…,"code":…}))`. The AES key
///   is a constant embedded in the official client.
/// - SMS login: `POST …/api/sendcaptcha` (enc = MD5(phone + salt + millis)),
///   then the same `loginregister` call with the SMS code in the `code` field.
/// - A successful login returns an SSO `url` that must be POSTed to harvest the
///   full cookie set (`fid`, `_uid`, `_tid`, `sso_puid`, …).
library;

/// How the user authenticates against passport2.
enum ChaoxingLoginMode {
  /// Account (phone / student id) + password.
  password,

  /// Phone + SMS verification code.
  sms,
}

/// Credentials entered by the user, persisted only when "remember" is on.
class ChaoxingCredentials {
  /// Creates a credential pair for [account] using [mode].
  const ChaoxingCredentials({
    required this.account,
    required this.password,
    this.mode = ChaoxingLoginMode.password,
  });

  /// Phone number or student id ("uname" in the protocol).
  final String account;

  /// Password, or the one-time SMS code when [mode] is [ChaoxingLoginMode.sms].
  /// An SMS code is single-use; the store never persists it.
  final String password;

  /// Which passport2 challenge [password] answers.
  final ChaoxingLoginMode mode;
}

/// The session harvested after a successful login + SSO follow.
///
/// [cookieHeader] is the raw `name=value; …` string replayed on every
/// subsequent API call; the individual identity fields are kept parsed for the
/// UI and for building signed requests.
class ChaoxingSession {
  /// Creates a session from an already-harvested cookie jar and identity.
  const ChaoxingSession({
    required this.cookieHeader,
    required this.puid,
    required this.uid,
    required this.fid,
    required this.savedAt,
    this.name = '',
    this.clientId = '',
  });

  /// Raw `name=value; …` cookie string replayed on every API call.
  final String cookieHeader;

  /// The `sso_puid` (or `_tid`) identity cookie.
  final String puid;

  /// The `_uid` identity cookie.
  final String uid;

  /// The `fid` (institution) cookie.
  final String fid;

  /// When the session was harvested.
  final DateTime savedAt;

  /// Display name when the profile call succeeded; empty otherwise.
  final String name;

  /// The server-issued encrypted device blob from `LoginResult.msg.clientId`.
  ///
  /// `qh/C36033a.m148784b` runs it through the native
  /// `CxDevice.decryptDeviceInfo` to obtain the `cxcid`/`sc` pair that the
  /// `cxsign` header and the `CLIENT_FORM_SIGN` bridge both need — see
  /// `ChaoxingSignService.resolveDeviceIdentity`. Empty when the SSO response
  /// did not carry one (e.g. because no `deviceInfo` was posted with it).
  final String clientId;

  /// True when the cookie jar and [puid] are both present.
  bool get isValid => cookieHeader.trim().isNotEmpty && puid.isNotEmpty;

  /// True when [clientId] is present and can be turned into a device identity.
  bool get hasDeviceIdentity => clientId.trim().isNotEmpty;

  /// Serialises the session for persistence.
  Map<String, dynamic> toJson() => {
    'cookieHeader': cookieHeader,
    'puid': puid,
    'uid': uid,
    'fid': fid,
    'name': name,
    'clientId': clientId,
    'savedAt': savedAt.toUtc().toIso8601String(),
  };

  /// Restores a session from [toJson] output.
  factory ChaoxingSession.fromJson(Map<String, dynamic> json) {
    return ChaoxingSession(
      cookieHeader: json['cookieHeader'] as String? ?? '',
      puid: json['puid'] as String? ?? '',
      uid: json['uid'] as String? ?? '',
      fid: json['fid'] as String? ?? '',
      name: json['name'] as String? ?? '',
      clientId: json['clientId'] as String? ?? '',
      savedAt:
          DateTime.tryParse(json['savedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  /// Returns a copy with [name] and/or [clientId] replaced.
  ChaoxingSession copyWith({String? name, String? clientId}) => ChaoxingSession(
    cookieHeader: cookieHeader,
    puid: puid,
    uid: uid,
    fid: fid,
    name: name ?? this.name,
    clientId: clientId ?? this.clientId,
    savedAt: savedAt,
  );
}

/// Typed failures so the UI can explain what went wrong instead of showing a
/// raw exception string.
sealed class ChaoxingAuthFailure implements Exception {
  /// Base constructor for the typed auth failures.
  const ChaoxingAuthFailure();
}

/// The server rejected the credentials (`status=false` on loginregister).
class ChaoxingBadCredentials extends ChaoxingAuthFailure {
  /// Creates a bad-credentials failure with a server-supplied [message].
  const ChaoxingBadCredentials(this.message);

  /// Human-readable reason returned by passport2.
  final String message;

  @override
  String toString() => message;
}

/// The server demanded an interactive captcha page (`webUrl` present). Cannot
/// be solved headlessly; the user must log in inside the official app or retry
/// later from a different network.
class ChaoxingCaptchaRequired extends ChaoxingAuthFailure {
  /// Creates a captcha-required failure pointing at [webUrl].
  const ChaoxingCaptchaRequired(this.webUrl);

  /// The interactive verification page the server wants opened.
  final String webUrl;

  @override
  String toString() => 'captcha required: $webUrl';
}

/// The password was accepted but passport2 insists on a second factor before it
/// will hand out an SSO url.
///
/// This is *not* the same as [ChaoxingCaptchaRequired]: here `status` is `true`
/// and the body looks like
///
/// ```json
/// {"webUrl":"https://passport2.chaoxing.com/v11/tocheckmessage?uid=…&enc=…
///             &time=…&enc2=…","type":2,"status":true}
/// ```
///
/// There is **no** `url` field, so there is nothing to SSO against and the
/// session cannot be harvested. An earlier build fell through to a generic
/// `SSO did not return an identity` network failure here, which sent callers
/// looking for a transport bug instead of a risk-control decision.
///
/// The `tocheckmessage` page renders `#type=0`, i.e. *new-device login by SMS*:
/// it gates `GET /num/phonecode` behind a CXCaptcha (asked as `textclick`, solved
/// as `slide` since `type` is not pinned) plus a numeric
/// image code, then posts the code to `/v11/checkmessage`. Completing that needs
/// a human-readable SMS, so it is out of scope for a headless client — surface
/// it to the user instead.
///
/// Observed trigger: a plaintext (un-crypted) official User-Agent. See
/// [ChaoxingUserAgent] — passport2 risk control accepts an ordinary browser UA
/// and rejects the reconstructed `ChaoXingStudy` suffix, which is the opposite
/// of what the learn APIs want.
class ChaoxingSecondaryVerificationRequired extends ChaoxingAuthFailure {
  /// Creates a secondary-verification failure for [webUrl].
  const ChaoxingSecondaryVerificationRequired({
    required this.webUrl,
    this.uid = '',
    this.enc = '',
    this.enc2 = '',
    this.time = '',
    this.responseType = 0,
  });

  /// Builds one from a `loginregister` body, pulling the state tokens out of
  /// `webUrl`'s query string.
  factory ChaoxingSecondaryVerificationRequired.fromBody(
    Map<String, dynamic> body,
  ) {
    final webUrl = '${body['webUrl'] ?? ''}';
    final query = Uri.tryParse(webUrl)?.queryParameters ?? const {};
    return ChaoxingSecondaryVerificationRequired(
      webUrl: webUrl,
      uid: query['uid'] ?? '',
      enc: query['enc'] ?? '',
      enc2: query['enc2'] ?? '',
      time: query['time'] ?? '',
      responseType: int.tryParse('${body['type']}') ?? 0,
    );
  }

  /// The `tocheckmessage` page the user has to complete.
  final String webUrl;

  /// The `uid` the challenge is bound to.
  final String uid;

  /// `enc` — the challenge state token.
  final String enc;

  /// `enc2` — posted back to `/v11/checkmessage` / `/v11/checkPassword`.
  final String enc2;

  /// `time` — the challenge's issue timestamp; `enc2`/`time` are validated as a
  /// pair and expire.
  final String time;

  /// The `type` field from the login body (`2` in every live observation). Note
  /// this is *not* the page's own `#type`, which selects SMS vs password.
  final int responseType;

  @override
  String toString() => 'secondary verification required (uid $uid): $webUrl';
}

/// The SMS code checked out, but passport2 refuses to issue a session until the
/// password is reset.
///
/// `checkmessage` answers `{"status":true,"type":"1","userid":…,"token":…}` for
/// an account whose password it considers weak. The page then opens
/// `/v11/updateweakpwd?uid=&token=`. There is no session yet — the reset has to
/// happen first — so this is a failure rather than a login result.
class ChaoxingPasswordResetRequired extends ChaoxingAuthFailure {
  /// Creates a password-reset demand for [uid] gated by [token].
  const ChaoxingPasswordResetRequired({required this.uid, required this.token});

  /// The account the reset applies to.
  final String uid;

  /// Single-use token posted to `/v11/updateweakpwd`.
  final String token;

  @override
  String toString() => 'password reset required (uid $uid)';
}

/// SMS code request failed (rate limit, unregistered phone, bad enc).
class ChaoxingCaptchaSendFailure extends ChaoxingAuthFailure {
  /// Creates an SMS-send failure with a server-supplied [message].
  const ChaoxingCaptchaSendFailure(this.message);

  /// Human-readable reason returned by the sendcaptcha endpoint.
  final String message;

  @override
  String toString() => message;
}

/// Network / unexpected response shape.
class ChaoxingNetworkFailure extends ChaoxingAuthFailure {
  /// Creates a network failure with a diagnostic [message].
  const ChaoxingNetworkFailure(this.message);

  /// Diagnostic describing the transport or parsing failure.
  final String message;

  @override
  String toString() => message;
}
