import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'campus_session.dart';
import 'cas_client.dart';

/// 统一认证会话中心（L1）—— 跨工具共享的 TGT 缓存。
///
/// ## 为什么需要它
///
/// 以前每个功能各登各的：教务一套 cookie、电费一套 `_tgt`、云打印又要一套。
/// 同一个学号在几秒内连开三次 CAS 登录会撞上 `CasClient` 的 8 秒节流，
/// 表现就是「首登时总有一两个功能说登录失败」。
///
/// 这里把**最值钱的那张票**（TGT）集中管起来：谁要建子系统会话，就拿同一张
/// TGT 去换对应 service 的 ST。CAS 一次登录可以换无数张 ST，这是它设计的用法，
/// 不是漏洞。
///
/// ## 与 `ssoTo` 的分工（这条别搞混）
///
/// - [CasClient.ssoTo] = 换 ST **并且访问** service，把 cookie 种进会话 ——
///   适合「教务/JWGL 那种落地页就是目标系统」的场景。
/// - [CasSessionCenter.stFor] = **只换票不消费** —— 适合「拿到 ST 之后还要
///   自己拼 URL 去 302 追几跳」的场景（云打印就是：authcenter 会先校验 ST，
///   再 302 回内网系统发 `uniToken`，最后才落 cookie）。票据被会话层提前
///   消费掉，那条链就断在第一步。
class CasSessionCenter {
  CasSessionCenter._();

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static const String _kTgt = 'cas_tgt';
  static const String _kTgtAt = 'cas_tgt_at';
  static const String _kTgtOwner = 'cas_tgt_owner';

  /// TGT 缓存有效期。
  ///
  /// 取 90 分钟而不是 CAS 服务端的上限：票据是**一次性**的活性凭证，多留一会
  /// 只会让「早上存下、下午才用」的过期票越来越多。90 分钟覆盖「打开 App 干
  /// 完一轮事」绰绰有余，过期了大不了重登一次（有本机密码时是静默的）。
  static const Duration ttl = Duration(minutes: 90);

  static String? _tgt;
  static String? _owner;
  static DateTime? _savedAt;

  /// 最近一次 [ensureTgt] 里 CAS 登录的状态（`CasClient.ok` 等常量）。
  ///
  /// 给界面区分「密码错 / 账号被锁 / 网络不行」用 —— `ensureTgt` 只回 TGT
  /// 或 null，null 的三种原因对用户的处置完全不同，不能都糊成「登录失败」。
  static String lastLoginStatus = '';

  /// 内存里的 TGT（测试与诊断用）。生产代码不要去读它，走 [stFor]。
  static String? get debugTgt => _tgt;

  /// 取一张指定 service 的 ST —— **只换票，不访问**。
  ///
  /// 返回 null 有两种含义（调用方处理方式一样：转 [ensureTgt] 重登）：
  ///  - 没有可用 TGT；
  ///  - TGT 已经失效（CAS 对过期票返回的不是 ST 开头）。
  static Future<String?> stFor(CampusSession session, String service) async {
    final tgt = _tgt;
    if (tgt == null || tgt.isEmpty) return null;
    try {
      final r = await session.postForm(
        '${CasClient.casBase}/lyuapServer/v1/tickets/$tgt',
        {'service': service},
        headers: {'Referer': '${CasClient.casBase}/'},
      );
      final body = r.body.trim();
      // 正常是纯文本 `ST-155735-xxxx`；有些部署会包一层 JSON，两种都认。
      var st = body;
      final j = CampusSession.tryJson(body);
      if (j != null && j['ticket'] is String) st = j['ticket'] as String;
      if (st.startsWith('ST-')) return st;
    } catch (_) {
      // 落到下面按「票已失效」处理
    }
    // 换不出票 = 这张 TGT 废了。必须当场清掉，否则之后每次调用都会
    // 拿着一张死票去 CAS 撞一次失败，白等网络往返。
    await clear();
    return null;
  }

  /// 确保有一张可用 TGT：缓存命中（且归属对得上）直接返回，否则登录一次。
  ///
  /// [password] 为空串（用户关了「记住密码」）时本方法**不会**弹任何输入框 ——
  /// 它只负责「能不能静默完成」，要不要问用户由界面层决定。
  static Future<String?> ensureTgt(
    CampusSession session, {
    required String username,
    required String password,
  }) async {
    final sno = username.trim();
    if (sno.isEmpty) return null;
    final cached = _tgt;
    if (cached != null && cached.isNotEmpty && _owner == sno) return cached;

    if (password.isEmpty) {
      lastLoginStatus = '';
      return null;
    }
    final login = await CasClient.login(session, sno, password);
    lastLoginStatus = login.status;
    if (!login.ok || login.tgt == null || login.tgt!.isEmpty) return null;
    await save(sno, login.tgt!);
    return login.tgt;
  }

  /// 从 SecureStorage 恢复（App 启动 / 冷启动后第一次用到时调）。
  ///
  /// 必须校验归属人：cookie/票据是账号绑定的，换账号后复用它 = 拿到
  /// **上一个人的数据**。这条在 `CampusStore.loadFreshSession` 里已经踩过一次。
  static Future<void> restore({required String username}) async {
    if (_tgt != null) return;
    try {
      final owner = await _secure.read(key: _kTgtOwner);
      if (owner == null || owner.isEmpty || owner != username.trim()) {
        // 归属对不上：可能是换过账号，静默丢弃，不要留给下一个人。
        if (owner != null && owner.isNotEmpty) await clear();
        return;
      }
      final tgt = await _secure.read(key: _kTgt);
      final at = await _secure.read(key: _kTgtAt);
      if (tgt == null || tgt.isEmpty || at == null) return;
      final savedAt = DateTime.tryParse(at);
      if (savedAt == null || DateTime.now().difference(savedAt) >= ttl) {
        await clear();
        return;
      }
      _tgt = tgt;
      _owner = owner;
      _savedAt = savedAt;
    } catch (_) {
      // 安全存储不可用（少数机型 Keystore 异常）→ 当作没缓存，功能仍可用
    }
  }

  /// 写入 TGT（内存 + 落盘）。
  static Future<void> save(String username, String tgt) async {
    _tgt = tgt;
    _owner = username.trim();
    _savedAt = DateTime.now();
    try {
      await _secure.write(key: _kTgt, value: tgt);
      await _secure.write(key: _kTgtAt, value: _savedAt!.toIso8601String());
      await _secure.write(key: _kTgtOwner, value: _owner!);
    } catch (_) {}
  }

  /// 最近一次拿到 TGT 的时刻（诊断用）。
  static DateTime? get savedAt => _savedAt;

  /// 清空内存 + 落盘缓存。退出登录 / 换账号 / 换表时必须调。
  static Future<void> clear() async {
    _tgt = null;
    _owner = null;
    _savedAt = null;
    try {
      await _secure.delete(key: _kTgt);
      await _secure.delete(key: _kTgtAt);
      await _secure.delete(key: _kTgtOwner);
    } catch (_) {}
  }
}
