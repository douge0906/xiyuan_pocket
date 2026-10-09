import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'campus_session.dart';
import 'cas_client.dart';
import 'card_balance.dart';
import 'course_fetcher.dart';
import 'jwgl_client.dart';

/// 教务会话缓存（本地版：把「登录一次」的成果存下来，避免每次查询都过验证码）。
///
/// 说明：账密本身**不在这里存** —— 本地版的账号沿用「用户页」已绑定的
/// 统一认证账号（`StorageService.loadUserConfig()`），这里只缓存会话 cookie。
class CampusStore {
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static const String _kSession = 'local_campus_session';
  static const String _kSessionAt = 'local_campus_session_at';

  /// 会话缓存有效期（保守 20 分钟；教务侧约 30 分钟不活动才过期）
  static const Duration sessionTtl = Duration(minutes: 20);

  static Future<void> saveSession(Map<String, String> cookies) async {
    await _secure.write(key: _kSession, value: jsonEncode(cookies));
    await _secure.write(
        key: _kSessionAt, value: DateTime.now().toIso8601String());
  }

  static Future<Map<String, String>?> loadFreshSession() async {
    final at = await _secure.read(key: _kSessionAt);
    final raw = await _secure.read(key: _kSession);
    if (at == null || raw == null || raw.isEmpty) return null;
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

  /// 上一次登录说明（成功尝试次数 / 失败原因），便于排查
  static String lastLoginNote = '';

  static void clear() {
    _session?.close();
    _session = null;
    _sessionUser = null;
    _portalSession?.close();
    _portalSession = null;
    _portalUser = null;
  }

  static Future<CampusSession> _ensure(
      String username, String password) async {
    if (_session != null && _sessionUser == username) return _session!;

    final s = CampusSession();
    final cached = await CampusStore.loadFreshSession();
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
    await CampusStore.saveSession(s.exportCookies());
    _session = s;
    _sessionUser = username;
  }

  /// 执行一次查询；若会话被教务系统判为失效，则清缓存重登一次再试。
  static Future<T> _withRelogin<T>(
    String username,
    String password,
    Future<T> Function(CampusSession) run,
  ) async {
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
        await CampusStore.saveSession(session.exportCookies());
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

  /// 查某学期课表（v2.0.0 开源版新增：客户端直连教务系统）。
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

  /// 查一卡通余额（v2.0.0 开源版新增：客户端直连融合门户）。
  ///
  /// ⚠️ 门户与教务是**两个子系统**，cookie 不通用 —— 所以这里独立建会话，
  ///   不复用 [_session]。门户会话**不做持久化缓存**（门户侧签发较敏感，
  ///   且余额查询本身低频），每次查询重新 CAS 登录建立。
  static Future<Map<String, dynamic>> fetchCardBalance(
      String username, String password) async {
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
