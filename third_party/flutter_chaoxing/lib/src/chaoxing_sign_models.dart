/// Domain models for 学习通 classroom activities and sign-in, mirroring the
/// official Android client 7.0.2 exactly.
///
/// Recovered from the decompiled 7.0.2 images, including the runtime dump of
/// DEX images 9–12. Authoritative sources:
///
/// - `com/chaoxing/fanya/common/model/StudentMission.java` — the activity row.
/// - `com/chaoxing/fanya/aphone/ui/course/StudentMissionFragment.java:1075`
///   (`H9`) — the `activeType` dispatch table.
/// - `com/chaoxing/mobile/course/persistence/C10730b0.java:55` — the
///   `backclazzdata` envelope (`{result:1, channelList:[…]}`).
/// - `com/chaoxing/mobile/course/persistence/C10750j0.java:122` — the
///   `taskactivelist` envelope (`{status:1, activeList:[…], groupList:[…]}`).
/// - `com/chaoxing/mobile/webapp/table/ProtocolTable_Impl.java:499` —
///   `CLIENT_FORM_SIGN`, and `vr/C37772b.java` which implements it.
///
/// ## The load-bearing finding
///
/// **The official Android client has no native sign-submit endpoint.** `H9`
/// handles live (17), topics (5), chat (27), notices (34/45) and a few others
/// specially; *everything else — including every sign flavour — falls through to
/// the default branch, which simply opens the server-supplied
/// [ChaoxingMission.url] in a WebView*. The words `otherId`, `ifphoto`,
/// `ifopenAddress`, `ifrefreshewm` and `signCode` do not appear anywhere in the
/// 69,685 recovered classes: they belong to the H5 page's own protocol, not to
/// the app.
///
/// What the app *does* contribute to a sign is two JS bridges:
///
/// - `CLIENT_FORM_SIGN` — RSA-signs the page's form fields and returns
///   `{cxcid, paramToken, cxtime, signToken, …}` (see [ChaoxingFormSignTokens]).
/// - `CLIENT_USER_LOCATION` — supplies GPS to the page.
///
/// So an implementation that wants official parity drives the H5 page and
/// answers those bridges, rather than inventing a submit URL.
library;

/// What the official client does with an activity, per the `H9` dispatch table.
///
/// [webView] is the default branch and covers **all** classroom sign-ins: the
/// client opens [ChaoxingMission.url] and the page takes it from there.
enum ChaoxingMissionAction {
  /// activeType 17 — live stream (`b9` → `LiveParams.streamName`/`vdoid`).
  live,

  /// activeType 44 — `K9`, its own native flow.
  special44,

  /// activeType 5 — topic/discussion; `extraInfo` carries `groupId` + `topicId`.
  topic,

  /// activeType 27 — chat-backed; `extraInfo` carries `chatId`. When
  /// `status == 1` the client opens the chat natively, otherwise it falls back
  /// to the WebView url.
  chat,

  /// activeType 34 / 45 — notice, opened via `NoticeBodyActivity`.
  notice,

  /// activeType 46 / 48 / 58 — native handlers driven entirely by `extraInfo`.
  extraInfoNative,

  /// activeType 30 — WebView, with `&from=1` appended.
  webViewFrom,

  /// Every other activeType, **including all sign-ins** — plain WebView.
  webView;

  /// Mirrors `StudentMissionFragment.H9`.
  static ChaoxingMissionAction fromActiveType(int activeType) =>
      switch (activeType) {
        17 => ChaoxingMissionAction.live,
        44 => ChaoxingMissionAction.special44,
        5 => ChaoxingMissionAction.topic,
        27 => ChaoxingMissionAction.chat,
        34 || 45 => ChaoxingMissionAction.notice,
        46 || 48 || 58 => ChaoxingMissionAction.extraInfoNative,
        30 => ChaoxingMissionAction.webViewFrom,
        _ => ChaoxingMissionAction.webView,
      };
}

/// One enrolled course/class pair.
///
/// `backclazzdata` returns `Resource` rows whose `content` field is itself a
/// JSON object holding a `Course` (with a nested `clazz` array). The official
/// models are `com/chaoxing/fanya/common/model/Course.java` and `Clazz.java`,
/// both extending `BaseGearBean` (which supplies the `id` field).
class ChaoxingCourse {
  /// Creates a course/class pair.
  const ChaoxingCourse({
    required this.courseId,
    required this.classId,
    required this.courseName,
    this.className = '',
    this.cpi = '',
    this.teacher = '',
    this.imageUrl = '',
    this.personid = '',
    this.fid = '',
    this.chatid = '',
    this.bbsid = '',
    this.hasSign = false,
  });

  /// `Course.id` (`BaseGearBean.id`).
  final String courseId;

  /// `Clazz.id`.
  final String classId;

  /// `Course.name`.
  final String courseName;

  /// `Clazz.name`.
  final String className;

  /// "course person id" — opaque per-enrollment token.
  final String cpi;

  /// `Course.teacherfactor`.
  final String teacher;

  /// `Course.imageurl`.
  final String imageUrl;

  /// `Course.personid`.
  final String personid;

  /// `Course.fid` (institution id).
  final String fid;

  /// `Clazz.chatid` — needed by the chat-backed activities (activeType 27).
  final String chatid;

  /// `Clazz.bbsid` — the discussion board id, used by the topic/discussion API
  /// (`ChaoxingApiService.fetchTopicList`).
  final String bbsid;

  /// `Clazz.hasSign`.
  final bool hasSign;
}

/// A classroom activity row — the official `StudentMission`.
///
/// Field names match the JSON keys the client parses with Gson, so this is the
/// wire shape, not an invention.
class ChaoxingMission {
  /// Creates an activity row.
  const ChaoxingMission({
    required this.id,
    required this.activeType,
    this.status = 0,
    this.startTime = 0,
    this.nameOne = '',
    this.nameTwo = '',
    this.nameFour = '',
    this.url = '',
    this.extraInfo = '',
    this.picUrl = '',
    this.attendNum = 0,
    this.releaseNum = 0,
    this.groupId = 0,
    this.isLook = 0,
    this.resourceType = 0,
    this.description = const {},
  });

