import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'campus_session.dart';
import 'cas_client.dart';
import 'card_balance.dart';
import 'course_fetcher.dart';
import 'jwgl_client.dart';
import 'study_client.dart';
import 'sygl_client.dart';
import 'web_campus_client.dart';
import 'web_campus_session.dart';
import '../../models/study_models.dart';

/// 教务会话缓存（本地版：把「登录一次」的成果存下来，避免每次查询都过验证码）。
///
/// 说明：账密本身**不在这里存** —— 本地版的账号沿用「用户页」已绑定的
/// 统一认证账号（`StorageService.loadUserConfig()`），这里只缓存会话 cookie。
class CampusStore {
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static const String _kSession = 'local_campus_session';
  static const String _kSessionAt = 'local_campus_session_at';
  /// 🔴 会话归属人（2026-10-13 修跨账号数据串台）。
  static const String _kSessionUser = 'local_campus_session_user';

  /// 会话缓存有效期（保守 20 分钟；教务侧约 30 分钟不活动才过期）
  static const Duration sessionTtl = Duration(minutes: 20);

  /// 保存会话：**连同账号一起存**。
  ///
  /// 为什么必须带账号：cookie 是账号绑定的凭证，只存 cookie 不加归属，
  /// 下次换账号登录就会复用上一个人的会话 —— 查到**别人的成绩/课表**
  /// （代码审查报告：严重·跨账号数据错误）。
  static Future<void> saveSession(
    Map<String, String> cookies, {
    required String username,
  }) async {
    await _secure.write(key: _kSession, value: jsonEncode(cookies));
    await _secure.write(
        key: _kSessionAt, value: DateTime.now().toIso8601String());
    await _secure.write(key: _kSessionUser, value: username);
  }

  /// 读取会话：**只有归属人与本次请求的账号一致**才复用。
  static Future<Map<String, String>?> loadFreshSession(
      {required String username}) async {
    final at = await _secure.read(key: _kSessionAt);
    final raw = await _secure.read(key: _kSession);
    final owner = await _secure.read(key: _kSessionUser);
    if (at == null || raw == null || raw.isEmpty) return null;
    // 账号不符 / 老数据没有归属人 → 一律不复用（宁可多登一次，也不能查错人）
    if (owner == null || owner.isEmpty || owner != username) return null;
    final savedAt = DateTime.tryParse(at);
    if (savedAt == null ||
        DateTime.now().difference(savedAt) >= sessionTtl) {
      return null;
    }
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearSession() async {
    await _secure.delete(key: _kSession);
    await _secure.delete(key: _kSessionAt);
    await _secure.delete(key: _kSessionUser);
  }
}

/// 本地直连门面：对外只暴露「查成绩 / 查考试」。
///
/// 内部流程：**复用会话 → 命中失效则自动重登一次**（只有会话失效时才需要过验证码）。
/// 账密由调用方传入（来自「用户页」已绑定的账号），本类不负责保存账密。
class LocalCampusService {
  static CampusSession? _session;
  static String? _sessionUser;

  /// 融合门户会话 —— 与教务会话**互相独立**（两个子系统各自的 cookie）。
  /// 一卡通余额走这里；教务（成绩/考试/课表）走 [_session]。
  static CampusSession? _portalSession;
  static String? _portalUser;

  /// Web 代理会话：服务端按 sessionId 持有 cookie 罐，本地只存凭证。
  /// [_webSid] 就绪会话；[_webPendingSid] 待回填验证码的 pending 会话。
  static String? _webSid;
  static String? _webPendingSid;
  static String? _webSidUser;

  // ---- Web sid 本地持久化（刷新 / 重开浏览器后免重登，服务端罐未过期前提下）----
  static const String _kWebSid = 'web_campus_sid';
  static const String _kWebSidUser = 'web_campus_sid_user';
  static const String _kWebSidAt = 'web_campus_sid_at';

  /// 本地留存兜底上限：真正有效性以服务端 ping 为准；这里只避免长期挂死旧 sid。
  static const Duration _webSidLocalTtl = Duration(hours: 12);

