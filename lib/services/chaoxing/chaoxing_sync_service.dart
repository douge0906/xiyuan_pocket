import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_chaoxing/flutter_chaoxing.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/todo.dart';
import '../../repositories/todo_repository.dart';
import '../exam_storage.dart';

/// 「学习通同步」服务层 —— 本服务项的全部逻辑都收在这一个类里。
///
/// ## 边界（用户 2026-11-23 明确划定）
/// 「最多其具备同步功能影响外界，其余为其独立服务项功能。」
///
/// 也就是说：
/// - **允许**：把学习通的作业写进「待办」、把考试写进「考试安排」——
///   这是「同步」这个动作本身该有的效果。
/// - **不允许**：往课表、成绩、一卡通、消息中心里塞任何东西；不注册全局
///   定时任务；不改别人的存储键。登录、拉取、解析、凭证保管全部留在本服务内。
///
/// ## 凭证与会话
/// 账号、密码都**不进 SharedPreferences**：会话（cookie + puid）与设备
/// uniqueId 存在系统安全存储（Android Keystore）。账号明文只用于界面回显。
///
/// `uniqueId` 由 [ChaoxingSignCrypto.newUniqueId] 生成一次后**永久复用**——
/// 每次登录换一个新设备号，学习通会判成新设备并索要短信二次验证。
///
/// ## 待办同步的四个坑（都照抄了 `CourseTodoService` 的既有结论）
/// 1. **串行锁**：手动「立即同步」与自动同步可能同时进来，两边各自读到的快照
///    都不含对方刚写的记录 → 同一条作业插两份。用一条 Future 链排队。
/// 2. **id 里的日期必须补零**：`2026-01-12` 与 `2026-11-02` 不补零会撞成同一天。
/// 3. **用户删掉的不能在下次同步时又冒出来**：抑制集合 + `suppress/unsuppress`。
/// 4. **已划掉的不能被同步覆盖回未完成**：`addMany` 按 `compositeKey` 覆盖，
///    所以写入前要先跳过库里「同键且已完成」的那条。
class ChaoxingSyncService {
  ChaoxingSyncService._();

  // ───────────────── 存储键 ─────────────────

  /// 会话（cookie + puid/uid/fid）—— 安全存储。
  static const String _kSession = 'chaoxing_session_v1';

  /// 访问超星网页时用的 UA。用普通手机浏览器 UA —— 学习通的服务端对
  /// `passport2-api` 拒官方 App UA、对 `mobilelearn` 又只认官方 UA，
  /// 而我们要走的 `mooc1-api` 这两条都不沾，浏览器 UA 最稳。
  static const String _kUserAgent =
      'Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 设备唯一号 —— 安全存储。见 [uniqueId] 注释。
  static const String _kUniqueId = 'chaoxing_unique_id_v1';

  /// 账号明文（仅用于设置页回显「已绑定 xxx」）。密码**永不落盘**。
  static const String _kAccount = 'chaoxing_account_v1';

  /// 同步开关。关掉只是不再自动同步，已写入的待办/考试不动。
  static const String _kEnabled = 'chaoxing_sync_enabled_v1';

  /// 上次同步时间（ISO8601）。
  static const String _kLastSync = 'chaoxing_last_sync_v1';

  /// 上次同步的结果摘要（给设置页显示一句话）。
  static const String _kLastSummary = 'chaoxing_last_summary_v1';

  /// 用户主动删除过的学习通待办，键与同步层同一套（见 [_idOn]）。
  static const String _kSuppressed = 'chaoxing_todo_suppressed_v1';

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  /// 待办 id 前缀。`home_page` 的删除流程据此决定要不要登记抑制键。
  static const String todoIdPrefix = 'chaoxing_';

  /// 考试 id 前缀。
  ///
  /// 为什么不用第三种 `source`：`ExamStorage._normalize` 会把非 `manual` 的来源
  /// 一律强制写成 `server`，而 `exam_query_page` 用 `source == manual` 判断
  /// 「是不是手动添加」——加第三种来源只会让这两处同时失真。
  /// 因此来源仍是 `server`，用 id 前缀区分「这条是学习通来的」。
  static const String examIdPrefix = 'chaoxing|';