  /// Parses one entry of the `activeList` array.
  factory ChaoxingMission.fromMap(Map<String, dynamic> map) {
    int asInt(dynamic v) =>
        v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
    int asLong(dynamic v) =>
        v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;

    return ChaoxingMission(
      id: (map['id'] ?? '').toString(),
      activeType: asInt(map['activeType']),
      status: asInt(map['status']),
      startTime: asLong(map['startTime']),
      nameOne: (map['nameOne'] ?? '').toString(),
      nameTwo: (map['nameTwo'] ?? '').toString(),
      nameFour: (map['nameFour'] ?? '').toString(),
      url: (map['url'] ?? '').toString(),
      extraInfo: (map['extraInfo'] ?? '').toString(),
      picUrl: (map['picUrl'] ?? '').toString(),
      attendNum: asInt(map['attendNum']),
      releaseNum: asInt(map['releaseNum']),
      groupId: asInt(map['groupId']),
      isLook: asInt(map['isLook']),
      resourceType: asInt(map['resourceType']),
      description: map['description'] is Map
          ? (map['description'] as Map).cast<String, dynamic>()
          : const {},
    );
  }

  /// `StudentMission.id`.
  final String id;

  /// Dispatch key for [ChaoxingMissionAction.fromActiveType].
  final int activeType;

  /// 1 = running, 2 = ended (0 = unset).
  final int status;

  /// Epoch millis when the activity started.
  final int startTime;

  /// First display name slot.
  final String nameOne;

  /// Second display name slot.
  final String nameTwo;

  /// Fourth display name slot.
  final String nameFour;

  /// The H5 page the official client opens for this activity. For sign-ins this
  /// is the whole story — there is no native submit call.
  final String url;

  /// Opaque blob; `H9` pulls `chatId` / `groupId` / `topicId` out of it for the
  /// native branches. The server sends a nested object for notices, topics and
  /// chat-backed activities (e.g. `{"noticeId": 1245656968}`); it is kept as the
  /// raw `toString()` so [noticeId] can regex it without a JSON round-trip.
  final String extraInfo;

  /// The notice id for a notice activity (`activeType` 34/45), pulled from
  /// [extraInfo]. Empty for every other activity. The official client opens
  /// these natively (`NoticeBodyActivity`) rather than via [url]'s intermediate
  /// page, whose 查看 button only fires a `CLIENT_OPEN_NOTICE_BYID` bridge call
  /// carrying this same id.
  ///
  /// Matches both the JSON form (`"noticeId":123`) and the Dart `Map.toString()`
  /// form (`noticeId: 123`) since [extraInfo] is whatever the server's object
  /// stringified to.
  String get noticeId =>
      RegExp(r'noticeId"?\s*[:=]\s*"?(\d+)').firstMatch(extraInfo)?.group(1) ??
      '';

  /// Activity cover image URL.
  final String picUrl;

  /// Number of participants.
  final int attendNum;

  /// Number released by the teacher.
  final int releaseNum;

  /// Group id, when the activity is group-scoped.
  final int groupId;

  /// Look/visibility flag.
  final int isLook;

  /// Resource type code.
  final int resourceType;

  /// Free-form description map.
  final Map<String, dynamic> description;

  /// The `H9` dispatch outcome for [activeType].
  ChaoxingMissionAction get action =>
      ChaoxingMissionAction.fromActiveType(activeType);

  /// True while the activity is still open ([status] == 1).
  bool get isRunning => status == 1;

  /// True when the official client would open [url] in a WebView. Sign-ins land
  /// here; this is the hook a driver should filter on.
  bool get isWebViewDriven =>
      action == ChaoxingMissionAction.webView ||
      action == ChaoxingMissionAction.webViewFrom;
}

/// The `CLIENT_FORM_SIGN` request payload (`vr/C37772b.mo3053c`).
///
/// The H5 page posts `{typeFlag, data:{…}}`; `data` is the field bag that gets
/// RSA-signed and then echoed back alongside the tokens.
class ChaoxingFormSignRequest {
  /// Creates a form-sign request.
  const ChaoxingFormSignRequest({
    required this.typeFlag,
    required this.data,
    this.checkCount = 0,
    this.sslStatus = 1,
    this.extraCode,
  });

  /// Parses the raw JSON string the bridge hands over. Returns null when the
  /// payload has no usable `data` object — the native code answers with
  /// `result: 2` in that case.
  static ChaoxingFormSignRequest? tryParse(Map<String, dynamic> json) {
    final data = json['data'];
    if (data is! Map) return null;
    return ChaoxingFormSignRequest(
      typeFlag: (json['typeFlag'] ?? '').toString(),
      data: data.cast<String, dynamic>(),
    );
  }

  /// Echoed back to the page unchanged.
  final String typeFlag;

  /// The field bag that gets RSA-signed.
  final Map<String, dynamic> data;

  /// `SslResult.getCheckCount()`, echoed back unchanged.
  final int checkCount;

  /// `SslResult.getRealStatus()`. The native path only signs when this is 1;
  /// anything else takes the error branch.
  final int sslStatus;

  /// `SslResult.getExtra()`, surfaced as `extraInfo.code` when present.
  final String? extraCode;
}

/// The `CLIENT_FORM_SIGN` response (`vr/C37772b.m156888H`).
///
/// Field order and names are exactly what gets handed back to the page's JS
/// callback, so a WebView bridge can return this verbatim.
class ChaoxingFormSignTokens {
  /// Creates a form-sign token bundle.
  const ChaoxingFormSignTokens({
    required this.cxcid,
    required this.paramToken,
    required this.cxtime,
    required this.signToken,
    required this.typeFlag,
    required this.checkCount,
    required this.result,
    this.extraCode,
  });

  /// Device id from `DeviceInfo.cid` — server-provisioned, see
  /// [ChaoxingDeviceIdentity].
  final String cxcid;