  static Future<void> _persistWebSid(String sid, String username) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kWebSid, sid);
    await p.setString(_kWebSidUser, username);
    await p.setString(_kWebSidAt, DateTime.now().toIso8601String());
  }

  static Future<void> _clearPersistedWebSid() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kWebSid);
    await p.remove(_kWebSidUser);
    await p.remove(_kWebSidAt);
  }

  /// 一期 Web 暂不接入的子系统（门户余额 / sygl 实验课）仍在此兜底拦截，
  /// 避免触达 dart:io 抛未捕获异常白屏；入口 UI 不隐藏，与安卓保持一致。
  static void _guardWeb() {
    if (kIsWeb) {
      throw CampusException('网页版暂不支持该功能，请使用安卓 App');
    }
  }

  /// 上一次登录说明（成功尝试次数 / 失败原因），便于排查
  static String lastLoginNote = '';

  static void clear() {
    _session?.close();
    _session = null;
    _sessionUser = null;
    _portalSession?.close();
    _portalSession = null;
    _portalUser = null;
    if (_webSid != null) WebCampusProxy.logout(_webSid!);
    _webSid = null;
    _webPendingSid = null;
    _webSidUser = null;
    // 退出登录同步清掉本地留存的 sid，避免下次换账号复用上一个会话。
    _clearPersistedWebSid();
  }

  /// Web 第一步：提交账密。服务端会自动识别验证码，识别成功就直接是已登录态
  /// （[WebLoginStart.loggedIn] 为 true，不再弹验证码）；失败才把图交人工回填。
  static Future<WebLoginStart> beginWebLogin(
      String username, String password) async {
    final start = await WebCampusProxy.startLogin(username, password);
    _webSidUser = username;
    if (start.loggedIn) {
      // 服务端已经替我们完成 CAS 登录，直接进就绪态并落盘，刷新后免重登。
      _webSid = start.sessionId;
      _webPendingSid = null;
      await _persistWebSid(start.sessionId, username);
    } else {
      _webPendingSid = start.sessionId;
    }
    return start;
  }

  /// Web 第二步：回填验证码，完成 CAS 登录并建立教务会话。
  static Future<void> submitWebCaptcha(String code) async {
    final sid = _webPendingSid;
    if (sid == null) {
      throw CampusException('登录会话已失效，请重新登录');
    }
    await WebCampusProxy.submitCaptcha(sid, code);
    _webSid = sid;
    _webPendingSid = null;
    // 落盘 sid + 归属人 + 时间戳：刷新 / 重开浏览器后先探活复用。
    await _persistWebSid(sid, _webSidUser ?? '');
  }

  /// 启动后尝试用本地留存的 sid 恢复 Web 会话（归属人匹配 + 本地兜底 TTL 内，
  /// 再向服务端探活）。探活通过则置回内存；失败清本地，留给两步登录。
  static Future<void> restoreWebSession(String username) async {
    if (_webSid != null) return;
    final p = await SharedPreferences.getInstance();
    final sid = p.getString(_kWebSid);
    final owner = p.getString(_kWebSidUser);
    final at = p.getString(_kWebSidAt);
    if (sid == null || sid.isEmpty || owner != username) return;
    if (at != null) {
      final t = DateTime.tryParse(at);
      if (t == null || DateTime.now().difference(t) > _webSidLocalTtl) {
        await _clearPersistedWebSid();
        return;
      }
    }
    final ok = await WebCampusProxy.ping(sid);
    if (ok) {
      _webSid = sid;
      _webSidUser = username;
    } else {
      await _clearPersistedWebSid();
    }
  }

  /// 取 Web 就绪会话；未登录 / 已过期则抛 needRelogin，由界面引导重新登录。
  static Future<CampusSessionBase> _ensureWeb(String username) async {
    if (_webSid == null) await restoreWebSession(username);
    final sid = _webSid;
    if (sid == null) {
      throw CampusException('登录已过期，请重新登录', needRelogin: true);
    }
    return WebCampusSession(sid);
  }

  static Future<CampusSession> _ensure(
      String username, String password) async {
    if (_session != null && _sessionUser == username) return _session!;

    final s = CampusSession();
    final cached = await CampusStore.loadFreshSession(username: username);
    if (cached != null && cached.isNotEmpty) {
      s.importCookies(cached);
      _session = s;
      _sessionUser = username;
      return s;
    }

    await _doLogin(s, username, password);
    return s;
  }

  static Future<void> _doLogin(
      CampusSession s, String username, String password) async {
    final res = await CasClient.loginAndSso(s, username, password);
    lastLoginNote = res.note;
    if (!res.ok) {
      throw CampusException(res.note,
          needRelogin: res.status == CasClient.badCredential);
    }
    await CampusStore.saveSession(s.exportCookies(), username: username);
    _session = s;
    _sessionUser = username;
  }

  /// 执行一次查询；若会话被教务系统判为失效，则清缓存重登一次再试。
  static Future<T> _withRelogin<T>(
    String username,
    String password,
    Future<T> Function(CampusSessionBase) run,
  ) async {
    // Web：走服务端有状态代理会话。教务罐在服务端过期时，先用留存的 TGT
    // **免验证码**静默重建（这是对齐 h5「重进不用重新登录」的体验），
    // 重建失败才清本地 sid，让界面走两步登录。
    if (kIsWeb) {
      final s = await _ensureWeb(username);
      try {
        return await run(s);
      } on CampusException catch (e) {
        if (!e.needRelogin) rethrow;
        final sid = _webSid;
        if (sid != null && await WebCampusProxy.refresh(sid)) {
          return await run(WebCampusSession(sid));
        }
        _webSid = null;
        _webSidUser = null;
        await _clearPersistedWebSid();
        rethrow;
      }
    }
    var s = await _ensure(username, password);
    try {
      return await run(s);
    } on CampusException catch (e) {
      if (!e.needRelogin) rethrow;
      await CampusStore.clearSession();
      s.close();
      s = CampusSession();
      await _doLogin(s, username, password);
      return await run(s);
    }
  }

  /// 查全部学期成绩（返回结构与原实现一致，界面层无需改动）
  static Future<Map<String, dynamic>> fetchGrades(
          String username, String password) =>
      _withRelogin(username, password, (s) => JwglClient.fetchGrades(s));

  /// 查某学期考试安排
  static Future<Map<String, dynamic>> queryExams(
          String username, String password, String xnm, String xqm) =>
      _withRelogin(
          username, password, (s) => JwglClient.queryExams(s, xnm, xqm));

  /// 查某学期教材预订信息
  static Future<Map<String, dynamic>> queryTextbooks(
          String username, String password, String xnm, String xqm) =>
      _withRelogin(
          username, password, (s) => JwglClient.queryTextbooks(s, xnm, xqm));

  /// 校验统一认证账密（登录用）。
  ///
  /// 走**一次真实的 CAS 登录**（不复用缓存 cookie）—— 否则「密码改了但旧会话仍有效」
  /// 会误判为登录成功。成功后 [_session] 被设好，后续查询直接复用，不用再过验证码。
  /// 失败抛 [CampusException]，message 已是中文可读文案。
  static Future<void> verifyLogin(String username, String password) async {
    _guardWeb();
    final session = CampusSession();

    // ① 只做**一步**校验：CAS 登录拿到 TGT 即证明账密正确。
    //    不再拿「换票据建教务会话」的结果判定登录 —— 那一步失败（教务子系统
    //    临时不可用等）**不代表账密错**，却会让用户以为「密码不对」。
    final res = await CasClient.login(session, username, password);
    lastLoginNote = res.note;
    if (!res.ok) {
      session.close();
      throw CampusException(res.note,
          needRelogin: res.status == CasClient.badCredential);
    }

    // ② 顺手建立教务会话：成功则后续查询免验证码；**失败不影响登录结果**。
    try {
      final ok = await CasClient.ssoTo(session, res.tgt!);
      if (ok) {
        await CampusStore.saveSession(session.exportCookies(),
            username: username);
        _session = session;
        _sessionUser = username;
        return;
      }
    } catch (_) {
      // 忽略：登录已经成功，教务会话让后续查询自己去建
    }
    session.close();
  }

  /// 取学生信息（姓名 / 学号 / 专业 / 学院 / 年级）。
  ///
  /// ⚠️ 数据来自**成绩查询**返回的 `student` 块 —— 正方教务把学生信息挂在成绩行上，
  ///    因此**没有成绩记录时拿不到**（返回 null，例如新生）。
  ///    拿不到不抛异常，由界面侧降级展示（只显示学号）。
  static Future<Map<String, dynamic>?> tryFetchStudentInfo(
      String username, String password) async {
    try {
      final r = await fetchGrades(username, password);
      final s = r['student'];
      if (s is Map) {
        final m = Map<String, dynamic>.from(s);
        if ((m['xm'] ?? '').toString().trim().isNotEmpty) return m;
      }
    } catch (_) {
      // 无成绩 / 网络异常：拿不到姓名不阻塞界面
    }
    return null;
  }

  /// 查「我的学业」学业档案（v1.10.0 新增：客户端直连教务「学生学业情况查询」）。
  ///
  /// 教务是否返回培养方案树取决于**学校有没有给这一届配培养方案**：
  /// 有 → 10 个板块 135 门课；没有 → 只能拿本学期课表按类别分组。
  /// 两种情况都返回 [StudyArchive]，由界面按 `mode` 决定怎么展示。
  static Future<StudyArchive> fetchStudy(
          String username, String password, String xnm, String xqm) =>
      _withRelogin(username, password,
          (s) => StudyClient.fetch(s, fallbackXnm: xnm, fallbackXqm: xqm));

  /// 查某学期课表（v2.0.0 新增：客户端直连教务系统）。
  /// 返回结构，界面层无需改动。
  static Future<Map<String, dynamic>> fetchSchedule(
          String username, String password, String xnm, String xqm) =>
      _withRelogin(
          username, password, (s) => CourseFetcher.fetch(s, xnm, xqm));

  /// 跨专业自选 · 步骤1：列出全部班级（可按关键字过滤）。
  /// 教务「班级课表打印」模块，客户端直连（v2.1.0）。
  static Future<Map<String, dynamic>> searchClassList(String username,
          String password, String xnm, String xqm, String keyword) =>
      _withRelogin(username, password,
          (s) => CourseFetcher.searchClassList(s, xnm, xqm, keyword));

  /// 跨专业自选 · 步骤2：取一个班的课表。
  static Future<Map<String, dynamic>> fetchClassCourses(String username,
          String password, String xnm, String xqm, String bhId) =>
      _withRelogin(username, password,
          (s) => CourseFetcher.fetchClassCourses(s, xnm, xqm, bhId));

  /// 查实验课（v1.0.9 新增：客户端直连实验管理系统 sygl.cwxu.edu.cn）。
  ///
  /// ⚠️ 与教务/门户一样是**独立子系统**：CAS 票据换的是 sygl 自己的
  ///   `ASP.NET_SessionId`，不能与 [fetchSchedule] 共用会话 —— 共用会有两个副作用：
  ///   ① 教务的 cookie 被一起发到 sygl；② sygl 判失效时 `_withRelogin` 会调
  ///   `CampusStore.clearSession()`，把**教务**的缓存会话一起清掉，下次查成绩白重登。
  ///   所以这里像 [fetchCardBalance] 一样自建会话，不走 [_withRelogin]。
  /// ⚠️ sygl **只开 80 端口**，必须走 http（`CampusSession` 里有白名单放行）。
  static Future<SyglLabFetchResult> fetchLabs(
      String username, String password) async {
    _guardWeb();
    Future<SyglLabFetchResult> once() async {
      final s = CampusSession();
      try {
        final err = await SyglClient.login(s, username, password);
        if (err != null) throw CampusException(err);
        return await SyglClient.fetchLabs(s);
      } finally {
        s.close();
      }
    }

    try {
      return await once();
    } on CampusException catch (e) {
      if (!e.needRelogin) rethrow;
      // 只重试一次：票据可能刚过期，重登一次通常就好。
      return once();
    }
  }

  /// 查一卡通余额（v2.0.0 新增：客户端直连融合门户）。
  ///
  /// ⚠️ 门户与教务是**两个子系统**，cookie 不通用 —— 所以这里独立建会话，
  ///   不复用 [_session]。门户会话**不做持久化缓存**（门户侧签发较敏感，
  ///   且余额查询本身低频），每次查询重新 CAS 登录建立。
  static Future<Map<String, dynamic>> fetchCardBalance(
      String username, String password) async {
    // Web：复用代理会话隧道访问融合门户（门户 cookie 罐由服务端持有）。
    // 走 _withRelogin 是为了共享「会话失效 → 静默续期 → 原地重试」这一条路径。
    if (kIsWeb) {
      return _withRelogin(username, password,
          (s) => CardBalanceClient.fetch(s, username, password));
    }
    if (_portalSession != null && _portalUser == username) {
      try {
        return await CardBalanceClient.fetch(
            _portalSession!, username, password);
      } on CampusException catch (e) {
        if (!e.needRelogin) rethrow;
        _portalSession!.close();
        _portalSession = null;
        _portalUser = null;
      }
    }
    final s = CampusSession();
    try {
      final r = await CardBalanceClient.fetch(s, username, password);
      _portalSession = s;
      _portalUser = username;
      return r;
    } catch (_) {
      s.close();
      rethrow;
    }
  }
}
