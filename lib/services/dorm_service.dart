import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'campus/campus_session.dart';
import 'campus/cas_client.dart';
import 'campus/webvpn.dart';
import 'net_mode.dart';
import 'storage_service.dart';
part 'dorm_models.dart';

/// 宿舍电费（2026-10-23）。
///
/// 数据来自校内「慧新E校」平台（`10.3.100.110`，**仅校园网可达**）：
///   CAS 登录换平台 token → 逐层查校区/楼栋 → 按房号查余额。
///
/// 约定：
/// - token 只存内存，不落盘、不打日志；
/// - 失败一律返回 null，由界面决定文案，不弹错误；
/// - 宿舍（楼栋 + 房号）存本机，非敏感信息。
class DormService {
  DormService._();

  static const String base = 'http://10.3.100.110';

  /// 内网会话。校外（[CampusNetMode.webvpn]）时把 URL 改写挂到会话层——
  /// 这样「起始请求 + 每一跳 302」都会被包装，平台换票链才不会断在中间。
  static CampusSession _newSession() => CampusSession(
        urlRewrite:
            NetMode.current == CampusNetMode.webvpn ? WebVpn.wrapUrl : null,
      );

  /// 回归测试用的数据接缝；生产环境始终为 null，不改真实网络与登录流程。
  static Future<CardTurnoverPage?> Function({int page, int size, String type})?
      debugTurnoverFetcher;

  /// 回归测试用：跳过内网可达性探测。
  static Future<void> Function()? debugEnsureNetworkFresh;

  /// 平台注册给 CAS 的 service（从统一认证跳转地址抄下来，必须一字不差）。
  static const String casService =
      'http://10.3.100.110/berserker-auth/cas/login/lyCas'
      '?targetUrl=http%3A%2F%2F10.3.100.110%2Fplat%2F%3Fname%3DloginTransit';

  /// 来源参数：**必须是 app**。实测 `h5` / `pc` 都会被服务端以 4030
  /// 「服务大厅未授权」拒掉（2026-10-26 用真实账号验证）。
  /// 且要**双份携带**：GET 走 query，再另加同名头（官方前端拦截器行为）。
  static const String _synSource = 'app';

  static const String _basic =
      'Basic bW9iaWxlX3NlcnZpY2VfcGxhdGZvcm06bW9iaWxlX3NlcnZpY2VfcGxhdGZvcm1fc2VjcmV0';
  static const String _chargeBasic = 'Basic Y2hhcmdlOmNoYXJnZV9zZWNyZXQ=';

  static String? _token;
  static String? _tokenSno;

  /// 持久会话：CAS 登录态 + **WebVPN 网关 cookie** 都在这里。
  ///
  /// 🔴 校外必须复用同一个会话对象 —— 网关认 `wengine_vpn_ticket…` cookie，
  /// 每次新建空会话都会被当成未登录、直接回登录页 HTML。
  /// （2026-10-26「查询失败」的真因：ensureLogin 用完就把会话关掉了，
  ///   后面每个接口又各自 new 一个空会话，直连靠 token 头能过、走网关全挂。）
  static CampusSession? _session;

  /// 该会话创建时的网络模式。模式切换（直连 ↔ 网关）必须重建 ——
  /// 否则会话里挂的 urlRewrite 还是旧的，请求会发错地方。
  static CampusNetMode? _sessionMode;

  /// CAS 票据（TGT）。有效期远长于 ST，留着可反复换 ST ——
  /// 充值跳转、卡包换票就不必每次重新登录（省 3~5 秒，也少碰风控）。
  static String? _tgt;
  static String? _tgtSno;

  /// 已登录会话（[ensureLogin] 成功后非空）。
  static CampusSession? get activeSession => _session;

  /// 内网可达性（2 秒超时）。不在校园网时用它快速短路，避免弹窗卡住。
  static Future<bool> isAvailable() async {
    final s = _newSession();
    try {
      final r = await s
          .get('$base/berserker-app/frontInfo?synAccessSource=mobile')
          .timeout(const Duration(seconds: 2));
      return r.body.contains('"code":200');
    } catch (_) {
      return false;
    } finally {
      s.close();
    }
  }

  /// 用本机账密换 token（同一学号复用内存结果）。
  /// 最近一次登录失败的具体阶段（空 = 没失败）。
  static String lastLoginError = '';

  /// 登录进行中的 Future：并发调用共享同一次登录。
  ///
  /// 没有它的话，两个页面同时触发登录会各建一个会话，后完成的那个
  /// `_session?.close()` 会把前一个**正在被使用**的会话关掉（请求直接断）。
  static Future<String?>? _loginInflight;

  /// 登录并返回**本次调用**的失败原因（null = 成功）。
  ///
  /// 为什么不读共享的 [lastLoginError]：多个页面会先后/并发调用，后一次开头
  /// 就把前一次的错误清空了，界面于是读到空文案（2026-10-26「一卡通报登录失败
  /// 却没有任何原因」就是这么来的）。
  /// 测试用：直接注入账密（生产不设置）。供 live 联通测试跑完整业务方法。
  @visibleForTesting
  static String? debugSno;
  @visibleForTesting
  static String? debugPwd;

  /// 测试用：读当前 access_token（只在诊断脚本里用）。
  @visibleForTesting
  static String? get debugToken => _token;

  /// 串行化所有 CAS / WebVPN / 平台票据操作。
  ///
  /// 之前余额刷新和充值预热会各自登录一次，后者换票时可能让前者的 TGT
  /// 失效；表现就是「更新数据时点充值，偶尔打不开充值页」。
  static Future<void> _authGate = Future<void>.value();