  /// `SecurityLib.webRequestSign(data)` — RSA-SHA256 over the sorted
  /// `key + value` concatenation, base64.
  final String paramToken;

  /// `System.currentTimeMillis()` at signing time, as a decimal string.
  final String cxtime;

  /// `bw/C3026c.m4937b` — MD5 over the sorted `key + value` concatenation of
  /// `{…data, paramToken, cxtime, cxcid}` plus the device secret.
  final String signToken;

  /// Echoed from the request.
  final String typeFlag;

  /// Echoed from the request.
  final int checkCount;

  /// `SslResult.getRealStatus()`; 1 means the cert check passed and the tokens
  /// are populated.
  final int result;

  /// Surfaced as `extraInfo.code` when non-empty.
  final String? extraCode;

  /// Serialises the bundle exactly as the bridge returns it to the page.
  Map<String, dynamic> toJson() => {
    'cxcid': cxcid,
    'paramToken': paramToken,
    'cxtime': cxtime,
    'signToken': signToken,
    'typeFlag': typeFlag,
    'checkCount': checkCount,
    'result': result,
    if (extraCode != null && extraCode!.isNotEmpty)
      'extraInfo': {'code': extraCode},
  };

  /// The native error branch (`m156887G`): empty `signToken`, no `paramToken`.
  static ChaoxingFormSignTokens failure({
    required String typeFlag,
    required int checkCount,
    required int result,
    String? extraCode,
  }) => ChaoxingFormSignTokens(
    cxcid: '',
    paramToken: '',
    cxtime: '',
    signToken: '',
    typeFlag: typeFlag,
    checkCount: checkCount,
    result: result,
    extraCode: extraCode,
  );
}

/// The device-provisioned identity behind `cxcid` and the `cxsign` secret.
///
/// `qh/C36033a.m148784b` obtains `AccountManager…getClientId()`, runs it
/// through the native `CxDevice.decryptDeviceInfo` (RSA **public**-key decrypt)
/// and deserialises the result into `com/chaoxing/mobile/device/DeviceInfo`,
/// whose `cid` and `sc` fields are these two values.
///
/// Consequence: **the `cxsign` secret is not a constant in the APK.** It is
/// issued per installation, so a headless client must either run the device
/// registration flow or be handed a captured pair. `webRequestSign`'s RSA key,
/// by contrast, *is* embedded and needs no provisioning.
class ChaoxingDeviceIdentity {
  /// Creates a device identity from the decrypted `cid`/`sc` pair.
  const ChaoxingDeviceIdentity({required this.cxcid, required this.sc});

  /// `DeviceInfo.cid` — sent as the `cxcid` query parameter.
  final String cxcid;

  /// `DeviceInfo.sc` — the secret appended before the `cxsign`/`signToken` MD5.
  final String sc;

  /// True when both halves are present.
  bool get isValid => cxcid.isNotEmpty && sc.isNotEmpty;
}

/// A scanned sign payload.
///
/// Three shapes reach a client in the wild, and they take different routes:
///
/// - `SIGNIN:<payload>` — what the official app's scanner produces; fed verbatim
///   to `newsign/studentSign?rcode=&uid=` as the `rcode`.
/// - `https://mobilelearn.chaoxing.com/widget/sign/e?id=<activeId>&enc=<enc>` —
///   an H5 QR; `id`/`enc` are consumed by the H5 page.
/// - `https://mobilelearn.chaoxing.com/widget/sign/signIn?activeId=<id>&ewnCode=<code>`
///   — the rotating-code variant (`ifrefreshewm`).
class ChaoxingScanTarget {
  /// Creates a scan target.
  const ChaoxingScanTarget({
    required this.raw,
    required this.activeId,
    this.enc,
    this.ewnCode,
    this.rcode,
  });

  /// The full scanned string, verbatim.
  final String raw;

  /// Resolved activity id (empty for bare `SIGNIN:` payloads).
  final String activeId;

  /// `enc` query param of the `widget/sign/e` shape.
  final String? enc;

  /// Rotating code of the `widget/sign/signIn` shape.
  final String? ewnCode;

  /// Full scanned payload for `newsign/studentSign?rcode=`; only set for bare
  /// `SIGNIN:` strings, whose activeId the server resolves.
  final String? rcode;

  /// True when this is the shape the official Android client natively handles.
  bool get isNativeRcode => rcode != null;
}

/// The device fingerprint fields that `CxDevice.getDeviceInfo` packs into JSON
/// before RSA-encrypting them.
///
/// Recovered from `libsecuritylib.so:0x78754`: 18 assignments through
/// `Json::Value::operator[](const char*)`, eight of them fed by
/// `__system_property_get`, plus `Device::getPackageInfo` (app name/version),
/// `Device::getResInfo` (resolution/dpi) and `gettimeofday`.
///
/// `time_stamp` is **milliseconds** — the native code does
/// `tv_sec * 1000 + tv_usec / 1000` (the `0x20c49ba5e353f7cf` magic constant is
/// the reciprocal-multiply for /1000) and stores it via `Json::Value(unsigned
/// long)`, i.e. a JSON number, not a string.
///
/// Four fields are marked [unresolved] below: their values are produced inside
/// JNI or the OAID SDK and were not pinned down. They are modelled as
/// caller-supplied so a real device can fill them in, rather than being faked
/// here.
class ChaoxingDeviceProfile {
  /// Creates a device fingerprint profile.
  const ChaoxingDeviceProfile({
    required this.deviceId,
    required this.appName,
    required this.appVer,
    required this.osVer,
    required this.osLang,
    required this.cpuArch,
    required this.resolution,
    required this.dpi,
    required this.brand,
    required this.hardware,
    required this.board,
    this.oaid = '',
    this.platform = 'android',
    this.osName = 'android',
    this.timeStamp,
    this.mediaDrmId,
    this.cdtype,
    this.cdid,
  });

  /// The `uniqueId` — see `ChaoxingSignCrypto.newUniqueId`. Passed in as the
  /// second argument to the native `getDeviceInfo`.
  final String deviceId;

  /// `ro.product.brand` / package info.
  final String appName;

