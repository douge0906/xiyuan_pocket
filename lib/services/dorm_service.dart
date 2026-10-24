import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'campus/campus_session.dart';
import 'campus/cas_client.dart';
import 'storage_service.dart';

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

  /// 平台注册给 CAS 的 service（从统一认证跳转地址抄下来，必须一字不差）。
  static const String casService =
      'http://10.3.100.110/berserker-auth/cas/login/lyCas'
      '?targetUrl=http%3A%2F%2F10.3.100.110%2Fplat%2F%3Fname%3DloginTransit';

  static const String _basic =
      'Basic bW9iaWxlX3NlcnZpY2VfcGxhdGZvcm06bW9iaWxlX3NlcnZpY2VfcGxhdGZvcm1fc2VjcmV0';
  static const String _chargeBasic = 'Basic Y2hhcmdlOmNoYXJnZV9zZWNyZXQ=';

  static String? _token;
  static String? _tokenSno;

  /// 内网可达性（2 秒超时）。不在校园网时用它快速短路，避免弹窗卡住。
  static Future<bool> isAvailable() async {
    final s = CampusSession();
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

  static Future<bool> ensureLogin() async {
    lastLoginError = '';
    final cfg = await StorageService.loadUserConfig();
    final sno = cfg.username.trim();
    final pwd = cfg.password;
    if (sno.isEmpty || pwd.isEmpty) {
      lastLoginError = '登录失败(缺账密)';
      return false;
    }
    if (_token != null && _tokenSno == sno) return true;

    CampusSession? s;
    try {
      s = CampusSession();
      final login = await CasClient.login(s, sno, pwd, service: casService);
      if (!login.ok || login.tgt == null) {
        lastLoginError = switch (login.status) {
          CasClient.badCredential => '登录失败(密码)',
          CasClient.captchaFailed => '登录失败(验证码)',
          _ => '登录失败(账号)',
        };
        return false;
      }

      final stResp = await s.postForm(
        '${CasClient.casBase}/lyuapServer/v1/tickets/${login.tgt}',
        {'service': casService},
        headers: {'Referer': '${CasClient.casBase}/'},
      );
      final st = stResp.body.trim();
      if (!st.startsWith('ST-')) {
        lastLoginError = '登录失败(票据)';
        return false;
      }

      // 🔴 关键：CAS 的 ST 不能直接换 token。
      // 必须先访问 lyCas?ticket=ST，平台会 302 到 /plat/?ticket=<平台自己的票>，
      // 拿这张「转换后的票」去 oauth 才能换到 access_token（已实测）。
      var platformTicket = '';
      try {
        final res = await s.get(
          "$casService&ticket=${Uri.encodeComponent(st)}",
          headers: {'Referer': '${CasClient.casBase}/'},
        );
        // CampusResponse.url = 跟随重定向后的最终地址，里面带着平台票
        platformTicket = _ticketParam(res.url);
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
        return false;
      }

      _token = token;
      _tokenSno = sno;
      return true;
    } catch (e) {
      debugPrint('电费登录失败: $e');
      if (lastLoginError.isEmpty) lastLoginError = '登录失败(网络)';
      return false;
    } finally {
      s?.close();
    }
  }

  static void clearToken() {
    _token = null;
    _tokenSno = null;
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
    DormBuilding(feeitemid: 449, value: '12460&李九', name: '李九', available: true),
    DormBuilding(feeitemid: 449, value: '13276&李十', name: '李十', available: true),
    DormBuilding(feeitemid: 449, value: '12868&李十一', name: '李十一', available: true),
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
    if (!await ensureLogin()) return null;
    final map = await _post(dorm.feeitemid, 'IEC', 3, {
      'campus': dorm.campus,
      'building': dorm.buildingValue,
      'room': dorm.room,
    });
    if (map == null) return null;

    final show = (map['showData'] as Map?)?.cast<String, dynamic>() ?? const {};
    final text = (show['信息'] ?? '').toString();
    final data = (map['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ElectricityInfo(
      text: text,
      balance: _num(text, r'余额\s*([\d.]+)\s*元'),
      kwh: _num(text, r'剩余电量\s*([\d.]+)\s*度'),
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
    if (!await ensureLogin()) {
      return CardQueryResult(
          reason: lastLoginError.isEmpty ? '登录失败' : lastLoginError);
    }
    final s = CampusSession();
    try {
      final headers = {
        'synjones-auth': 'bearer $_token',
        'synAccessSource': 'h5',
      };

      // ① 用户信息里找卡账号（字段名各版本不同，递归找 key 含 account/card 的）
      final ur = await s.get('$base/berserker-base/user', headers: headers);
      final uj = CampusSession.tryJson(ur.body);
      final account = _findAccount(uj);
      if (account == null) {
        return const CardQueryResult(reason: '无卡账号');
      }

      // ② 查卡
      final r = await s.get(
        '$base/berserker-app/ykt/tsm/queryCard'
        '?account=$account&synAccessSource=h5',
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
      s.close();
    }
  }

  /// 从 302 的 Location 里取 `ticket` 参数（平台票是二次编码的，解一次）。
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
    for (final k in const [
      'cardaccount',
      'cardid',
      'yktaccount',
      'cardno',
      'account',
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
    if (!await ensureLogin()) return null;
    final s = CampusSession();
    try {
      final r = await s.get(
        '$base/berserker-search/search/personal/turnover'
        '?type=$type&pageNum=$page&pageSize=$size',
        headers: {
          'synjones-auth': 'bearer $_token',
          'synAccessSource': 'h5',
        },
      );
      final j = CampusSession.tryJson(r.body);
      if (j == null || j['code']?.toString() != '200') return null;
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
      s.close();
    }
  }

  /// 电费充值页（官方 H5）：URL 自带 token，打开即登录。
  static Future<String?> rechargeUrlFor(int feeitemid) async {
    if (!await ensureLogin()) return null;
    final pay = Uri.encodeComponent('$base/plat');
    return '$base/charge-app?name=pays&id=$feeitemid&paymentUrl=$pay&token=$_token';
  }

  /// 卡包（充值入口）：需在页面内登录，交给浏览器/WebView 处理。
  static String get cardBagUrl => '$base/campus-card/?name=campusCard';


  /// 取一张**新鲜的平台票**（一次性，用于把已登录状态带进浏览器）。
  ///
  /// 流程：CAS 登录 → ST → lyCas 302 里拿平台票。
  static Future<String?> freshPlatformTicket() async {
    final cfg = await StorageService.loadUserConfig();
    final sno = cfg.username.trim();
    final pwd = cfg.password;
    if (sno.isEmpty || pwd.isEmpty) return null;

    CampusSession? s;
    try {
      s = CampusSession();
      final login = await CasClient.login(s, sno, pwd, service: casService);
      if (!login.ok || login.tgt == null) return null;
      final stResp = await s.postForm(
        '${CasClient.casBase}/lyuapServer/v1/tickets/${login.tgt}',
        {'service': casService},
        headers: {'Referer': '${CasClient.casBase}/'},
      );
      final st = stResp.body.trim();
      if (!st.startsWith('ST-')) return null;
      final res = await s.get(
        "$casService&ticket=${Uri.encodeComponent(st)}",
        headers: {'Referer': '${CasClient.casBase}/'},
      );
      return _ticketParam(res.url);
    } catch (_) {
      return null;
    } finally {
      s?.close();
    }
  }

  /// 卡包登录跳转：先落登录态（loginTransit），再进卡包页。
  static Future<String?> cardBagLoginUrl() async {
    final ticket = await freshPlatformTicket();
    if (ticket == null || ticket.isEmpty) return null;
    final target =
        Uri.encodeComponent('$base/campus-card/?name=campusCard');
    return '$base/plat/?name=loginTransit'
        '&ticket=${Uri.encodeComponent(ticket)}&targetUrl=$target';
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
        current: 1,
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
    if (!await ensureLogin()) return '登录失败';
    final s = CampusSession();
    try {
      final h = {
        'Authorization': _chargeBasic,
        'synjones-auth': 'bearer $_token',
        'synAccessSource': 'h5',
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
      s.close();
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

  static double? _num(String text, String pattern) {
    final m = RegExp(pattern).firstMatch(text);
    if (m == null) return null;
    return double.tryParse(m.group(1) ?? '');
  }

  static Future<Map<String, dynamic>?> _post(
    int feeitemid,
    String type,
    int level,
    Map<String, String> extra,
  ) async {
    final s = CampusSession();
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
      s.close();
    }
  }
}

class DormBuilding {
  const DormBuilding({
    required this.feeitemid,
    required this.value,
    required this.name,
    this.campus = '1',
    this.available = true,
  });

  final int feeitemid;

  /// 形如 `A7&李园贰號A7`，服务端要求的原样格式。
  final String value;

  /// 界面显示的短名（李二 / 桃一 / 梅三）。
  final String name;

  /// 该楼栋所属校区的「value」（不同片区编码不同：梅园是一长串数字）。
  final String campus;

  /// 平台是否已开通该楼栋。
  final bool available;
}

class DormInfo {
  const DormInfo({
    required this.feeitemid,
    required this.buildingValue,
    required this.buildingName,
    required this.room,
    this.campus = '1',
  });

  final int feeitemid;
  final String buildingValue;
  final String buildingName;
  final String room;
  final String campus;

  String get display => '$buildingName $room';

  Map<String, dynamic> toMap() => {
        'feeitemid': feeitemid,
        'value': buildingValue,
        'name': buildingName,
        'room': room,
        'campus': campus,
      };

  static DormInfo? fromMap(Map<String, dynamic> m) {
    final fee = m['feeitemid'];
    final value = (m['value'] ?? '').toString();
    final name = (m['name'] ?? '').toString();
    final room = (m['room'] ?? '').toString();
    if (fee is! int || value.isEmpty || name.isEmpty || room.isEmpty) {
      return null;
    }
    return DormInfo(
      feeitemid: fee,
      buildingValue: value,
      buildingName: name,
      room: room,
      campus: (m['campus'] ?? '1').toString(),
    );
  }
}

class ElectricityInfo {
  const ElectricityInfo({
    required this.text,
    required this.balance,
    required this.kwh,
    required this.buildingName,
    required this.room,
  });

  /// 平台原句：`当前余额468.89元,当前剩余电量868.32度`
  final String text;
  final double? balance;
  final double? kwh;
  final String buildingName;
  final String room;
}

/// 宿舍信息本机存储（用户页与电费卡片共用）。
class DormStore {
  static const String _kFee = 'dorm_feeitemid_v1';
  static const String _kValue = 'dorm_building_value_v1';
  static const String _kName = 'dorm_building_name_v1';
  static const String _kRoom = 'dorm_room_v1';
  static const String _kCampus = 'dorm_campus_v1';

  static Future<DormInfo?> load() async {
    final p = await SharedPreferences.getInstance();
    final fee = p.getInt(_kFee);
    final value = p.getString(_kValue);
    final name = p.getString(_kName);
    final room = p.getString(_kRoom);
    if (fee == null || value == null || name == null || room == null) {
      return null;
    }
    return DormInfo.fromMap({
      'feeitemid': fee,
      'value': value,
      'name': name,
      'room': room,
      'campus': p.getString(_kCampus) ?? '1',
    });
  }

  static Future<void> save(DormInfo d) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kFee, d.feeitemid);
    await p.setString(_kValue, d.buildingValue);
    await p.setString(_kName, d.buildingName);
    await p.setString(_kRoom, d.room);
    await p.setString(_kCampus, d.campus);
  }
}

class CardQueryResult {
  const CardQueryResult({this.balance, this.reason});

  final double? balance;
  final String? reason;
}

class CardTxn {
  const CardTxn({
    required this.time,
    required this.title,
    required this.place,
    required this.amountYuan,
    required this.isIncome,
    required this.balanceYuan,
  });

  final String time;
  final String title;
  final String place;
  final double amountYuan;
  final bool isIncome;
  final double? balanceYuan;
}

class CardTurnoverPage {
  const CardTurnoverPage({
    required this.items,
    required this.total,
    required this.current,
    required this.pages,
  });

  final List<CardTxn> items;
  final int total;
  final int current;
  final int pages;
}