  static Future<T> _authLocked<T>(Future<T> Function() action) async {
    final previous = _authGate;
    final gate = Completer<void>();
    _authGate = gate.future;
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
    }
  }

  static Future<String?> loginOrError() =>
      _authLocked(_loginSingleFlight);

  static Future<String?> _loginSingleFlight() {
    final running = _loginInflight;
    if (running != null) return running;
    // 整体超时兜底：CAS + 网关 + 换票最多走十几跳，单跳 25 秒叠起来能拖到几分钟，
    // 界面就一直是「更新中」。40 秒拿不到结果就直接判失败（2026-10-26）。
    final fut = _loginRun().timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        _loginInflight = null;
        lastLoginError = '登录失败(超时)';
        return lastLoginError;
      },
    );
    _loginInflight = fut;
    return fut;
  }

  static Future<String?> _loginRun() async {
    lastLoginError = '';
    // 测试注入时完全绕过本机存储（flutter_secure_storage 在测试环境无平台通道）
    String sno;
    String pwd;
    if (debugSno != null) {
      sno = debugSno!.trim();
      pwd = debugPwd ?? '';
    } else {
      final cfg = await StorageService.loadUserConfig();
      sno = cfg.username.trim();
      pwd = cfg.password;
    }
    if (sno.isEmpty || pwd.isEmpty) {
      lastLoginError = '登录失败(缺账密)';
      return lastLoginError;
    }
    if (_token != null &&
        _tokenSno == sno &&
        _session != null &&
        _sessionMode == NetMode.current) {
      return null;
    }

    CampusSession? s;
    try {
      s = _newSession();
      final login = await CasClient.login(s, sno, pwd, service: casService);
      if (!login.ok || login.tgt == null) {
        lastLoginError = switch (login.status) {
          CasClient.badCredential => '登录失败(密码)',
          CasClient.captchaFailed => '登录失败(验证码)',
          CasClient.throttled => '登录过于频繁，请稍后再试',
          _ => '登录失败(账号)',
        };
        return lastLoginError;
      }

      // 🔴 校外必须先登录 WebVPN 网关，再走平台换票。
      //
      // 位置很关键：平台的登录链（lyCas → 302 /plat/?ticket=…）**全在内网**，
      // 没有网关登录态就到不了、平台票也就拿不到。而 CAS 换 ST 时传的 service
      // 必须保持**原始内网地址**（CAS 会校验与平台注册值一致），包装交给
      // CampusSession.urlRewrite 逐跳完成 —— 所以这里只补网关登录这一步。
      if (NetMode.current == CampusNetMode.webvpn) {
        final vpnErr = await WebVpn.login(s, login.tgt!);
        if (vpnErr != null) {
          lastLoginError = '登录失败($vpnErr)';
          return lastLoginError;
        }
      }

      final stResp = await s.postForm(
        '${CasClient.casBase}/lyuapServer/v1/tickets/${login.tgt}',
        {'service': casService},
        headers: {'Referer': '${CasClient.casBase}/'},
      );
      final st = stResp.body.trim();
      if (!st.startsWith('ST-')) {
        lastLoginError = '登录失败(票据)';
        return lastLoginError;
      }

      // 🔴 关键：CAS 的 ST 不能直接换 token。
      // 必须先访问 lyCas?ticket=ST，平台会 302 到 /plat/?ticket=<平台自己的票>，
      // 拿这张「转换后的票」去 oauth 才能换到 access_token（已实测）。
      // 🔴 平台票只出现在**中间那一跳**的 URL 上，必须逐跳捕获。
      //
      // 直连时 `/plat/?ticket=` 直接 200，最终 URL 里还有票，所以「只看最终 URL」
      // 碰巧能用；走 WebVPN 时网关会多跳一次、最终落点是门户首页，票就丢了 ——
      // 于是退回用 ST 换 token，拿到的是低权限 token，一卡通报
      // 「4030 服务大厅未授权1」（2026-10-26 实测）。
      var platformTicket = '';
      try {
        platformTicket = await locatePlatformTicket(
          s,
          "$casService&ticket=${Uri.encodeComponent(st)}",
        );
      } catch (_) {
        // 拿不到就退回用 ST 试一次
      }
      final ticketForToken =
          platformTicket.isEmpty ? st : platformTicket;

      final tokenResp = await s.postForm(
        '$base/berserker-auth/oauth/token',
        {
          'username': ticketForToken,
          'password': ticketForToken,
          'grant_type': 'password',
          'scope': 'all',
          'loginFrom': 'app',
          'logintype': 'sso',
          'device_token': 'h5',
        },
        headers: {'Authorization': _basic},
      );
      final j = CampusSession.tryJson(tokenResp.body);
      final token = j?['access_token']?.toString();
      if (token == null || token.isEmpty) {
        lastLoginError = '登录失败(换取)';
        return lastLoginError;
      }

      _token = token;
      _tokenSno = sno;
      _tgt = login.tgt;
      _tgtSno = sno;
      // 保留会话：WebVPN 的登录 cookie 就存在这里，后续所有内网请求必须复用它
      _session?.close();
      _session = s;
      _sessionMode = NetMode.current;
      s = null; // 已由 _session 持有，别让 finally 关掉
      return null;
    } catch (e) {
      debugPrint('电费登录失败: $e');
      if (lastLoginError.isEmpty) lastLoginError = '登录失败(网络)';
      return lastLoginError;
    } finally {
      s?.close();
      _loginInflight = null;
    }
  }

  static void clearToken() {
    _token = null;
    _tokenSno = null;
    _tgt = null;
    _tgtSno = null;
    _session?.close();
    _session = null;
    _sessionMode = null;
  }

  /// 预置楼栋：即使不在校园网，弹窗也能选。
  /// （完整列表在首次联网成功后缓存到本机，之后离线也能用。）
  static const List<DormBuilding> _seed = [
    DormBuilding(feeitemid: 448, value: 'A5&李园壹號A5', name: '李一', available: true),
    DormBuilding(feeitemid: 448, value: 'A7&李园贰號A7', name: '李二', available: true),
    DormBuilding(feeitemid: 448, value: 'A6&李园叄号A6', name: '李三', available: true),
    DormBuilding(feeitemid: 448, value: 'A8&李园肆号A8', name: '李四', available: true),
    DormBuilding(feeitemid: 448, value: 'A9&李园伍号A9', name: '李五', available: true),
    DormBuilding(feeitemid: 448, value: 'A10&李园陆号A10', name: '李六', available: true),
    DormBuilding(feeitemid: 448, value: 'A11&李园柒号A11', name: '李七', available: true),
    DormBuilding(feeitemid: 448, value: 'A12&李园捌号A12', name: '李八', available: true),
    DormBuilding(feeitemid: 449, value: '12460&李九', name: '李九', campus: '1&无锡学院', available: true),
    DormBuilding(feeitemid: 449, value: '13276&李十', name: '李十', campus: '1&无锡学院', available: true),
    DormBuilding(feeitemid: 449, value: '12868&李十一', name: '李十一', campus: '1&无锡学院', available: true),
    DormBuilding(feeitemid: 448, value: 'A1&桃园壹號A1', name: '桃一', available: true),
    DormBuilding(feeitemid: 448, value: 'A2&桃园贰號A2', name: '桃二', available: true),
    DormBuilding(feeitemid: 448, value: 'A3&桃园叁號A3', name: '桃三', available: true),
    DormBuilding(feeitemid: 448, value: 'A4&桃园肆號A4', name: '桃四', available: true),
    DormBuilding(feeitemid: 450, value: '2309046091500776&1号楼', name: '梅一', campus: '2309045673200002&无锡学院'),
    DormBuilding(feeitemid: 450, value: '2407124814801010&2号楼', name: '梅二', campus: '2309045673200002&无锡学院'),
    DormBuilding(feeitemid: 450, value: '2407124814300001&3号楼', name: '梅三', campus: '2309045673200002&无锡学院'),
    DormBuilding(feeitemid: 448, value: 'A9L&青教公寓A9L', name: '青教公寓', available: true),
  ];

  /// 楼栋列表：直接返回预置（不缓存、不联网、不随平台变化）。
  static Future<List<DormBuilding>> buildings() async => _seed;

  static Future<ElectricityInfo?> query(DormInfo dorm) async {
    final loginErr = await loginOrError();
    if (loginErr != null) {
      lastLoginError = loginErr; // 绑定本次，避免被并发调用清空
      return null;
    }
    final map = await _post(dorm.feeitemid, 'IEC', 3, {
      'campus': dorm.campus,
      'building': dorm.buildingValue,
      'room': dorm.room,
    });
    if (map == null) return null;

    final show = (map['showData'] as Map?)?.cast<String, dynamic>() ?? const {};
    final text = (show['信息'] ?? '').toString();
    final data = (map['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final balance = parseMoney(text);
    var kwh = parseKwh(text);
    if (kwh == null && balance != null) {
      // 449/450 不下发电量 → 按单价换算（文案自带单价优先，否则用学校电价）
      final price = parseUnitPrice(text) ?? defaultUnitPrice;
      if (price > 0) kwh = balance / price;
    }
    return ElectricityInfo(
      text: text,
      balance: balance,
      kwh: kwh,
      buildingName: (data['buildingName'] ?? dorm.buildingName).toString(),
      room: (data['room'] ?? dorm.room).toString(),
    );
  }

  /// 一卡通余额（内网平台）。
  ///
  /// 返回失败原因，便于界面区分：
  ///   `登录失败`  CAS 换 token 没成功
  ///   `无卡账号`  平台用户信息里找不到卡账号
  ///   `查询失败`  接口返回异常 / 没有卡
  static Future<CardQueryResult> fetchCardBalanceDetailed() async {
    final loginErr = await loginOrError();
    if (loginErr != null) return CardQueryResult(reason: loginErr);
    final s = _session;
    if (s == null) return const CardQueryResult(reason: '查询失败');
    try {
      final headers = {
        'synjones-auth': 'bearer $_token',
        'synAccessSource': _synSource,
      };

      // ① 用户信息里找卡账号（字段名各版本不同，递归找 key 含 account/card 的）
      final ur = await s.get(
        '$base/berserker-base/user?synAccessSource=$_synSource',
        headers: headers,
      );
      final uj = CampusSession.tryJson(ur.body);
      if (uj == null) {
        // 不是 JSON → 多半被网关/登录页拦了，**不能报「无卡账号」**
        // （那两个字的误导性极强，2026-10-26 排查时就是被它带偏的）
        if (ur.body.trimLeft().startsWith('<')) clearToken();
        return const CardQueryResult(reason: '查询失败');
      }
      final account = _findAccount(uj);
      if (account == null) {
        // 区分「平台报错」和「确实没有卡号」：前者多半是 token 不对
        // （VPN 下换了会话/票据），后者才是真没卡。混在一起会误导排查。
        final code = uj['code']?.toString();
        if (code != null && code != '200') {
          final msg = (uj['msg'] ?? uj['message'] ?? uj['message'] ?? '')
              .toString();
          return CardQueryResult(
              reason: '查询失败($code${msg.isEmpty ? '' : ' $msg'})');
        }
        return const CardQueryResult(reason: '无卡账号');
      }

      // ② 查卡
      final r = await s.get(
        '$base/berserker-app/ykt/tsm/queryCard'
        '?account=$account&synAccessSource=$_synSource',
        headers: headers,
      );
      final j = CampusSession.tryJson(r.body);
      if (j == null || j['code']?.toString() != '200') {
        return const CardQueryResult(reason: '查询失败');
      }
      final d = (j['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final cards = (d['card'] as List<dynamic>?) ?? const [];
      if (cards.isEmpty) return const CardQueryResult(reason: '查询失败');
      final first = (cards.first as Map).cast<String, dynamic>();
      final acc = (first['accinfo'] as List<dynamic>?) ?? const [];
      for (final a in acc) {
        if (a is Map && a['balance'] is num) {
          return CardQueryResult(
              balance: (a['balance'] as num).toDouble() / 100);
        }
      }
      final elec = first['elec_accamt'];
      if (elec is num) {
        return CardQueryResult(balance: elec.toDouble() / 100);
      }
      return const CardQueryResult(reason: '查询失败');
    } catch (_) {
      return const CardQueryResult(reason: '查询失败');
    } finally {
      // 持久会话**不能关**：WebVPN cookie 在里面，一关下一次请求就是空会话
    }
  }

  /// 从 302 的 Location 里取 `ticket` 参数（平台票是二次编码的，解一次）。
  /// 逐跳跟随 302 链，找出**平台票**（非 `ST-` 前缀的 `?ticket=`）。
  ///
  /// 为什么不能只看最终 URL：平台票只出现在中间那一跳（`/plat/?ticket=…`）。
  /// 直连时那一跳直接 200 所以碰巧能取到；走 WebVPN 时网关会多跳一次，
  /// 最终落点已是门户首页，票就丢了 —— 退回用 ST 换 token 会得到低权限 token，
  /// 一卡通报「4030 服务大厅未授权1」（2026-10-26 实测）。
  ///
  /// 抽成公开静态方法是为了能用本地桩服务器测（不依赖真实账号）。
  static Future<String> locatePlatformTicket(
    CampusSession s,
    String startUrl, {
    int maxHops = 6,
  }) async {
    var hopUrl = startUrl;
    for (var i = 0; i < maxHops; i++) {
      final res = await s.get(hopUrl, followRedirects: false);
      var tk = _ticketParam(hopUrl);
      if (tk.isEmpty) tk = _ticketParam(res.url);
      if (tk.isNotEmpty && !tk.startsWith('ST-')) return tk;

      final loc = res.location;
      if (loc == null || loc.isEmpty) break;
      hopUrl = CampusSession.nextHop(hopUrl, loc);

      final tk2 = _ticketParam(hopUrl);
      if (tk2.isNotEmpty && !tk2.startsWith('ST-')) return tk2;
    }
    return '';
  }

  static String _ticketParam(String location) {
    if (location.isEmpty) return '';
    final uri = Uri.tryParse(location);
    final raw = uri?.queryParameters['ticket'] ?? '';
    if (raw.isEmpty) return '';
    return Uri.decodeComponent(raw);
  }

  /// 找「卡账号」：优先 cardAccount（实测 4630），再 cardId / cardNo，
  /// 最后才退回 account（那是学号，不能用于查卡）。
  static String? _findAccount(dynamic node) {
    final found = <String, String>{};
    void walk(dynamic n) {
      if (n is Map) {
        n.forEach((k, v) {
          final key = k.toString().toLowerCase();
          if (v is String || v is num) {
            found[key] = v.toString();
          } else {
            walk(v);
          }
        });
      } else if (n is List) {
        for (final v in n) {
          walk(v);
        }
      }
    }

    walk(node);
    // 🔴 2026-11-04 审查 P2：候选表里原来有 `'account'`，与上面注释
    //    「account 是学号，不能用于查卡」直接矛盾。判据 `^\d{3,10}$` 对
    //    8-12 位学号完全成立，一旦接口没返回 cardAccount/cardId/cardNo，
    //    就会拿学号去查卡：轻则平台返回空 card（用户看到"查询失败"而实际
    //    是"无卡账号"），重则平台按学号返回另一张卡（教师卡/临时卡）的
    //    余额。这条链路最终通向充值入口，不能留兜底。
    for (final k in const [
      'cardaccount',
      'cardid',
      'yktaccount',
      'cardno',
    ]) {
      final v = found[k] ?? '';
      if (v.isNotEmpty && RegExp(r'^\d{3,10}$').hasMatch(v)) return v;
    }
    return null;
  }

  // ---------------- 持久化缓存（进页面先显示，再覆盖） ----------------

  static const String _kCardCache = 'card_balance_cache_v2';
  static const String _kElecCache = 'elec_balance_cache_v1';

  static Future<double?> loadCardCache() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getDouble(_kCardCache);
    return v;
  }

  static Future<void> saveCardCache(double v) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kCardCache, v);
    // 同步到旧缓存键，桌面小组件读的是这份。
    await StorageService.saveCardBalanceCache(v);
  }

  /// 缓存按「楼栋 + 房号」区分：换宿舍后旧数据自动失效。
  static String elecCacheKey(DormInfo d) =>
      '${d.buildingValue}|${d.room}';

  static Future<ElectricityInfo?> loadElecCache(DormInfo dorm) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kElecCache);
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      // 兼容旧格式（没有 key）：楼栋名 + 房号对得上就认
      if (m['key'] != null && m['key'] != elecCacheKey(dorm)) return null;
      if (m['key'] == null) {
        final sameBuilding = (m['building'] ?? '') == dorm.buildingName;
        final sameRoom = (m['room'] ?? '') == dorm.room;
        if (!sameBuilding || !sameRoom) return null;
      }
      return ElectricityInfo(
        text: (m['text'] ?? '').toString(),
        balance: (m['balance'] as num?)?.toDouble(),
        kwh: (m['kwh'] as num?)?.toDouble(),
        buildingName: (m['building'] ?? '').toString(),
        room: (m['room'] ?? '').toString(),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveElecCache(
      ElectricityInfo i, DormInfo dorm) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kElecCache,
      jsonEncode({
        'key': elecCacheKey(dorm),
        'text': i.text,
        'balance': i.balance,
        'kwh': i.kwh,
        'building': i.buildingName,
        'room': i.room,
      }),
    );
  }


  // ---------------- 消费流水（2026-10-24 实测） ----------------

  /// 一卡通消费流水。返回 null = 失败。
  ///
  /// `type`: 空=全部 / 1=收入 / 2=支出。
  static Future<CardTurnoverPage?> fetchTurnover({
    int page = 1,
    int size = 20,
    String type = '',
  }) async {
    final debugFetcher = debugTurnoverFetcher;
    if (debugFetcher != null) {
      return debugFetcher(page: page, size: size, type: type);
    }
    var result = await _fetchTurnoverOnce(page: page, size: size, type: type);
    // 平台 token 过期时请求会清 token 并返回 null；自动重登一次，
    // 避免详情页偶发「进入后一片空白，要手动更新」。
    if (result == null && _token == null) {
      result = await _fetchTurnoverOnce(page: page, size: size, type: type);
    }
    return result;
  }

  static Future<CardTurnoverPage?> _fetchTurnoverOnce({
    int page = 1,
    int size = 20,
    String type = '',
  }) async {
    if (await loginOrError() != null) return null;
    final s = _session;
    if (s == null) return null;
    try {
      // 🔴 分页参数名是 `current`，不是 `pageNum`（2026-11-06 实测）。
      //    传 pageNum / pageNo / currentPage 服务端一律忽略、恒回第 1 页
      //    （响应里 current 也恒为 1），于是「查看更多」每点一次就把同样的
      //    前 10 条再追加一遍 —— 用户看到的就是「交易明细重复前十条」。
      //    传 current=2 才真的换页（current=2、首条时间前移）。
      final r = await s.get(
        '$base/berserker-search/search/personal/turnover'
        '?type=$type&current=$page&pageSize=$size'
        '&synAccessSource=$_synSource',
        headers: {
          'synjones-auth': 'bearer $_token',
          'synAccessSource': _synSource,
        },
      );
      final j = CampusSession.tryJson(r.body);
      if (j == null) {
        // 回来不是 JSON = 多半被网关弹回登录页。清掉登录态，下次调用会静默重登；
        // 否则 token 还在、永远走同一个死会话（表现为一直「查询失败」）。
        if (r.body.trimLeft().startsWith('<')) clearToken();
        return null;
      }
      if (j['code']?.toString() != '200') return null;
      final d = (j['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final records = (d['records'] as List<dynamic>?) ?? const [];
      final list = <CardTxn>[];
      for (final item in records) {
        if (item is! Map) continue;
        final m = item.cast<String, dynamic>();
        final fen = int.tryParse('${m['tranamt'] ?? ''}') ?? 0;
        final bal = int.tryParse('${m['cardBalance'] ?? ''}');
        final income = '${m['typeFrom'] ?? ''}' == '1';
        list.add(CardTxn(
          time: '${m['jndatetimeStr'] ?? ''}',
          title: '${m['payName'] ?? m['resume'] ?? ''}',
          place: '${m['locationName'] ?? ''}',
          amountYuan: fen / 100,
          isIncome: income,
          balanceYuan: bal == null ? null : bal / 100,
        ));
      }
      return CardTurnoverPage(
        items: list,
        total: int.tryParse('${d['total'] ?? 0}') ?? 0,
        current: int.tryParse('${d['current'] ?? page}') ?? page,
        pages: int.tryParse('${d['pages'] ?? 1}') ?? 1,
      );
    } catch (_) {
      return null;
    } finally {
      // 持久会话**不能关**：WebVPN cookie 在里面，一关下一次请求就是空会话
    }
  }

  /// 电费充值页（官方 H5）：URL 自带 token，打开即登录。
  /// 用已有 TGT 换一张 ST（指定 service）。失败即认为 TGT 失效并清空。
  static Future<String?> _stFor(CampusSession s, String service) async {
    final tgt = _tgt;
    if (tgt == null) return null;
    try {
      final r = await s.postForm(
        '${CasClient.casBase}/lyuapServer/v1/tickets/$tgt',
        {'service': service},
        headers: {'Referer': '${CasClient.casBase}/'},
      );
      final st = r.body.trim();
      if (st.startsWith('ST-')) return st;
    } catch (_) {
      // 落到下面清 TGT
    }
    _tgt = null;
    _tgtSno = null;
    return null;
  }

  /// 确保有 TGT（优先复用；没有才真的登录一次）。返回 null = 登录失败。
  static Future<String?> _ensureTgt(
      CampusSession s, String sno, String pwd) async {
    final cached = _tgt;
    if (cached != null && _tgtSno == sno) return cached;
    final login = await CasClient.login(s, sno, pwd, service: casService);
    if (!login.ok || login.tgt == null) return null;
    _tgt = login.tgt;
    _tgtSno = sno;
    return login.tgt;
  }

  /// 网关域的 cookie（供内置 WebView 注入，免去在页面里再登录一次）。
  ///
  /// 🔴 只挑网关自己的 cookie：平台侧 cookie（会话/票据）不往外给，
  /// WebView 只该拿到"已登录网关"这一个事实。
  static Map<String, String> get vpnCookies {
    final all = _session?.cookies ?? const <String, String>{};
    return {
      for (final e in all.entries)
        if (e.key.startsWith('wengine_vpn_ticket') ||
            e.key.startsWith('show_') ||
            e.key == 'heartbeat')
          e.key: e.value,
    };
  }

  /// 一卡通充值页的**直链**（靠平台会话，不靠 targetUrl）。
  ///
  /// `loginTransit` 只负责「用 ticket 建立会话」，它到底把浏览器送到哪不可靠
  /// （实测返回 200 的 HTML，targetUrl 不保证生效）。所以 WebView 里分两步：
  /// 先 open [cardBagLoginUrl] 建会话，再 load 本方法返回的地址。
  static String? cardBagRechargeUrl() {
    if (NetMode.current == CampusNetMode.offline) return null;
    return WebVpn.wrapUrl(
      '$base/campus-card/cardRecharge'
      '?appId=27&loginFrom=h5&synAccessSource=h5',
    );
  }

  /// 电费充值页（官方 H5，URL 自带 token，打开即登录）。
  ///
  /// 校外不拦，只把地址**包装成网关地址**：浏览器打开后若未登录 WebVPN 会跳一次
  /// 登录页，登录后 cookie 由浏览器保留、后续直接进；校园网内 wrapUrl 原样返回。
  static Future<String?> rechargeUrlFor(int feeitemid) async {
    // 离线（既不在校园网、网关也不通）时不要给地址：浏览器只会打开一个死链
    if (NetMode.current == CampusNetMode.offline) return null;
    if (await loginOrError() != null) return null;
    final pay = Uri.encodeComponent('$base/plat');
    return WebVpn.wrapUrl(
      '$base/charge-app?name=pays&id=$feeitemid&paymentUrl=$pay&token=$_token',
    );
  }

  /// 卡包（充值入口）：需在页面内登录，交给浏览器/WebView 处理。
  static String get cardBagUrl => '$base/campus-card/cardRecharge'
      '?appId=27&loginFrom=h5&synAccessSource=h5';


  /// 取一张**新鲜的平台票**（一次性，用于把已登录状态带进浏览器）。
  ///
  /// 流程：CAS 登录 → ST → lyCas 302 里拿平台票。
  static Future<String?> freshPlatformTicket() async {
    var ticket = await _authLocked(_freshPlatformTicketRun);
    // TGT 可能刚过期：第二次会重新走 CAS，避免充值偶发「票据失败」。
    ticket ??= await _authLocked(_freshPlatformTicketRun);
    return ticket;
  }

  static Future<String?> _freshPlatformTicketRun() async {
    // 与 loginOrError 同口径：测试注入优先，否则读本机存储
    String sno;
    String pwd;
    if (debugSno != null) {
      sno = debugSno!.trim();
      pwd = debugPwd ?? '';
    } else {
      final cfg = await StorageService.loadUserConfig();
      sno = cfg.username.trim();
      pwd = cfg.password;
    }
    if (sno.isEmpty || pwd.isEmpty) return null;

    CampusSession? s;
    try {
      s = _newSession();
      final tgt = await _ensureTgt(s, sno, pwd);
      if (tgt == null) return null;

      // 校外必须先登录网关：后面的换票链（lyCas → /plat/）全在内网。
      if (NetMode.current == CampusNetMode.webvpn) {
        if (await WebVpn.login(s, tgt) != null) {
          // 网关登录失败多半是 TGT 过期，清掉让下次重登
          _tgt = null;
          _tgtSno = null;
          return null;
        }
      }

      final st = await _stFor(s, casService);
      if (st == null) return null;
      // 逐跳找票（票只在中间那一跳，最终落点会丢）
      return locatePlatformTicket(
        s,
        "$casService&ticket=${Uri.encodeComponent(st)}",
      );
    } catch (_) {
      return null;
    } finally {
      s?.close();
    }
  }

  /// 卡包登录跳转：先落登录态（loginTransit），再进卡包页。
  /// 卡包（充值入口）。同样在校外包装成网关地址交给浏览器。
  static Future<String?> cardBagLoginUrl() async {
    if (NetMode.current == CampusNetMode.offline) return null;
    final ticket = await freshPlatformTicket();
    if (ticket == null || ticket.isEmpty) return null;
    // 目标是**充值页**而不是卡包首页（2026-10-26 用户指正）：
    // 卡包首页只有概览，充值要进 cardRecharge。
    final target = Uri.encodeComponent(
      '$base/campus-card/cardRecharge'
      '?appId=27&loginFrom=h5&synAccessSource=h5',
    );
    return WebVpn.wrapUrl(
      '$base/plat/?name=loginTransit'
      '&ticket=${Uri.encodeComponent(ticket)}&targetUrl=$target',
    );
  }


  // ---------------- 消费流水缓存 ----------------

  static const String _kTxnCache = 'card_txn_cache_v1';

  static Future<CardTurnoverPage?> loadTurnoverCache() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kTxnCache);
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final list = (m['items'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => CardTxn(
                time: '${e['t'] ?? ''}',
                title: '${e['n'] ?? ''}',
                place: '${e['p'] ?? ''}',
                amountYuan: (e['a'] as num?)?.toDouble() ?? 0,
                isIncome: e['i'] == true,
                balanceYuan: (e['b'] as num?)?.toDouble(),
              ))
          .toList();
      if (list.isEmpty) return null;
      return CardTurnoverPage(
        items: list,
        total: (m['total'] as num?)?.toInt() ?? list.length,
        current: (m['current'] as num?)?.toInt() ?? 1,
        pages: (m['pages'] as num?)?.toInt() ?? 1,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveTurnoverCache(CardTurnoverPage page) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kTxnCache,
      jsonEncode({
        'items': [
          for (final t in page.items)
            {
              't': t.time,
              'n': t.title,
              'p': t.place,
              'a': t.amountYuan,
              'i': t.isIncome,
              'b': t.balanceYuan,
            }
        ],
        'total': page.total,
        'current': page.current,
        'pages': page.pages,
      }),
    );
  }



  /// 电费/一卡通快捷充值（原生建单，四步）。
  ///
  /// 返回：`ok` / `needPassword` / 其他错误文案。
  /// - `tranamt` 单位是**元**（服务端口径，不乘 100）
  /// - 建单前补齐 `third_party`（电费房间上下文）
  /// - 免密判据只有 `nopassword == 1`；否则删单并回落官方充值
  static Future<String> quickRecharge({
    required int feeitemid,
    required double yuan,
    DormInfo? dorm,
  }) async {
    final loginErr = await loginOrError();
    if (loginErr != null) return loginErr;
    final s = _session;
    if (s == null) return '登录失败';
    try {
      final h = {
        'Authorization': _chargeBasic,
        'synjones-auth': 'bearer $_token',
        'synAccessSource': _synSource,
      };

      // 电费：带上房间上下文（末级 IEC 的 map.data）
      String? thirdParty;
      if (dorm != null) {
        final raw = await _roomData(s, dorm, h);
        if (raw != null && raw.isNotEmpty) {
          thirdParty = jsonEncode(raw);
        }
      }

      // ① 建单（tranamt 单位：元）
      final orderBody = <String, String>{
        'feeitemid': '$feeitemid',
        'tranamt': yuan.toStringAsFixed(2),
        'flag': 'choose',
        'source': 'app',
        'paystep': '0',
      };
      if (thirdParty != null) orderBody['third_party'] = thirdParty;

      final r1 = await s.postForm('$base/blade-pay/pay', orderBody, headers: h);
      final j1 = CampusSession.tryJson(r1.body);
      final d1 = (j1?['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final orderid = (d1['orderid'] ?? '').toString();
      if (orderid.isEmpty) {
        return (j1?['msg'] ?? '建单失败').toString();
      }
      if ((d1['orderflag'] ?? '').toString() == 'results') return 'ok';

      // ② 支付方式
      final r2 = await s.get(
        '$base/charge/pay/getpayinfo?orderid=$orderid',
        headers: h,
      );
      final j2 = CampusSession.tryJson(r2.body);
      final payList = (j2?['payList'] as List<dynamic>?) ?? const [];
      if (payList.isEmpty) {
        await _dropOrder(s, orderid, h);
        return 'needPassword';
      }
      final p0 = (payList.first as Map).cast<String, dynamic>();
      final noPwd = p0['nopassword'] == 1 || p0['nopassword'] == true;
      final paytype = '${p0['code'] ?? ''}';
      final paytypeid = '${p0['payid'] ?? ''}';

      // ③ 查账户：必须**不带** ccctype，否则会被当成提交
      final r3 = await s.postForm(
        '$base/blade-pay/pay',
        {
          'orderid': orderid,
          'paystep': '2',
          'paytype': paytype,
          'paytypeid': paytypeid,
        },
        headers: h,
      );
      final j3 = CampusSession.tryJson(r3.body);
      final d3 = (j3?['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final accountno = (d3['accountno'] ?? '').toString();
      final ccctype = (d3['ccctype'] ?? '').toString();

      if (!noPwd) {
        await _dropOrder(s, orderid, h);
        return 'needPassword';
      }

      // ④ 提交（带 accountno + ccctype）
      final r4 = await s.postForm(
        '$base/blade-pay/pay',
        {
          'orderid': orderid,
          'paystep': '2',
          'paytype': paytype,
          'paytypeid': paytypeid,
          'accountno': accountno,
          'ccctype': ccctype,
          'isWX': '0',
        },
        headers: h,
      );
      final j4 = CampusSession.tryJson(r4.body);
      if (j4?['code']?.toString() != '200') {
        return (j4?['msg'] ?? '提交失败').toString();
      }

      // ⑤ 轮询结果（最多 5 次）
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        final r5 = await s.get(
          '$base/charge/pay/getpayinfo?orderid=$orderid',
          headers: h,
        );
        final j5 = CampusSession.tryJson(r5.body);
        final order = (j5?['order'] as Map?)?.cast<String, dynamic>() ?? const {};
        if ('${order['status'] ?? ''}' == '1') return 'ok';
      }
      return '订单处理中，请稍后在消费记录确认';
    } catch (_) {
      return '网络异常';
    } finally {
      // 持久会话**不能关**：WebVPN cookie 在里面，一关下一次请求就是空会话
    }
  }

  /// 取某宿舍末级 IEC 的 `map.data`（电费建单的 third_party）。
  static Future<Map<String, dynamic>?> _roomData(
    CampusSession s,
    DormInfo dorm,
    Map<String, String> headers,
  ) async {
    try {
      final r = await s.postForm(
        '$base/charge/feeitem/getThirdData',
        {
          'feeitemid': '${dorm.feeitemid}',
          'type': 'IEC',
          'level': '3',
          'campus': dorm.campus,
          'building': dorm.buildingValue,
          'room': dorm.room,
        },
        headers: headers,
      );
      final j = CampusSession.tryJson(r.body);
      return (j?['map']?['data'] as Map?)?.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// 取消未支付订单（必须 JSON body，否则服务端 500）。
  static Future<void> _dropOrder(
    CampusSession s,
    String orderid,
    Map<String, String> headers,
  ) async {
    try {
      await s.postJson(
        '$base/charge/order/deleteOrder',
        {'orderid': orderid},
        headers: headers,
      );
    } catch (_) {
      // 清理失败不影响主流程
    }
  }


  // ---------------- 电费趋势快照 ----------------

  static const String _kElecPoints = 'elec_points_v1';

  /// 记录一次电费余额（按宿舍隔离，各保留最近 60 条）。
  ///
  /// [kwh] 一并存下来，详情页切到「度」时才能按度显示与算差值。
  static Future<void> saveElecPoint(double balance,
      {double? kwh, DormInfo? dorm}) async {
    final key = dorm == null ? '' : elecCacheKey(dorm);
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kElecPoints);
    final list = <Map<String, dynamic>>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        list.addAll(
            (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>());
      } catch (_) {}
    }
    final now = DateTime.now();
    // 同一宿舍 30 分钟内重复查询只更新最后一条，避免刷出一堆点
    for (var i = list.length - 1; i >= 0; i--) {
      if ((list[i]['k'] as String?) == key) {
        final t =
            DateTime.fromMillisecondsSinceEpoch((list[i]['t'] as num).toInt());
        if (now.difference(t) < const Duration(minutes: 30)) {
          list.removeAt(i);
        }
        break;
      }
    }
    list.add({
      't': now.millisecondsSinceEpoch,
      'b': balance,
      if (kwh != null) 'e': kwh,
      'k': key,
    });
    if (list.length > 60) list.removeRange(0, list.length - 60);
    await p.setString(_kElecPoints, jsonEncode(list));
  }

  static Future<List<({DateTime time, double balance, double? kwh})>>
      loadElecPoints({DormInfo? dorm}) async {
    final key = dorm == null ? '' : elecCacheKey(dorm);
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kElecPoints);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .whereType<Map>()
          .where((e) => (e['k'] as String?) == key)
          .map((e) => (
                time: DateTime.fromMillisecondsSinceEpoch(
                    (e['t'] as num).toInt()),
                balance: (e['b'] as num).toDouble(),
                kwh: (e['e'] as num?)?.toDouble(),
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 解析平台文案里的**金额**。
  ///
  /// 三个片区的文案格式**各不相同**（平台自己就没统一，2026-10-26 实测）：
  ///   448 `当前余额517.05元,当前剩余电量957.50度`
  ///   449 `房间当前剩余电费625.35`（无「元」字、无电量）
  ///   450 `房间号：211,剩余金额：29.79，单价：0.5400`
  /// 且余额可能为**负**（`当前余额-12.19元`，欠费）。
  ///
  /// 口径：关键词 + 可选分隔符 + 数字（允许负号），**不做位置解构**——
  /// 不能"取文本里第一个数字"，平台改文案时会错报成房间号或单价。
  @visibleForTesting
  static double? parseMoney(String text) {
    if (text.isEmpty) return null;
    for (final k in const ['剩余金额', '剩余电费', '余额']) {
      final m = RegExp('$k' r'\s*[:：=＝为是]?\s*(-?\d+(?:\.\d+)?)')
          .firstMatch(text);
      if (m != null) return double.tryParse(m.group(1)!);
    }
    return null;
  }

  /// 学校居民电价（元/度）。450 的文案自带单价（实测 0.5400），
  /// 449 不提供 —— 用它换算；两片区实测一致。
  static const double defaultUnitPrice = 0.54;

  /// 解析文案里的单价（450 形如 `单价：0.5400`）。
  @visibleForTesting
  static double? parseUnitPrice(String text) {
    if (text.isEmpty) return null;
    final m = RegExp(r'单价\s*[:：=＝]?\s*(-?\d+(?:\.\d+)?)').firstMatch(text);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  /// 解析剩余电量（只有 448 片区下发，其余返回 null）。
  @visibleForTesting
  static double? parseKwh(String text) {
    if (text.isEmpty) return null;
    final m = RegExp(r'剩余电量\s*[:：=＝为是]?\s*(-?\d+(?:\.\d+)?)')
        .firstMatch(text);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  static Future<Map<String, dynamic>?> _post(
    int feeitemid,
    String type,
    int level,
    Map<String, String> extra,
  ) async {
    final s = _session;
    if (s == null) return null;
    try {
      final r = await s.postForm(
        '$base/charge/feeitem/getThirdData',
        {
          'feeitemid': '$feeitemid',
          'type': type,
          'level': '$level',
          ...extra,
        },
        headers: {
          'Authorization': _chargeBasic,
          'synjones-auth': 'bearer $_token',
        },
      );
      final j = CampusSession.tryJson(r.body);
      if (j == null || j['code']?.toString() != '200') return null;
      return (j['map'] as Map?)?.cast<String, dynamic>();
    } catch (_) {
      return null;
    } finally {
      // 持久会话**不能关**：WebVPN cookie 在里面，一关下一次请求就是空会话
    }
  }
}