  /// Application version name.
  final String appVer;

  /// `ro.build.version.release`.
  final String osVer;

  /// `ro.product.locale.language`.
  final String osLang;

  /// `ro.product.cpu.abilist`.
  final String cpuArch;

  /// From `Device::getResInfo`.
  final String resolution;

  /// Screen density, from `Device::getResInfo`.
  final String dpi;

  /// `ro.product.brand`.
  final String brand;

  /// `ro.hardware`.
  final String hardware;

  /// `ro.product.board`.
  final String board;

  /// From the OAID SDK (the fourth native argument).
  final String oaid;

  // --- Field sources confirmed by static RE of `getDeviceInfo` (7.0.2) ------
  // The JSON key insertion order is: platform, app_name, app_ver, mediaDrmId,
  // cdtype, os_name, os_ver, os_lang, cpu_ar, resolution, brand, hardware,
  // board, dpi, device_id, oaid, cdid, time_stamp. jsoncpp sorts object keys on
  // output, so the wire JSON is alphabetical regardless (see `fastWriterJson`).

  /// `"android"`. The constant sits in the `getDeviceInfo` `.rodata` string
  /// cluster (`libsecuritylib.so` 7.0.2 @ `0x52409`, between the `mediaDrmId`
  /// and `os_name` keys); high confidence, exact load not traced.
  final String platform;

  /// `"android"`; same evidence as [platform].
  final String osName;

  /// Milliseconds since epoch; defaults to "now" when null.
  final int? timeStamp;

  /// Read at runtime via JNI `Settings.Secure.getString(resolver, …)` — the
  /// `(Landroid/content/ContentResolver;Ljava/lang/String;)Ljava/lang/String;`
  /// call sits next to the `mediaDrmId` key in `getDeviceInfo`. Device-specific
  /// (commonly empty); capture from a live client rather than fabricating.
  final String? mediaDrmId;

  /// Two further constants whose values were not recoverable from the
  /// disassembly.
  final String? cdtype;

  /// Companion to [cdtype]; value not recoverable from the disassembly.
  final String? cdid;

  /// The exact JSON object the native code hands to `Json::FastWriter`.
  /// Unresolved optional fields are omitted rather than sent empty, matching
  /// how jsoncpp skips unset members.
  Map<String, dynamic> toJson({int? nowMillis}) => {
    'platform': platform,
    'app_name': appName,
    'app_ver': appVer,
    'os_name': osName,
    'os_ver': osVer,
    'os_lang': osLang,
    'cpu_ar': cpuArch,
    'resolution': resolution,
    'brand': brand,
    'hardware': hardware,
    'board': board,
    'dpi': dpi,
    'device_id': deviceId,
    'oaid': oaid,
    'time_stamp':
        timeStamp ?? nowMillis ?? DateTime.now().millisecondsSinceEpoch,
    if (mediaDrmId != null) 'mediaDrmId': mediaDrmId,
    if (cdtype != null) 'cdtype': cdtype,
    if (cdid != null) 'cdid': cdid,
  };
}

/// Outcome of the 泛雅 native sign submit (`usersign/addsign`).
///
/// `SignInfoActivity` (the one *native* sign path in the client, used for
/// scanned 泛雅 codes rather than classroom activities) reads `result` first:
/// 300 means the call was understood, and only then does it look at the
/// `status` boolean and `msg`.
class ChaoxingFanyaSignResult {
  /// Creates a Fanya sign result.
  const ChaoxingFanyaSignResult({
    required this.result,
    required this.status,
    required this.message,
    this.studentName = '',
    this.data = const {},
    this.raw = '',
  });

  /// 300 = accepted. Anything else maps through [ChaoxingFanyaSignCode].
  final int result;

  /// The `status` boolean, only meaningful when [result] is 300.
  final bool status;

  /// Server-supplied `msg`.
  final String message;

  /// `stuName` from the response.
  final String studentName;

  /// `courseName`, `className`, `addTime.time`, … — passed through unparsed
  /// because only the UI consumes them.
  final Map<String, dynamic> data;

  /// The raw response body, for diagnostics.
  final String raw;

  /// True when the sign was accepted and confirmed.
  bool get isOk => result == 300 && status;

  /// The client's own explanation for a non-300 `result`
  /// (`SignInfoActivity.m82181v5`).
  String? get resultExplanation => ChaoxingFanyaSignCode.explain(result);
}

/// Server result codes for `usersign/addsign`, with the strings the official
/// client shows for each (`SignInfoActivity.m82181v5`).
enum ChaoxingFanyaSignCode {
  /// 300 — accepted.
  ok(300, null),

  /// 301 — database insert failed.
  dbInsertFailed(301, '签到失败（数据库插入失败）'),

  /// 306 — `enc` verification failed.
  encMismatch(306, 'enc验证错误'),

  /// 307 — QR code time window expired.
  qrExpired(307, '二维码时间过期'),

  /// 308 — sign id does not exist.
  signIdMissing(308, '签到id不存在'),

  /// 309 — user does not exist.
  userMissing(309, '用户不存在'),

  /// 310 — bad user unit info.
  badUnit(310, '用户单位信息错误'),

  /// 311 — wrong user role.
  badRole(311, '用户角色错误'),

  /// 312 — system error.
  systemError(312, '系统错误');

  const ChaoxingFanyaSignCode(this.code, this.message);

  /// Numeric `result` value.
  final int code;

  /// Client-facing explanation, or null for [ok].
  final String? message;

  /// Returns the explanation for a numeric [code], or null when unknown.
  static String? explain(int code) {
    for (final value in values) {
      if (value.code == code) return value.message;
    }
    return null;
  }
}

/// Outcome of a classroom sign submit (`pptSign/stuSignajax`).
enum ChaoxingClassroomSignOutcome {
  /// Server answered `success` — the sign is recorded.
  success,

  /// Server answered `success2` — recorded but past the teacher's deadline.
  successPastDeadline,

