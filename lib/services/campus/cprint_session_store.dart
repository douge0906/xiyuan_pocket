import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 云打印会话缓存（L3）—— 存**整份 cookie 罐**。
///
/// ## 为什么是「整份罐」而不是只存 `OSESSIONID`
///
/// 最初的实现只存 `OSESSIONID`，理由写在当时的注释里：那是站点侧会话的凭据。
/// 2026-11-25 实机 + 抓包证明这个假定**只在校内直连时成立**：
///
/// ```
/// 校内直连  SSoPage  → Set-Cookie: SESSIONID=;…  OSESSIONID=xxx; path=/
/// 校外网关  SSoPage  → Set-Cookie: refresh=1; Path=/          ← 站点的 cookie 被网关吞了
/// ```
///
/// 校外走 WebVPN 时，站点的 `Set-Cookie` 根本到不了客户端，罐里只有网关自己的
/// `wengine_vpn_ticket…`。于是 `s.cookies['OSESSIONID']` 永远是空串，授权链其实
/// **已经成功**（同一个罐接着调 `Auth/Check` 返回 `code:0`），却被
/// 「站点没有下发会话」这条判断拦下来 —— 用户看到的就是那句
/// 「授权走完了，但站点没有下发会话，请稍后重试。」（m12060 实机截图）。
///
/// 结论：**会话成立与否只能靠 `Auth/Check` 判定，不能靠某个具体 cookie 名。**
/// 缓存的目标也随之改成「把这罐原样保存，下次原样灌回去，再验一次」。
///
/// ## 为什么连网关票也一起存
///
/// 实测：把整份罐（含 `wengine_vpn_ticket…`）抄进全新会话，
/// `Auth/Check` 仍 `code:0`、`PrintJob/Get` 仍 `n=2`；
/// 只抄 `wengine_vpn_ticket` 一项也一样能通。所以**整罐就是凭据**。
///
/// 安全上它等价于一枚会话票据，和原来的 `OSESSIONID` 同级，
/// 一样只进 `flutter_secure_storage`，退出登录 / 换账号 / 清数据一律删（见
/// `CprintClient.clear` 与 `DataWipe.wipeAll`）。
///
/// ## 为什么还要记着「当时是哪种网络」
///
/// 校内罐里是 `OSESSIONID`，校外罐里是网关票 —— 两者不通用。换网络后拿旧罐去试，
/// 必然先吃一次 `code:4` 才回落到完整 SSO。带上模式就能直接跳过这次无效往返。
class CprintSessionStore {
  CprintSessionStore._();

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static const String _kCookies = 'cprint_cookies';
  static const String _kSavedAt = 'cprint_cookies_at';
  static const String _kOwner = 'cprint_cookies_owner';
  static const String _kMode = 'cprint_cookies_mode';

  /// 缓存有效期。
  ///
  /// 取 40 分钟：站点没有公开的会话时长，这是实测「放 40 分钟内还能拿到
  /// 列表」的保守下界。设太短 → 每次进页面都重跑 6 跳 SSO；设太长 → 拿着
  /// 已失效的罐去请求，多绕一次 `code:4` 才转重登，反而更慢。
  ///
  /// 注意：**过期不代表一定失效**，反过来也一样（服务端可能提前踢掉）。
  /// 所以它只是「省一次 SSO」的优化，正确性仍靠 `Auth/Check` 那条兜底路径。
  static const Duration ttl = Duration(minutes: 40);

  static Map<String, String>? _value;
  static String? _owner;
  static String? _mode;
  static DateTime? _savedAt;

  /// 内存里的当前罐（诊断用）。
  static Map<String, String>? get debugValue => _value;

  /// 读缓存：**归属人必须等于当前学号、网络模式必须一致、且未过期**，
  /// 否则视为未命中。返回的是要灌回会话的 cookie 表。
  static Future<Map<String, String>?> load(
    String username, {
    required String mode,
  }) async {
    final sno = username.trim();
    if (sno.isEmpty) return null;

    if (_value != null && _owner == sno && _mode == mode) {
      final at = _savedAt;
      if (at != null && DateTime.now().difference(at) < ttl) return _value;
      // 内存里有但过期了 → 顺手清掉，别留着让下次又走一遍判断
      await clear();
    }

    try {
      final owner = await _secure.read(key: _kOwner);
      if (owner == null || owner.isEmpty || owner != sno) {
        // 换账号了：必须清，否则把上一个人的云打印会话给下一个人用
        if (owner != null && owner.isNotEmpty) await clear();
        return null;
      }
      final savedMode = await _secure.read(key: _kMode);
      if (savedMode != mode) {
        // 换了网络（校内 ↔ 校外），旧罐里的凭据不通用了。
        // 不删数据，只是这次不用 —— 用户切回去还能省一次 SSO。
        return null;
      }
      final rawCookies = await _secure.read(key: _kCookies);
      final rawAt = await _secure.read(key: _kSavedAt);
      if (rawCookies == null || rawCookies.isEmpty || rawAt == null) {
        return null;
      }
      final savedAt = DateTime.tryParse(rawAt);
      if (savedAt == null || DateTime.now().difference(savedAt) >= ttl) {
        await clear();
        return null;
      }

      final decoded = jsonDecode(rawCookies);
      if (decoded is! Map) {
        await clear();
        return null;
      }
      final jar = <String, String>{};
      decoded.forEach((k, v) {
        final key = k.toString().trim();
        final val = v?.toString().trim() ?? '';
        if (key.isNotEmpty && val.isNotEmpty) jar[key] = val;
      });
      if (jar.isEmpty) {
        await clear();
        return null;
      }

      _value = jar;
      _owner = owner;
      _mode = savedMode;
      _savedAt = savedAt;
      return jar;
    } catch (_) {
      return null;
    }
  }

  /// 落盘整份罐。空罐不存（存了也没用，下次照样要重登）。
  static Future<void> save(
    String username, {
    required String mode,
    required Map<String, String> cookies,
  }) async {
    final sno = username.trim();
    if (sno.isEmpty || cookies.isEmpty) return;
    final jar = <String, String>{
      for (final entry in cookies.entries)
        if (entry.key.trim().isNotEmpty && entry.value.trim().isNotEmpty)
          entry.key.trim(): entry.value.trim(),
    };
    if (jar.isEmpty) return;

    _value = jar;
    _owner = sno;
    _mode = mode;
    _savedAt = DateTime.now();
    try {
      await _secure.write(key: _kCookies, value: jsonEncode(jar));
      await _secure.write(key: _kSavedAt, value: _savedAt!.toIso8601String());
      await _secure.write(key: _kOwner, value: sno);
      await _secure.write(key: _kMode, value: mode);
    } catch (_) {}
  }

  static DateTime? get savedAt => _savedAt;

  /// 只存在于 2026-11-25 之前那版里的旧键（那时只存 OSESSIONID）。
  ///
  /// 升级上来的设备会留着它们：既没人读，又多存了一份会话票据。
  /// 每次清理顺手删掉，不留历史包袱。
  static const List<String> _legacyKeys = <String>[
    'cprint_osession',
    'cprint_osession_at',
    'cprint_osession_owner',
  ];

  /// 清空（退出登录 / 换账号 / 会话失效时）。
  static Future<void> clear() async {
    _value = null;
    _owner = null;
    _mode = null;
    _savedAt = null;
    try {
      await _secure.delete(key: _kCookies);
      await _secure.delete(key: _kSavedAt);
      await _secure.delete(key: _kOwner);
      await _secure.delete(key: _kMode);
      for (final k in _legacyKeys) {
        await _secure.delete(key: k);
      }
    } catch (_) {}
  }
}
