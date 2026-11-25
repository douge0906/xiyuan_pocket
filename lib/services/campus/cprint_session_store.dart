import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 云打印会话缓存（L3）—— `OSESSIONID` 落盘。
///
/// ## 为什么要单独存
///
/// 从 CAS 换到 `OSESSIONID` 要走 6 跳（SSoPage → authcenter → doAuth →
/// SSOLogin → UniEntry → 落地页），其中 authcenter 那一步是 **30 秒内一次性**
/// 的。如果每次打开列表页都重跑整条链：
///   · 慢（6 次网络往返 + 2 次 302 跟随）；
///   · 会不断在 authcenter 造新的临时会话，站点那边的日志会变脏；
///   · 校外走 WebVPN 时每一跳都要过网关，延迟翻倍。
///
/// 而站点自己给 `OSESSIONID` 的寿命远长于这个页面 —— 实测 `Auth/Check` 在
/// 几十分钟后仍返回 `code:0`。所以缓存它，命中就免掉整条 SSO 链。
///
/// ## 为什么不缓存 `SESSIONID`
///
/// 站点会同时下发两个 cookie，但只有 `OSESSIONID` 是**站点侧会话**的凭据；
/// `SESSIONID` 只是 SSO 过程中间那个临时 ID，落地后就没用了。
/// 只存 `OSESSIONID`，别的一概不落盘。
class CprintSessionStore {
  CprintSessionStore._();

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static const String _kSession = 'cprint_osession';
  static const String _kSessionAt = 'cprint_osession_at';
  static const String _kSessionOwner = 'cprint_osession_owner';

  /// 缓存有效期。
  ///
  /// 取 40 分钟：站点没有公开的会话时长，这是实测「放 40 分钟内还能拿到
  /// 列表」的保守下界。设太短 → 每次进页面都重跑 6 跳 SSO；设太长 → 拿着
  /// 已失效的 cookie 去请求，多绕一次 `code:4` 才转重登，反而更慢。
  ///
  /// 注意：**过期不代表一定失效**，反过来也一样（服务端可能提前踢掉）。
  /// 所以它只是"省一次 SSO"的优化，正确性仍靠 `code:4` 那条兜底路径。
  static const Duration ttl = Duration(minutes: 40);

  static String? _value;
  static String? _owner;
  static DateTime? _savedAt;

  /// 内存里的当前值（诊断用）。
  static String? get debugValue => _value;

  /// 读缓存：**归属人必须等于当前学号且未过期**，否则视为未命中。
  static Future<String?> load(String username) async {
    final sno = username.trim();
    if (sno.isEmpty) return null;
    if (_value != null && _owner == sno) {
      final at = _savedAt;
      if (at != null && DateTime.now().difference(at) < ttl) return _value;
      // 内存里有但过期了 → 顺手清掉，别留着让下次又走一遍判断
      await clear();
    }
    try {
      final owner = await _secure.read(key: _kSessionOwner);
      if (owner == null || owner.isEmpty || owner != sno) {
        // 换账号了：必须清，否则把上一个人的云打印会话给下一个人用
        if (owner != null && owner.isNotEmpty) await clear();
        return null;
      }
      final raw = await _secure.read(key: _kSession);
      final at = await _secure.read(key: _kSessionAt);
      if (raw == null || raw.isEmpty || at == null) return null;
      final savedAt = DateTime.tryParse(at);
      if (savedAt == null || DateTime.now().difference(savedAt) >= ttl) {
        await clear();
        return null;
      }
      _value = raw;
      _owner = owner;
      _savedAt = savedAt;
      return raw;
    } catch (_) {
      return null;
    }
  }

  /// 落盘 `OSESSIONID`。
  static Future<void> save(String username, String osessionId) async {
    final sno = username.trim();
    final value = osessionId.trim();
    if (sno.isEmpty || value.isEmpty) return;
    _value = value;
    _owner = sno;
    _savedAt = DateTime.now();
    try {
      await _secure.write(key: _kSession, value: value);
      await _secure.write(key: _kSessionAt, value: _savedAt!.toIso8601String());
      await _secure.write(key: _kSessionOwner, value: sno);
    } catch (_) {}
  }

  static DateTime? get savedAt => _savedAt;

  /// 清空（退出登录 / 换账号 / 会话失效时）。
  static Future<void> clear() async {
    _value = null;
    _owner = null;
    _savedAt = null;
    try {
      await _secure.delete(key: _kSession);
      await _secure.delete(key: _kSessionAt);
      await _secure.delete(key: _kSessionOwner);
    } catch (_) {}
  }
}