  /// Server answered `validate` — an anti-cheat captcha token is required.
  /// Obtain one with [ChaoxingCaptchaService.solveSlide] against
  /// [ChaoxingCaptchaService.signCaptchaId] and re-submit with
  /// [ChaoxingSignService.submitClassroomSign]'s `validate` argument.
  validateRequired,

  /// This account already signed this activity. The body is
  /// `您已签到过了`; treat as terminal success rather than an error.
  alreadySigned,

  /// A QR-code sign was submitted without a valid `enc`. The body is
  /// `签到失败，请重新扫描`. The `enc` only exists inside the teacher's live
  /// QR code, so this cannot be satisfied headlessly.
  rescanRequired,

  /// The activity has `openCheckFaceFlag=1` and the server holds no liveness
  /// session record for this (activeId, uid). The body is prefixed `[face]` and
  /// arrives in two stages, both mapped here:
  ///
  /// - `[face]人脸采集失败，请重新进入签到` — `currentFaceId` absent or empty.
  /// - `[face]活体协议验证不通过，请重新进入签到` — `currentFaceId` non-empty (the
  ///   enrolled pan objectId and the literal `"1"` behave identically), but no
  ///   server-side liveness session backs it.
  ///
  /// Measured: `ifCFP` and any `faceEnc`/`faceCode` value change nothing, and
  /// enrolment alone does not help. Enrolment is
  /// `passport2-api…/api/changefaceid?objectid=<panObjectId>`, which runs face
  /// *detection* only — no liveness, no identity check — so any still photo
  /// containing a face enrols. The per-sign gate is separate: it needs a
  /// `signToken` issued to a natively started liveness session
  /// (`/pptSign/check-face-result`, codes `CFR001`/`CFR002`/`CFR003`/`CFR006`).
  faceRequired,

  /// A location sign fell outside the teacher's radius. The body names the
  /// distance, e.g. `距教师指定签到地点1234.0米，不在可签到范围内。`
  outOfRange,

  /// Anything else — the raw body is a human-readable refusal.
  rejected,
}

/// Result of the classroom `stuSignajax` submit.
///
/// The H5 sign page (`newsign/preSign`) posts a plain `GET` to
/// `mobilelearn.chaoxing.com/pptSign/stuSignajax`; the body is a bare token
/// (`success` / `success2` / `validate`) or an error string. Captured live
/// 2026-09-23 from the `纯普通` and `防作弊（验证码）` sign pages.
class ChaoxingClassroomSignResult {
  /// Creates a classroom sign result.
  const ChaoxingClassroomSignResult({required this.outcome, required this.raw});

  /// The classified [outcome].
  final ChaoxingClassroomSignOutcome outcome;

  /// The raw response body.
  final String raw;

  /// True when the sign is recorded — either success variant, or the server
  /// reporting it was already recorded earlier.
  bool get isSigned =>
      outcome == ChaoxingClassroomSignOutcome.success ||
      outcome == ChaoxingClassroomSignOutcome.successPastDeadline ||
      outcome == ChaoxingClassroomSignOutcome.alreadySigned;

  /// True when the server demands an anti-cheat captcha token.
  bool get needsValidate =>
      outcome == ChaoxingClassroomSignOutcome.validateRequired;

  /// Classifies the bare `stuSignajax` response body.
  ///
  /// Only the first three are exact tokens; the rest are the server's
  /// human-readable refusals, matched on stable substrings captured live
  /// 2026-09-24 across all nine sign flavours.
  static ChaoxingClassroomSignResult parse(String body) {
    final t = body.trim();
    final outcome = switch (t) {
      'success' => ChaoxingClassroomSignOutcome.success,
      'success2' => ChaoxingClassroomSignOutcome.successPastDeadline,
      'validate' => ChaoxingClassroomSignOutcome.validateRequired,
      _ when t.contains('已签到') => ChaoxingClassroomSignOutcome.alreadySigned,
      _ when t.contains('重新扫描') => ChaoxingClassroomSignOutcome.rescanRequired,
      _ when t.contains('[face]') => ChaoxingClassroomSignOutcome.faceRequired,
      _ when t.contains('不在可签到范围') => ChaoxingClassroomSignOutcome.outOfRange,
      _ => ChaoxingClassroomSignOutcome.rejected,
    };
    return ChaoxingClassroomSignResult(outcome: outcome, raw: t);
  }
}

/// The sign flavour, decoded from `getPPTActiveInfo`'s `activeSort`.
///
/// Mapped live 2026-09-24 against a course that had all nine flavours
/// published at once. `activeSort` is the only reliable discriminator: the
/// mission list's `activeType` is `2` (WebView-driven) for every one of them.
///
/// | sort | flavour | extra input the submit needs | headless? |
/// |---|---|---|---|
/// | 1 | 纯普通 | — | yes |
/// | 2 | 普通+防作弊 | `validate` from CXCaptcha | yes |
/// | 3 | 普通+拍照 | `objectId` + `photoResult` | yes |
/// | 4 | 位置 | `address` + `latitude`/`longitude` | yes |
/// | 5 | 位置+人脸 | enrolled face + `signToken` | yes |
/// | 6 | 二维码 | `enc` | no — live QR |
/// | 7 | 二维码自动更新 | `enc` (rotates ~30 s) | no — live QR |
/// | 8 | 二维码指定地点 | `enc` + location | no — live QR |
/// | 9 | 签到码 | `signCode`, pre-checked | yes |
///
/// Sort 5 is headless once a face is enrolled. Enrolment
/// (`passport2-api…/api/changefaceid?objectid=<panObjectId>`) runs face
/// *detection* only — any still photo containing a face enrols, with no liveness
/// and no identity check. The per-sign `signToken` is then just an MD5 of the
/// enrolled objectId plus the device `sc` ([ChaoxingSignCrypto.formSignToken]);
/// `/pptSign/check-face-result` exchanges it for the `enc` that `stuSignajax`
/// accepts. The QR flavours stay blocked: `enc` is unobtainable student-side.
enum ChaoxingSignKind {
  /// 纯普通 — no extra input.
  plain(1),

  /// 普通+防作弊（验证码）— `openPreventCheatFlag=1`, `ifNeedVCode=1`.
  antiCheat(2),