  // ───────────────── 串行锁 ─────────────────

  static Future<void> _lock = Future<void>.value();

  static Future<T> _exclusive<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final prev = _lock;
    _lock = prev.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  // ───────────────── 抑制集合（用户删掉的别再回来） ─────────────────

  // 🔴 必须是 final 不是 const：const 集合不可变，`add`/`clear` 会抛
  //    `Unsupported operation: Cannot change an unmodifiable set`，
  //    后果是「用户删掉的待办下次同步又回来」（抑制键根本没登记上）。
  static final Set<String> _suppressed = <String>{};

  static Future<void> _loadSuppressed() async {
    if (_suppressed.isNotEmpty) return;
    try {
      final sp = await SharedPreferences.getInstance();
      _suppressed
        ..clear()
        ..addAll(sp.getStringList(_kSuppressed) ?? const <String>[]);
    } catch (_) {
      // 读不到就当空集：本次会话可能重建一条已删的待办，不阻断同步。
    }
  }

  static Future<void> _saveSuppressed() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(_kSuppressed, _suppressed.toList()..sort());
    } catch (_) {
      // 存不下只留内存态。
    }
  }

  /// 待办 id + 日期 的复合键（与本服务写待办时用的是同一套）。
  static String _idOn(String id, DateTime day) {
    final m = day.month.toString().padLeft(2, '0');
    final d = day.day.toString().padLeft(2, '0');
    return '$id@${day.year}$m$d';
  }

  /// 判断这条学习通待办是否被用户主动删过。
  static Future<bool> isSuppressed(String id, DateTime day) async {
    await _loadSuppressed();
    return _suppressed.contains(_idOn(id, day));
  }

  /// 登记「用户删掉了这条学习通待办」，并顺带清理过期键。
  static Future<void> suppress(String id, DateTime day) async {
    await _loadSuppressed();
    _suppressed.add(_idOn(id, day));
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _suppressed.removeWhere((k) {
      final at = k.indexOf('@');
      if (at < 0) return true;
      final raw = k.substring(at + 1);
      if (raw.length != 8) return true;
      final y = int.tryParse(raw.substring(0, 4));
      final m = int.tryParse(raw.substring(4, 6));
      final d = int.tryParse(raw.substring(6, 8));
      if (y == null || m == null || d == null) return true;
      return DateTime(y, m, d).isBefore(today);
    });
    await _saveSuppressed();
  }

  /// 解除抑制（用户撤销删除，或重新手动添加了同一天的同一条）。
  static Future<void> unsuppress(String id, DateTime day) async {
    await _loadSuppressed();
    if (_suppressed.remove(_idOn(id, day))) await _saveSuppressed();
  }

  /// 仅供测试。
  @visibleForTesting
  static void debugResetCaches() => _suppressed.clear();

  // ───────────────── 状态读取 ─────────────────

  /// 已绑定的账号明文（未绑定返回空串）。
  static Future<String> account() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return (sp.getString(_kAccount) ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  /// 是否已绑定（有账号且有可用会话）。
  static Future<bool> isBound() async {
    final acc = await account();
    if (acc.isEmpty) return false;
    final s = await _loadSession();
    return s != null && s.isValid;
  }

  /// 自动同步开关，默认开（用户绑定的目的就是要它同步）。
  static Future<bool> enabled() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getBool(_kEnabled) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool value) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_kEnabled, value);
    } catch (_) {}
  }

  static Future<DateTime?> lastSyncAt() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kLastSync);
      if (raw == null || raw.isEmpty) return null;
      return DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<String> lastSummary() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return (sp.getString(_kLastSummary) ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  static Future<void> _recordSync(String summary) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kLastSync, DateTime.now().toIso8601String());
      await sp.setString(_kLastSummary, summary);
    } catch (_) {}
  }

  // ───────────────── 会话与设备号 ─────────────────

  /// 设备唯一号：生成一次后**永久复用**。
  ///
  /// 每次登录换一个新的，学习通会当成新设备并触发短信二次验证；
  /// 反过来，同一个号一直用，服务端才会认为「还是这台手机」。
  static Future<String> uniqueId() async {
    try {
      final existing = await _secure.read(key: _kUniqueId);
      if (existing != null && existing.trim().isNotEmpty) return existing;
      final fresh = ChaoxingSignCrypto.newUniqueId();
      await _secure.write(key: _kUniqueId, value: fresh);
      return fresh;
    } catch (_) {
      // 安全存储不可用（极少数机型）：退回进程内临时号，本次会话仍能登录。
      return ChaoxingSignCrypto.newUniqueId();
    }
  }

  static Future<ChaoxingSession?> _loadSession() async {
    try {
      final raw = await _secure.read(key: _kSession);
      if (raw == null || raw.isEmpty) return null;
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final s = ChaoxingSession.fromJson(map.cast<String, dynamic>());
      return s.isValid ? s : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveSession(ChaoxingSession s) async {
    await _secure.write(key: _kSession, value: jsonEncode(s.toJson()));
  }

  // ───────────────── 绑定 / 解绑 ─────────────────

  /// 绑定账密并立即同步一次。
  ///
  /// 返回值里的 [ChaoxingBindResult.message] 已经是可以直接展示给用户的中文。
  static Future<ChaoxingBindResult> bind(String account, String password) async {
    final acc = account.trim();
    if (acc.isEmpty) {
      return const ChaoxingBindResult(false, '请输入学习通账号（手机号）');
    }
    if (password.isEmpty) {
      return const ChaoxingBindResult(false, '请输入学习通密码');
    }

    final existing = await uniqueId();
    final auth = ChaoxingAuthService();
    ChaoxingSession session;
    try {
      session = await auth.login(
        ChaoxingCredentials(account: acc, password: password),
      );
      // 登录成功后把设备号挂回会话，后续请求头才带得上。
      session = session.copyWith(clientId: existing);
    } on ChaoxingCaptchaRequired {
      return const ChaoxingBindResult(
        false,
        '学习通要求人机验证。请先用手机 App 或浏览器登录一次学习通，'
        '完成验证后再回来绑定。',
      );
    } on ChaoxingSecondaryVerificationRequired {
      return const ChaoxingBindResult(
        false,
        '学习通认为这是一台新设备，需要短信二次验证。'
        '请先用手机 App 登录一次学习通，再回来绑定。',
      );
    } on ChaoxingBadCredentials {
      return const ChaoxingBindResult(false, '账号或密码不对，学习通没有通过');
    } catch (e) {
      return ChaoxingBindResult(false, '登录失败：${_friendly(e)}');
    }

    try {
      await _saveSession(session);
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kAccount, acc);
      await sp.setBool(_kEnabled, true);
    } catch (e) {
      return ChaoxingBindResult(false, '登录成功但保存凭证失败：${_friendly(e)}');
    }

    final r = await syncNow();
    if (r.error != null) {
      return ChaoxingBindResult(true, '已绑定，但首次同步没成功：${r.error}');
    }
    return ChaoxingBindResult(true, '已绑定：${r.summary}');
  }

  /// 解绑：清掉会话、账号、设备号与抑制集合。
  ///
  /// 已写进待办/考试的内容**不删** —— 那是用户自己的数据，解绑不该顺手清掉
  /// 他的待办列表。用户想清可以逐条删。
  static Future<void> unbind() async {
    try {
      await _secure.delete(key: _kSession);
      await _secure.delete(key: _kUniqueId);
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_kAccount);
      await sp.remove(_kLastSync);
      await sp.remove(_kLastSummary);
      await sp.setBool(_kEnabled, false);
      _suppressed.clear();
      await sp.remove(_kSuppressed);
    } catch (_) {}
  }

  // ───────────────── 同步 ─────────────────

  /// 立即同步一次（设置页按钮 / 绑定后自动调）。
  static Future<ChaoxingSyncResult> syncNow() => _exclusive(_syncInner);

  /// 到点才同步：距上次同步超过 [minInterval] 才真的跑。
  ///
  /// 由课表/首页这类「用户本来就会打开的页面」顺手触发，不注册任何后台任务。
  static Future<ChaoxingSyncResult?> syncIfDue({
    Duration minInterval = const Duration(hours: 6),
  }) async {
    if (!await enabled()) return null;
    if (!await isBound()) return null;
    final last = await lastSyncAt();
    if (last != null && DateTime.now().difference(last) < minInterval) {
      return null;
    }
    return syncNow();
  }

  /// 同步主流程。
  ///
  /// ## 为什么不是「一个 JSON 接口拿全部」
  /// 官方 App 用的 `mooc1-api.chaoxing.com/gas/taskmsg` 确实一次能给全
  /// （字段里连 `taskopentime`/`taskendtime` 都有），但它是 **WAF 保护的**：
  /// 不在官方客户端的网络里，任何 UA 都是 `403 很抱歉，您没有权限访问这个页面`。
  /// 2026-11-23 实测，连 `gas/clazz` 也一起 403。
  ///
  /// 所以真正能走的是「和客户端 WebView 同一张页面」这条路：
  ///   1. `mycourse/backclazzdata?view=json` 取课程（JSON，实测存在）
  ///   2. 每门课 `phone/moocAnalysis/workList` / `examList` 取作业与考试（HTML）
  /// 代价是每门课两次请求，所以主流程**先试 JSON feed，失败再走这条路**：
  /// 万一哪天 WAF 放行，就自动省下 N 次请求。
  static Future<ChaoxingSyncResult> _syncInner() async {
    final session = await _loadSession();
    if (session == null) {
      return const ChaoxingSyncResult(error: '还没有绑定学习通，或会话已失效');
    }

    final api = ChaoxingApiService();
    List<ChaoxingTaskItem> items;
    try {
      items = await _collectTasks(api, session);
    } catch (e) {
      final msg = _friendly(e);
      await _recordSync('同步失败：$msg');
      return ChaoxingSyncResult(error: msg);
    }

    final todos = await _writeTodos(items);
    final exams = await _writeExams(items);
    final summary = _summaryOf(todos, exams);
    await _recordSync(summary);
    return ChaoxingSyncResult(
      addedTodos: todos.added,
      removedTodos: todos.removed,
      exams: exams.written,
      summary: summary,
    );
  }

  /// 取全部任务：JSON feed 优先，不行就按课程逐门抓 HTML 页。
  static Future<List<ChaoxingTaskItem>> _collectTasks(
    ChaoxingApiService api,
    ChaoxingSession session,
  ) async {
    try {
      final feed = await api.fetchTaskFeed(session, userid: session.puid, limit: 50);
      if (feed.isNotEmpty) return feed;
    } catch (_) {
      // 403 WAF 是常态，不是异常情况 —— 直接落到下面那条路。
    }

    final courses = await _fetchCourses(session);
    if (courses.isEmpty) {
      // 课程都拿不到，说明会话已经不可用（或学校没开超星课）。
      throw const ChaoxingSessionExpired('拿不到课程列表，会话可能已失效');
    }

    final out = <ChaoxingTaskItem>[];
    var failed = 0;
    for (final c in courses) {
      try {
        final tasks = await api.fetchCourseTasks(
          session,
          courseId: c.courseId,
          classId: c.classId,
        );
        for (final t in tasks) {
          out.add(_courseTaskToItem(t, courseName: c.courseName, classId: c.classId));
        }
      } catch (_) {
        failed++;
      }
    }
    // 全部失败 = 真的同步不了，要报错；部分失败 = 用拿到的，别把好数据丢了。
    if (out.isEmpty && failed == courses.length) {
      throw const ChaoxingSessionExpired('这门课都没取到，会话可能已失效');
    }
    return out;
  }

  /// 课程列表。`backclazzdata` 是 JSON，结构是「班级 → 课程」：
  /// `channelList[i].content` 是一个班级（`id`=classId、`name`=班级名），
  /// 课程在 `content.course.data[]`（`id`=courseId、`name`=课程名）。
  static Future<List<_ChaoxingCourseRef>> _fetchCourses(
    ChaoxingSession session,
  ) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      followRedirects: false,
      validateStatus: (s) => s != null && s < 500,
    ));
    final res = await dio.get<String>(
      'https://mooc1-api.chaoxing.com/mycourse/backclazzdata',
      queryParameters: <String, String>{
        'view': 'json',
        'getTchClazzType': '1',
        'mcode': '',
      },
      options: Options(
        responseType: ResponseType.plain,
        headers: <String, String>{
          'User-Agent': _kUserAgent,
          'Accept': 'application/json, text/plain, */*',
          'Cookie': session.cookieHeader,
        },
      ),
    );
    final body = res.data ?? '';
    if (body.trim().isEmpty) return const [];
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const [];
    }
    if (decoded is! Map) return const [];
    final list = decoded['channelList'];
    if (list is! List) return const [];

    final out = <_ChaoxingCourseRef>[];
    for (final ch in list) {
      if (ch is! Map) continue;
      final content = ch['content'];
      if (content is! Map) continue;
      final classId = (content['id'] ?? '').toString();
      final className = (content['name'] ?? '').toString();
      final course = content['course'];
      if (course is! Map) continue;
      final data = course['data'];
      if (data is! List) continue;
      for (final row in data) {
        if (row is! Map) continue;
        final courseId = (row['id'] ?? '').toString();
        final name = (row['name'] ?? '').toString().trim();
        if (courseId.isEmpty || classId.isEmpty) continue;
        out.add(_ChaoxingCourseRef(
          courseId: courseId,
          classId: classId,
          courseName: name.isEmpty ? className : name,
        ));
      }
    }
    return out;
  }

  /// 课程页解析出来的一行 → 同步用的统一模型。
  ///
  /// 关键缺陷：`workList`/`examList` 的 HTML 行**只带一个日期字符串**
  /// （作业是 `<p>` 里的那行，考试是 `<td>` 里的分数位），没有成对的
  /// 「开考/截止」。所以这里做两件事：
  /// - 用正则从文本里尽力捞出一个日期时间；
  /// - 捞不到就交 0，由写入侧决定怎么降级（作业放今天、考试跳过）。
  static ChaoxingTaskItem _courseTaskToItem(
    ChaoxingCourseTask t, {
    required String courseName,
    required String classId,
  }) {
    final when = _parseWhen(t.detail) ?? _parseWhen(t.statusText);
    final start = when ?? DateTime.fromMillisecondsSinceEpoch(0);
    // 状态文案归一：包含「已完成/已交/已批阅」就当交过了。
    final done = ['已完成', '已交', '已提交', '已批阅', '已评分']
        .any(t.statusText.contains);
    return ChaoxingTaskItem(
      id: t.url.isNotEmpty ? t.url.hashCode.toRadixString(16) : t.title.hashCode.toRadixString(16),
      title: t.title,
      courseName: courseName,
      type: t.type,
      status: done ? 1 : 0,
      openTime: start,
      endTime: start,
      doTaskUrl: t.url,
      classId: classId,
    );
  }

  /// 从一段中文/英文文本里捞日期时间。
  /// 覆盖 `2026-11-30 23:59`、`2026年11月30日`、`11-30 23:59`（无年份按今年）。
  static DateTime? _parseWhen(String text) {
    if (text.trim().isEmpty) return null;
    final withYear = RegExp(
      r'(\d{4})\s*[-/年.]\s*(\d{1,2})\s*[-/月.]\s*(\d{1,2})'
      r'(?:\s*日)?(?:\s*(\d{1,2}):(\d{2}))?',
    ).firstMatch(text);
    if (withYear != null) {
      return _buildWhen(
        int.parse(withYear.group(1)!),
        int.parse(withYear.group(2)!),
        int.parse(withYear.group(3)!),
        withYear.group(4),
        withYear.group(5),
      );
    }
    final noYear = RegExp(
      r'(?:^|[^\d])(\d{1,2})\s*[-/月]\s*(\d{1,2})(?:\s*日)?'
      r'(?:\s*(\d{1,2}):(\d{2}))?',
    ).firstMatch(text);
    if (noYear != null) {
      final now = DateTime.now();
      return _buildWhen(
        now.year,
        int.parse(noYear.group(1)!),
        int.parse(noYear.group(2)!),
        noYear.group(3),
        noYear.group(4),
      );
    }
    return null;
  }

  static DateTime? _buildWhen(
    int year,
    int month,
    int day,
    String? hour,
    String? minute,
  ) {
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final h = hour == null ? 23 : int.tryParse(hour) ?? 23;
    final mi = minute == null ? 59 : int.tryParse(minute) ?? 59;
    if (h > 23 || mi > 59) return null;
    return DateTime(year, month, day, h, mi);
  }

  /// 作业 → 待办。
  ///
  /// 只同步「还没交的」（`status == 0`）且「截止时间在今天 0 点之后」的，
  /// 已经过期的不再往待办里塞 —— 那是历史，不是待办。
  static Future<({int added, int removed})> _writeTodos(
    List<ChaoxingTaskItem> items,
  ) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final wanted = <String, Todo>{};
    for (final t in items) {
      if (t.type != 'work') continue;
      if (!t.isPending) continue;
      if (t.title.trim().isEmpty) continue;
      // 有截止时间的：过期就不要了（那是历史，不是待办）。
      // 没有截止时间的（按课程 HTML 页解析不出日期）：放到今天，dueAt 留空，
      // 描述里如实写「学习通没给截止时间」——不要编一个假时间出来。
      final hasDeadline = t.endTime.millisecondsSinceEpoch > 0;
      if (hasDeadline && t.endTime.isBefore(today)) continue;

      final end = hasDeadline
          ? t.endTime
          : DateTime(now.year, now.month, now.day, 23, 59);
      final day = hasDeadline ? DateTime(end.year, end.month, end.day) : today;
      final m = day.month.toString().padLeft(2, '0');
      final d = day.day.toString().padLeft(2, '0');
      final id = '$todoIdPrefix${t.id.isNotEmpty ? t.id : '${t.courseId}_${t.title.hashCode}'}_'
          '${day.year}$m$d';

      if (await isSuppressed(id, day)) continue;

      final hm =
          '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
      wanted[id] = Todo(
        id: id,
        title: '【学习通】${t.title.trim()}',
        description: [
          if (t.courseName.trim().isNotEmpty) t.courseName.trim(),
          hasDeadline
              ? '截止 ${end.month.toString().padLeft(2, '0')}-$d $hm'
              : '学习通没给截止时间',
        ].join(' · '),
        date: day,
        // 时间只写进 dueAt，reminderTime 留空 —— 与课程待办同一套约定：
        // 提前量统一由「待办提醒」的设置决定，别在这里算死一个时刻。
        dueAt: hasDeadline ? end : null,
      );
    }

    final repo = TodoRepository.instance;
    final existing = await repo.getAll();
    final byKey = <String, Todo>{
      for (final t in existing) t.compositeKey: t,
    };

    final toWrite = <Todo>[];
    for (final t in wanted.values) {
      final old = byKey[t.compositeKey];
      // 已划掉的不要被同步覆盖回未完成。
      if (old != null && old.completed) continue;
      toWrite.add(t);
    }
    if (toWrite.isNotEmpty) await repo.addMany(toWrite);

    // 清理：库里属于本服务、但这轮已经不该存在（交过了 / 过期了）的待办。
    var removed = 0;
    for (final t in existing) {
      if (!t.id.startsWith(todoIdPrefix)) continue;
      if (wanted.containsKey(t.id)) continue;
      if (t.completed) continue; // 完成的留给人自己看/删
      if (await isSuppressed(t.id, t.date)) continue;
      await repo.delete(t);
      removed++;
    }
    return (added: toWrite.length, removed: removed);
  }

  /// 考试 → 考试安排。
  ///
  /// ⚠️ 不能直接调 `saveExams(只含学习通)` —— 那个方法会**整体替换所有
  /// `source == server` 的项**，等于把教务同步来的考试全抹掉。
  /// 正确做法：读出全部 → 去掉旧的学习通项 → 拼上新的 → 整体写回。
  static Future<({int written, int skipped})> _writeExams(
    List<ChaoxingTaskItem> items,
  ) async {
    final fresh = <Map<String, dynamic>>[];
    var skipped = 0;
    for (final t in items) {
      if (t.type != 'exam') continue;
      if (t.title.trim().isEmpty) continue;
      final start = t.openTime.millisecondsSinceEpoch > 0 ? t.openTime : t.endTime;
      if (start.millisecondsSinceEpoch <= 0) {
        // 没有日期就没法进「考试安排」——排在一张空日期卡上比没有更糟。
        // 计数带出去，让摘要如实说「N 场没解析出日期」。
        skipped++;
        continue;
      }

      String two(int n) => n.toString().padLeft(2, '0');
      final date =
          '${start.year}-${two(start.month)}-${two(start.day)}';
      fresh.add(<String, dynamic>{
        'id': '$examIdPrefix${t.id.isNotEmpty ? t.id : '${t.courseId}_${t.title.hashCode}'}',
        'name': t.title.trim(),
        'date': date,
        'start_time': '${two(start.hour)}:${two(start.minute)}',
        'end_time': t.endTime.millisecondsSinceEpoch > 0 &&
                t.endTime.isAfter(start)
            ? '${two(t.endTime.hour)}:${two(t.endTime.minute)}'
            : '',
        // 学习通不提供考场与监考老师，留空；考试页对空值本来就有兜底。
        'classroom': '',
        'teacher': '',
        'source': ExamStorage.sourceServer,
      });
    }

    final existing = await ExamStorage.loadExams();
    final keep = existing
        .where((e) =>
            !(e['id'] ?? '').toString().startsWith(examIdPrefix))
        .toList();

    // 新一轮为空时**不写**：见过太多次「接口挂掉 → 返回空 → 空被当有效
    // 结果写回 → 抹掉好东西」。这里课表考试同样适用。
    if (fresh.isEmpty && existing.any((e) =>
        (e['id'] ?? '').toString().startsWith(examIdPrefix))) {
      // 老的学习通考试还在，说明是「这次真没考试了」还是「这次抓挂了」无法
      // 区分 —— 保守起见保留老数据，等下次成功再清。
      return (
        written: existing
            .where((e) => (e['id'] ?? '').toString().startsWith(examIdPrefix))
            .length,
        skipped: skipped,
      );
    }
    if (fresh.isEmpty) return (written: 0, skipped: skipped);

    await ExamStorage.saveExams([...keep, ...fresh]);
    return (written: fresh.length, skipped: skipped);
  }

  static String _summaryOf(
    ({int added, int removed}) todos,
    ({int written, int skipped}) exams,
  ) {
    final added = todos.added;
    final removed = todos.removed;
    final parts = <String>[
      if (added > 0) '新增 $added 条待办',
      if (exams.written > 0) '同步 ${exams.written} 场考试',
      if (removed > 0) '清理 $removed 条已结束',
      if (exams.skipped > 0) '${exams.skipped} 场考试没解析出日期',
    ];
    return parts.isEmpty ? '没有新的作业或考试' : parts.join('，');
  }

  /// 把底层异常翻成一句用户能看懂的话。
  static String _friendly(Object e) {
    final s = e.toString().replaceFirst('Exception: ', '').trim();
    if (s.isEmpty) return '网络异常，请稍后重试';
    if (s.contains('Timeout') || s.contains('timed out')) return '网络超时';
    if (s.contains('SocketException') || s.contains('ClientException')) {
      return '连不上学习通，请检查网络';
    }
    if (s.contains('Unexpected response') ||
        s.contains('unexpected response') ||
        s.contains('非预期')) {
      return '学习通返回了看不懂的内容（可能在做维护）';
    }
    return s.length > 40 ? '${s.substring(0, 40)}…' : s;
  }
}

/// [ChaoxingSyncService.bind] 的结果。
/// 课程列表里的一条（课程 + 班级）。同步只需要这三个字段。
class _ChaoxingCourseRef {
  const _ChaoxingCourseRef({
    required this.courseId,
    required this.classId,
    required this.courseName,
  });

  final String courseId;
  final String classId;
  final String courseName;
}

class ChaoxingBindResult {
  const ChaoxingBindResult(this.ok, this.message);

  final bool ok;
  final String message;
}

/// [ChaoxingSyncService.syncNow] 的结果。
class ChaoxingSyncResult {
  const ChaoxingSyncResult({
    this.addedTodos = 0,
    this.removedTodos = 0,
    this.exams = 0,
    this.summary = '',
    this.error,
  });

  final int addedTodos;
  final int removedTodos;
  final int exams;
  final String summary;

  /// 非空表示这次同步失败，[summary] 无意义。
  final String? error;
}
