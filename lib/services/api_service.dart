import 'auth_gate.dart';
import 'campus/campus_store.dart';
import 'storage_service.dart';

/// 「我的」页与查询页 到 **客户端直连** 的门面。
///
/// ⚠️ 开源版说明：本类原名 `ApiService`，是服务端 HTTP 接口的封装。改成客户端
/// 直连后，它只剩一层很薄的转发 —— 把 `LocalCampusService`（CAS 统一认证 +
/// 正方教务 + 融合门户）包装成界面层习惯的签名。
///
/// 类名与既有方法签名保持不变，只是为了不动所有调用方；它**不再涉及任何服务端**。
class ApiService {
  /// 解析本次查询要用的账密。
  ///
  /// ① 调用方显式传入（临时查他人账号）→ 直接用；
  /// ② 否则读**本机**已保存的账号（`StorageService`，密码在系统安全存储里）。
  ///
  /// 拿不到就抛异常 —— 让页面提示去登录，而不是静默失败。
  static Future<({String username, String password})> _resolveCredential(
      String username, String password) async {
    if (username.isNotEmpty && password.isNotEmpty) {
      return (username: username, password: password);
    }
    final cfg = await StorageService.loadUserConfig();
    final u = username.isNotEmpty ? username : cfg.username;
    final p = password.isNotEmpty ? password : cfg.password;
    if (u.isEmpty || p.isEmpty) {
      // ⚠️ 文案统一取自 AuthGate，避免各页面/服务各写一套「未登录」提示。
      throw Exception(AuthGate.loginRequiredMessage);
    }
    return (username: u, password: p);
  }

  /// 校验统一认证账密（登录时调用）。
  ///
  /// CAS 登录成功即认为账密有效；成功后**会话被缓存**，随后查成绩/考试/课表
  /// 直接复用，不必再过一次验证码。
  /// 失败抛 `CampusException`，其 message 已是中文可读文案。
  static Future<void> verifyLogin(String username, String password) =>
      LocalCampusService.verifyLogin(username, password);

  /// 取学生信息（姓名 / 学号 / 专业 / 学院 / 年级）。
  ///
  /// 数据来自成绩查询返回的 `student` 块。**没有成绩记录时返回 null**（例如新生），
  /// 由界面侧降级展示。
  static Future<Map<String, dynamic>?> tryFetchStudentInfo() async {
    final c = await _resolveCredential('', '');
    return LocalCampusService.tryFetchStudentInfo(c.username, c.password);
  }

  /// 查询成绩（客户端直连教务系统）。
  static Future<Map<String, dynamic>> pushGrades({
    String username = '',
    String password = '',
  }) async {
    final c = await _resolveCredential(username, password);
    return LocalCampusService.fetchGrades(c.username, c.password);
  }

  /// 查询一卡通余额（客户端直连融合门户）。
  static Future<Map<String, dynamic>> fetchCardBalance({
    String username = '',
    String password = '',
  }) async {
    final c = await _resolveCredential(username, password);
    final data =
        await LocalCampusService.fetchCardBalance(c.username, c.password);
    // 门面返回的是「余额本身」，而页面读的是 res['data']['balance'] —— 包一层对齐旧契约。
    return {'data': data};
  }

  /// 从教务系统导入课程表（客户端直连抓取）。
  static Future<Map<String, dynamic>> fetchSchedule({
    String username = '',
    String password = '',
    required String xnm,
    required String xqm,
  }) async {
    final c = await _resolveCredential(username, password);
    // ⚠️ 页面读的是 res['data']['courses'] —— 这里必须包一层对齐旧契约。
    //    （与 fetchCardBalance 同样的处理；漏掉会导致导入「成功」但一门课都没有。）
    final data = await LocalCampusService.fetchSchedule(
        c.username, c.password, xnm, xqm);
    return {'data': data};
  }

  /// 搜索班级（跨专业自选 · 步骤1：选班）。
  ///
  /// 开源版无服务器：客户端直连教务「班级课表打印」模块。
  /// [keyword] 留空返回全部（357 个班，本机缓存 30 分钟）。
  static Future<Map<String, dynamic>> searchClassList({
    required String xnm,
    required String xqm,
    String keyword = '',
  }) async {
    final c = await _resolveCredential('', '');
    final data = await LocalCampusService.searchClassList(
        c.username, c.password, xnm, xqm, keyword);
    return {'data': data};
  }

  /// 抓取一个班级的课表（跨专业自选 · 步骤2：取课）。
  /// 返回 data.courses 的字段与学生课表接口完全一致。
  static Future<Map<String, dynamic>> fetchClassSchedule({
    required String xnm,
    required String xqm,
    required String bhId,
  }) async {
    final c = await _resolveCredential('', '');
    final data = await LocalCampusService.fetchClassCourses(
        c.username, c.password, xnm, xqm, bhId);
    return {'data': data};
  }

  /// 从教务系统查询考试安排。
  static Future<Map<String, dynamic>> fetchExams({
    String username = '',
    String password = '',
    required String xnm,
    required String xqm,
  }) async {
    final c = await _resolveCredential(username, password);
    // ⚠️ 同上：页面读 res['data']['exams']，不包一层就会「查询成功但 0 门考试」。
    final data = await LocalCampusService.queryExams(
        c.username, c.password, xnm, xqm);
    return {'data': data};
  }

  /// 从教务系统查询教材预订信息（客户端直连抓取）。
  static Future<Map<String, dynamic>> fetchTextbooks({
    String username = '',
    String password = '',
    required String xnm,
    required String xqm,
  }) async {
    final c = await _resolveCredential(username, password);
    // 同上：页面读 res['data']['books']。
    final data = await LocalCampusService.queryTextbooks(
        c.username, c.password, xnm, xqm);
    return {'data': data};
  }
}