  /// 普通+拍照 — upload an image and submit its `objectId`.
  photo(3),

  /// 位置 — submit coordinates inside `locationRange` metres.
  location(4),

  /// 位置+防作弊人脸识别 — `openCheckFaceFlag=1`.
  ///
  /// Headless-capable once a face is enrolled: the `signToken` is an MD5 over
  /// the device's `sc`, not a liveness signature. See
  /// [ChaoxingSignService.submitFaceSign].
  locationWithFace(5),

  /// 二维码 — needs the `enc` from the teacher's QR code.
  qrCode(6),

  /// 二维码自动更新 — the `enc` rotates (commonly every 30 s).
  qrCodeRotating(7),

  /// 二维码指定地点 — QR plus a location check.
  qrCodeAtLocation(8),

  /// 签到码 — a `numberCount`-digit code the teacher displays. `otherId=5`.
  signCode(5),

  /// 手势 — a stroke on the 3×3 grid, submitted as a `signCode`. `otherId=3`.
  ///
  /// The grid is numbered like a phone keypad and the stroke is the code:
  ///
  /// ```
  /// 1 2 3
  /// 4 5 6
  /// 7 8 9
  /// ```
  ///
  /// A vertical line down the middle is `258`; an L down the left column and
  /// along the bottom is `14789`. It uses the same `checkSignCode` endpoint as
  /// [signCode], and a wrong value answers `手势不正确` for both. Measured: an
  /// activity titled 手势-L形 (`activeSort=16`, `numberCount=5`) accepted `14789`.
  gesture(3),

  /// A flavour this build does not know.
  unknown(-1);

  const ChaoxingSignKind(this.sort);

  /// The `activeSort` value on the wire.
  final int sort;

  /// True when the flavour can be satisfied without a camera, a live QR code,
  /// or a human face.
  bool get isHeadlessCapable => switch (this) {
    ChaoxingSignKind.plain => true,
    ChaoxingSignKind.antiCheat => true,
    ChaoxingSignKind.photo => true,
    ChaoxingSignKind.location => true,
    ChaoxingSignKind.locationWithFace => true,
    ChaoxingSignKind.signCode => true,
    ChaoxingSignKind.gesture => true,
    _ => false,
  };

  /// True when the H5 page `POST`s `stuSignajax` instead of `GET`ing it.
  ///
  /// Captured live: only the 纯普通 and 防作弊 pages use `type:"get"`; the 拍照,
  /// 签到码, 位置 and 二维码 pages all use `type:"post"` because they carry
  /// `photoResult` / `locationResult` blobs that are awkward in a query string.
  bool get usesPost => switch (this) {
    ChaoxingSignKind.plain => false,
    ChaoxingSignKind.antiCheat => false,
    ChaoxingSignKind.unknown => false,
    _ => true,
  };

  /// Decodes an `activeSort` value.
  ///
  /// Only reliable for the first batch of an activity plan. `activeSort` is a
  /// per-plan sequence number, not a flavour code: a second batch measured live
  /// came back as sorts 10–16 for the same flavours (plain=10, photo=12,
  /// gesture=16). Prefer [fromOtherId], which is stable.
  static ChaoxingSignKind fromSort(int? sort) =>
      ChaoxingSignKind.values.firstWhere(
        (k) => k.sort == sort,
        orElse: () => ChaoxingSignKind.unknown,
      );

  /// Decodes `getPPTActiveInfo`'s `otherId`, the stable flavour code.
  ///
  /// `otherId` alone cannot see the captcha, photo or face modifiers — those
  /// are flags on the same base type. [resolve] applies them.
  ///
  /// | otherId | base flavour |
  /// |---|---|
  /// | 0 | 普通 |
  /// | 2 | 二维码 |
  /// | 3 | 手势 |
  /// | 4 | 位置 |
  /// | 5 | 签到码 |
  static ChaoxingSignKind fromOtherId(int? otherId) => switch (otherId) {
    0 => ChaoxingSignKind.plain,
    2 => ChaoxingSignKind.qrCode,
    3 => ChaoxingSignKind.gesture,
    4 => ChaoxingSignKind.location,
    5 => ChaoxingSignKind.signCode,
    _ => ChaoxingSignKind.unknown,
  };

  /// The flavour of one activity, from its `otherId` plus the modifier flags.
  ///
  /// Measured across two batches (sorts 1–9 and 10–16): `otherId` picks the
  /// base type and the flags subdivide it. `ifrefreshewm=1` marks the rotating
  /// QR, `ifopenAddress=1` marks the located QR, `openCheckFaceFlag=1` marks
  /// the face location sign, and `ifNeedVCode=1` / `ifphoto=1` split 普通.
  static ChaoxingSignKind resolve({
    required int otherId,
    int ifNeedVCode = 0,
    int ifphoto = 0,
    int openCheckFaceFlag = 0,
    int ifrefreshewm = 0,
    int ifopenAddress = 0,
  }) => switch (otherId) {
    0 when ifNeedVCode == 1 => ChaoxingSignKind.antiCheat,
    0 when ifphoto == 1 => ChaoxingSignKind.photo,
    2 when ifrefreshewm == 1 => ChaoxingSignKind.qrCodeRotating,
    2 when ifopenAddress == 1 => ChaoxingSignKind.qrCodeAtLocation,
    4 when openCheckFaceFlag == 1 => ChaoxingSignKind.locationWithFace,
    _ => fromOtherId(otherId),
  };
}

/// A parsed `v2/apis/active/getPPTActiveInfo` payload.
///
/// This is the endpoint that tells a client *what kind* of sign an activity is
/// and what it demands, so it should be read before choosing a submit shape.
/// Note what it deliberately does **not** leak:
///
/// * `signCode` is always empty — the code for a [ChaoxingSignKind.signCode]
///   activity has to come from the teacher's screen (or the activity title).
/// * `locationLongitude` / `locationLatitude` are empty even though
///   `locationText` names the place. The distance check is server-side, so a
///   client that wants to satisfy it must geocode `locationText` itself.
class ChaoxingActiveInfo {
  /// Creates an activity-info record.
  const ChaoxingActiveInfo({
    required this.activeId,
    required this.kind,
    required this.status,
    this.raw = const {},
    this.parentId,
    this.startTime,
    this.endTime,
    this.openPreventCheatFlag = 0,
    this.openCheckFaceFlag = 0,
    this.openCheckWeChatFlag = 0,
    this.openSignOutFlag = 0,
    this.ifNeedVCode = 0,
    this.showVCode = 0,
    this.numberCount = 0,
    this.signCode = '',
    this.locationText = '',
    this.locationRange = '',
    this.ifopenAddress = 0,
    this.lateMinute = 0,
    this.createPageTimeLong = -1,
    this.activityTranMode = 0,
  });

  /// Parses the `{result, msg, data:{…}}` envelope. Returns null when the
  /// server refused (`result != 1`) or sent no `data`.
  static ChaoxingActiveInfo? parse(Map<String, dynamic> body) {
    if (body['result'] != 1) return null;
    final data = body['data'];
    if (data is! Map) return null;
    final d = data.cast<String, dynamic>();
    int num_(String k, [int fallback = 0]) {
      final v = d[k];
      if (v is num) return v.toInt();
      return int.tryParse('$v') ?? fallback;
    }

    return ChaoxingActiveInfo(
      activeId: '${d['id'] ?? ''}',
      kind: ChaoxingSignKind.resolve(
        otherId: num_('otherId', -1),
        ifNeedVCode: num_('ifNeedVCode'),
        ifphoto: num_('ifphoto'),
        openCheckFaceFlag: num_('openCheckFaceFlag'),
        ifrefreshewm: num_('ifrefreshewm'),
        ifopenAddress: num_('ifopenAddress'),
      ),
      status: num_('status'),
      raw: d,
      parentId: d['parentid'] == null ? null : num_('parentid'),
      startTime: d['starttime'] == null ? null : num_('starttime'),
      endTime: d['endtime'] == null ? null : num_('endtime'),
      openPreventCheatFlag: num_('openPreventCheatFlag'),
      openCheckFaceFlag: num_('openCheckFaceFlag'),
      openCheckWeChatFlag: num_('openCheckWeChatFlag'),
      openSignOutFlag: num_('openSignOutFlag'),
      ifNeedVCode: num_('ifNeedVCode'),
      showVCode: num_('showVCode'),
      numberCount: num_('numberCount'),
      signCode: '${d['signCode'] ?? ''}',
      locationText: '${d['locationText'] ?? ''}',
      locationRange: '${d['locationRange'] ?? ''}',
      ifopenAddress: num_('ifopenAddress'),
      lateMinute: num_('lateMinute'),
      createPageTimeLong: num_('createPageTimeLong', -1),
      activityTranMode: num_('activityTranMode'),
    );
  }

  /// The activity id this info describes.
  final String activeId;

  /// The decoded sign flavour.
  final ChaoxingSignKind kind;

  /// `status` — 1 while the activity is live.
  final int status;

  /// The untouched `data` object, for fields this model does not name.
  final Map<String, dynamic> raw;

  /// `parentid` — the class-level activity this instance belongs to.
  final int? parentId;

  /// `starttime`, millis since epoch.
  final int? startTime;

  /// `endtime`, millis since epoch; null when open-ended.
  final int? endTime;

  /// 1 when the teacher enabled 防作弊; pairs with [ifNeedVCode].
  final int openPreventCheatFlag;

  /// 1 when face liveness is required — not satisfiable headlessly.
  final int openCheckFaceFlag;

  /// 1 when a WeChat binding check is required.
  final int openCheckWeChatFlag;

  /// 1 when the teacher also published a sign-*out*.
  final int openSignOutFlag;

  /// 1 when a captcha token must accompany the submit.
  final int ifNeedVCode;

  /// 1 when the page should render the captcha widget.
  final int showVCode;

  /// Digit count of the 签到码, for [ChaoxingSignKind.signCode].
  final int numberCount;

  /// Always empty in practice — the server does not disclose the code.
  final String signCode;

  /// The teacher's target place name, e.g. `中国湖北省武汉市武昌区珞珈山街道桂园路`.
  final String locationText;

  /// Allowed radius in metres, as a string (`"500"`); empty when unset.
  final String locationRange;

  /// 1 when the page collects a reverse-geocoded `address`.
  final int ifopenAddress;

  /// Minutes after which the sign counts as late.
  final int lateMinute;

  /// How long the creating page took, or -1.
  final int createPageTimeLong;

  /// `activityTranMode`.
  final int activityTranMode;

  /// True when the teacher turned on any anti-cheat measure.
  bool get hasAntiCheat =>
      openPreventCheatFlag == 1 || ifNeedVCode == 1 || showVCode == 1;

  /// The allowed radius in metres, or null when the activity is not
  /// location-bound.
  int? get locationRangeMetres => int.tryParse(locationRange);
}

/// The verdict of `widget/sign/pcStuSignController/checkSignCode`.
///
/// The 签到码 page validates the code *before* submitting, and a wrong code is
/// not free: `result == -1` means the server has banned further attempts for
/// brute force. Callers should therefore check once and stop on failure rather
/// than iterate over candidates.
class ChaoxingSignCodeCheck {
  /// Creates a code-check verdict.
  const ChaoxingSignCodeCheck({
    required this.result,
    this.message = '',
    this.errorMsg,
  });

  /// Parses the `{result, msg, data, errorMsg}` body.
  static ChaoxingSignCodeCheck parse(Map<String, dynamic> body) =>
      ChaoxingSignCodeCheck(
        result: int.tryParse('${body['result']}') ?? 0,
        message: '${body['msg'] ?? ''}',
        errorMsg: body['errorMsg'] == null ? null : '${body['errorMsg']}',
      );

  /// 1 = accepted, -1 = brute-force ban, anything else = wrong code.
  final int result;

  /// `msg`, e.g. `验证成功`.
  final String message;

  /// `errorMsg` when the server supplied one.
  final String? errorMsg;

  /// True when the code was accepted and the sign may proceed.
  bool get isAccepted => result == 1;

  /// True when the server has banned further code attempts for this activity.
  bool get isBanned => result == -1;
}

/// The already-signed record rendered by a `newsign/preSign` page.
///
/// The preSign HTML is server-rendered and **is** the source of truth for the
/// signed state — the official WebView shows nothing else. An activity the
/// student has not signed renders a submit form (`#signButton` + `stuSignajax`)
/// with no status block; once signed (or otherwise terminal) it renders
/// `#statuscontent` with the verdict text, a `.signtime`, and — per flavour —
/// the submitted photo (`zsign_photo`) or the location (`#latitude`/`#longitude`
/// plus `#address` and a Baidu map container).
///
/// [parse] reads exactly those markers, so a headless client can show the same
/// "已签到 + 时间 + 照片/位置" the WebView does without rendering any HTML.
class ChaoxingSignRecord {
  /// Creates a sign record.
  const ChaoxingSignRecord({
    required this.signed,
    this.statusText = '',
    this.signTime = '',
    this.photoObjectId = '',
    this.photoUrl = '',
    this.latitude,
    this.longitude,
    this.address = '',
  });

  /// Parses a `newsign/preSign` page. [signed] is false when the page is still
  /// the submit form (no `#statuscontent`), in which case the media fields stay
  /// empty and the caller should offer the submit UI instead.
  static ChaoxingSignRecord parse(String html) {
    final signed = html.contains('id="statuscontent"');
    if (!signed) return const ChaoxingSignRecord(signed: false);

    String text(RegExp re) {
      final m = re.firstMatch(html);
      if (m == null) return '';
      return _stripTags(m.group(1) ?? '').trim();
    }

    final statusText = text(RegExp(r'id="statuscontent"\s*>([\s\S]*?)</h1>'));
    final signTime = text(RegExp(r'class="signtime"\s*>([\s\S]*?)</p>'));
    final address = text(RegExp(r'<h2 id="address"\s*>([\s\S]*?)</h2>'));

    final photo = RegExp(
      r'zsign_photo[\s\S]*?objId="([^"]+)"[\s\S]*?src="([^"]+)"',
    ).firstMatch(html);

    return ChaoxingSignRecord(
      signed: true,
      statusText: statusText,
      signTime: signTime,
      photoObjectId: photo?.group(1) ?? '',
      photoUrl: photo?.group(2) ?? '',
      latitude: _coord(text(RegExp(r'id="latitude"\s+value="([^"]*)"'))),
      longitude: _coord(text(RegExp(r'id="longitude"\s+value="([^"]*)"'))),
      address: address,
    );
  }

  /// Coordinates are Baidu **BD-09** (the H5 pages plot them on `BMap`). The
  /// `-1`/empty sentinel the unsigned pages carry is coerced to null so callers
  /// can treat "no usable fix" uniformly.
  static double? _coord(String raw) {
    final v = double.tryParse(raw.trim());
    if (v == null || v == -1 || v == 0) return null;
    return v;
  }

  static String _stripTags(String s) =>
      s.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ');

  /// True when the page rendered a terminal status block rather than the submit
  /// form. This is the "already signed" gate the native UI keys on.
  final bool signed;

  /// The server's verdict text, e.g. `签到成功`. Shown verbatim.
  final String statusText;

  /// The recorded sign time as the page prints it, e.g. `05-13 18:21`.
  final String signTime;

  /// The submitted photo's pan objectId, empty when this was not a photo sign.
  final String photoObjectId;

  /// The submitted photo's thumbnail URL (`p.cldisk.com/star3/312_412c/…`),
  /// served with a Chaoxing `Referer` and no cookies.
  final String photoUrl;

  /// BD-09 latitude of the recorded location sign, null when not location-bound.
  final double? latitude;

  /// BD-09 longitude of the recorded location sign, null when not location-bound.
  final double? longitude;

  /// The reverse-geocoded address the page shows under a location sign.
  final String address;

  /// True when a usable location fix is present (both coordinates resolved).
  bool get hasLocation => latitude != null && longitude != null;

  /// True when a photo was submitted with the sign.
  bool get hasPhoto => photoUrl.trim().isNotEmpty;
}

/// Typed failures so callers can distinguish "log in again" from "the server
/// said no" without string matching.
sealed class ChaoxingSignFailure implements Exception {
  /// Base constructor for the typed sign failures.
  const ChaoxingSignFailure();
}

/// The session cookies were rejected (login page / redirect). Re-login needed.
class ChaoxingSessionExpired extends ChaoxingSignFailure {
  /// Creates a session-expired failure with a diagnostic [message].
  const ChaoxingSessionExpired(this.message);

  /// Diagnostic describing why the session was rejected.
  final String message;

  @override
  String toString() => message;
}

/// The server (or local validation) refused the call.
class ChaoxingSignRejected extends ChaoxingSignFailure {
  /// Creates a rejected-call failure with a diagnostic [message].
  const ChaoxingSignRejected(this.message);

  /// Diagnostic describing the refusal.
  final String message;

  @override
  String toString() => message;
}

/// Transport-level failure.
class ChaoxingSignNetworkFailure extends ChaoxingSignFailure {
  /// Creates a network failure with a diagnostic [message].
  const ChaoxingSignNetworkFailure(this.message);

  /// Diagnostic describing the transport failure.
  final String message;

  @override
  String toString() => message;
}

/// A `cxsign`-bearing call was attempted without a [ChaoxingDeviceIdentity].
///
/// Kept distinct from [ChaoxingSignRejected] because the fix is provisioning,
/// not retrying: see the class doc on [ChaoxingDeviceIdentity].
class ChaoxingDeviceIdentityMissing extends ChaoxingSignFailure {
  /// Creates a missing-device-identity failure with a diagnostic [message].
  const ChaoxingDeviceIdentityMissing(this.message);

  /// Diagnostic describing the missing provisioning.
  final String message;

  @override
  String toString() => message;
}
