import 'dart:async';
import 'dart:convert' show base64Decode;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show debugPrint;

import '../net_mode.dart';
import '../storage_service.dart';
import 'campus_session.dart';
import 'cas_client.dart';
import 'cas_session_center.dart';
import 'cprint_models.dart';
import 'cprint_session_store.dart';
import 'jwgl_client.dart' show CampusException;
import 'webvpn.dart';

/// 云打印扫描件的授权阶段。
enum CprintAuthStage {
  /// 有可用会话，可以请求接口了。
  ok,

  /// 本机没存密码（用户关了「记住密码」），需要让用户输一次。
  needPassword,

  /// 账号或密码错误。
  badCredential,

  /// 账号被 CAS 临时锁定，重试只会延长锁定时间。
  locked,

  /// 校外但 WebVPN 网关没打通（或没登录）。
  webvpnDown,

  /// 既不在校园网、网关也不通。
  offline,

  /// 其它失败（网络异常、SSO 链某一步断了）。
  failed,
}

/// 授权结果。`message` 都是**已经写好的中文**，界面直接显示，不要二次加工。
class CprintAuthResult {
  final CprintAuthStage stage;
  final String message;
  final String? trueName;

  const CprintAuthResult(this.stage, this.message, {this.trueName});

  bool get ok => stage == CprintAuthStage.ok;

  static const CprintAuthResult unknown =
      CprintAuthResult(CprintAuthStage.failed, '云打印授权失败，请稍后重试');
}

/// 无锡学院图书馆「云打印」扫描件客户端。
///
/// ## 它解决什么问题
///
/// 打印机旁那台机器扫出来的文件，存在图书馆的云打印系统里，同学只能回宿舍打开
/// 电脑上网页看。网页版在校外还得先登 WebVPN，路径长、在手机上很难用。
/// 这里把整条链搬进 App：**一次授权，之后直接看列表、下载、分享**。
///
/// ## 链路（2026-11-25 用真实账号逐步实测）
///
/// ```
/// ① GET  zzwy:9130/api/client/Auth/SSoPage?backurl=<scanDoc.html>
///         → 返回 authcenter 地址（里面带 targetPageUrl=base64(落地页)）
/// ② GET  kjyy.cwxu.edu.cn/authcenter/toLoginPage?…
///         → 302，Location 里带 service=https://kjyy…/authcenter/doAuth/<32hex>
/// ③ CAS 登录拿 TGT（走 CasSessionCenter，复用已有 TGT 就不登）
/// ④ POST wxcas/lyuapServer/v1/tickets/<TGT> form{service} → ST-…
/// ⑤ GET  …/doAuth/<32hex>?ticket=ST-…
///         → 302 → SSOLogin?uniToken=… → 302 → UniEntry?SessionId=…&Func=…
///         → 302 → 落地页，**这一跳下发 OSESSIONID**
/// ⑥ GET  zzwy:9130/api/client/Auth/Check → code:0 才算真的登录上
/// ```
///
/// ## 三个必须记住的坑
///
/// 1. **`OSESSIONID` 才是凭据**，`SESSIONID` 只是 SSO 过程中的临时 ID。只带
///    后者一定 `code:4`。
/// 2. **`SSoPage` 单独请求也会下发 `OSESSIONID`，但那时是未登录态**。所以
///    「拿到 cookie」≠「登录成功」，必须靠 ⑥ 的 `code` 判。
/// 3. **校外时网关会把 302 里的内网地址改写成包装 URL**，所以逐跳跟随时不能
///    再自己包一次（会变成 `http-9130/http-9130/…`）。这件事由
///    [WebVpn.wrapUrl] 的幂等性保证 —— 它认不出已包装的地址，就不会重复包。
class CprintClient {
  CprintClient._();

  /// 云打印站点（图书馆内网，只有 http:9130；443 不通）。
  static const String host = 'http://zzwy.cwxu.edu.cn:9130';

  /// 网页版的落地页，`backurl` 要的就是它。
  static const String backUrl = '$host/client/new/cprintPc/scanDoc.html';

  static const String _api = '$host/api/client';

  /// 持久会话：**校外时 WebVPN 网关 cookie 也在这里面**，所以不能每次请求都新建。
  /// 这与 [DormService] 踩过的坑是同一个：新建空会话 = 网关认为你没登录。
  static CampusSession? _session;

  static String _username = '';
  static String? _trueName;

  /// 当前登录到的真实姓名（授权成功后才有值）。
  static String? get trueName => _trueName;

  /// 当前用户学号（授权时记下）。
  static String get username => _username;

  /// 已有可用会话（不再打网络）。
  static bool get hasSession => _session != null;

  static CampusSession _newSession() => CampusSession(
        urlRewrite:
            NetMode.current == CampusNetMode.webvpn ? WebVpn.wrapUrl : null,
      );

  /// 授权：能用缓存就用缓存，不能用就跑一次完整 SSO。
  ///
  /// [password] 不传时自己去读本机保存的密码；读出来是空串（用户关了
  /// 「记住密码」）就返回 [CprintAuthStage.needPassword]，由界面弹一次输入框。
  /// [force] 为 true 时忽略 OSESSIONID 缓存，强制重跑 SSO。
  static Future<CprintAuthResult> authorize({
    String? password,
    bool force = false,
  }) async {
    await NetMode.ensureFresh();
    if (NetMode.current == CampusNetMode.offline) {
      return const CprintAuthResult(
        CprintAuthStage.offline,
        '既不在校园网内、也连不上学校 VPN。请连接校园网，或先登录 WebVPN 再试。',
      );
    }

    final cfg = await StorageService.loadUserConfig();
    final sno = cfg.username.trim();
    if (sno.isEmpty) {
      return const CprintAuthResult(
        CprintAuthStage.failed,
        '请先登录掌上锡院，再来使用云打印。',
      );
    }
    _username = sno;

    // ① 先用缓存
    if (!force) {
      final cached = await CprintSessionStore.load(sno);
      if (cached != null && cached.isNotEmpty) {
        final s = _newSession();
        s.importCookies(<String, String>{'OSESSIONID': cached});
        final chk = await _check(s);
        if (chk != null && chk.code == 0) {
          _session = s;
          _trueName = chk.trueName.isEmpty ? null : chk.trueName;
          return CprintAuthResult(CprintAuthStage.ok, '已连接云打印',
              trueName: _trueName);
        }
        // 缓存失效：清掉，走完整链
        await CprintSessionStore.clear();
        s.close();
      }
    }

    final pwd = (password ?? cfg.password).trim();
    if (pwd.isEmpty) {
      return const CprintAuthResult(
        CprintAuthStage.needPassword,
        '需要统一认证密码才能连接云打印。这次输入后会用于本次授权。',
      );
    }

    // ② 完整 SSO。必须**同一个会话对象**跑到底 —— 实测单 cookie 罐可行，
    //    而中途换会话会丢掉网关 cookie，校外直接断。
    final s = _newSession();
    try {
      await CasSessionCenter.restore(username: sno);
      var tgt = await CasSessionCenter.ensureTgt(s,
          username: sno, password: pwd);
      if (tgt == null) {
        return CprintAuthResult(
          CprintAuthStage.badCredential,
          _loginFailureText(),
        );
      }

      // 校外先登网关：SSoPage 本身就在内网，不先过网关根本请求不到。
      if (NetMode.current == CampusNetMode.webvpn) {
        final vpnErr = await WebVpn.login(s, tgt);
        if (vpnErr != null) {
          return CprintAuthResult(
            CprintAuthStage.webvpnDown,
            '连不上学校 VPN（$vpnErr）。请先登录 WebVPN，或连接校园网后重试。',
          );
        }
      }

      // ⑤ 整条 302 链一次跟到底
      final st = await _ssoToCprint(s, tgt, pwd);
      if (st == null || st.isEmpty) {
        s.close();
        return const CprintAuthResult(
          CprintAuthStage.failed,
          '统一认证没有换到云打印的通行票据，请稍后重试。',
        );
      }
      final chk = await _check(s);
      if (chk == null) {
        return const CprintAuthResult(
          CprintAuthStage.failed,
          '云打印授权失败（接口没有返回可识别的数据），请稍后重试。',
        );
      }
      if (chk.code == CprintError.noAccount) {
        return const CprintAuthResult(
          CprintAuthStage.failed,
          '你的账号还没有开通云打印。请到图书馆技术部登记后再试。',
        );
      }
      if (chk.code != 0) {
        return CprintAuthResult(
          CprintAuthStage.failed,
          chk.message.isEmpty ? '云打印授权失败（代码 ${chk.code}）' : chk.message,
        );
      }

      final osession = s.cookies['OSESSIONID'] ?? '';
      if (osession.isEmpty) {
        return const CprintAuthResult(
          CprintAuthStage.failed,
          '授权走完了，但站点没有下发会话，请稍后重试。',
        );
      }
      await CprintSessionStore.save(sno, osession);
      _session = s;
      _trueName = chk.trueName.isEmpty ? null : chk.trueName;
      return CprintAuthResult(CprintAuthStage.ok, '已连接云打印',
          trueName: _trueName);
    } on CampusException catch (e) {
      s.close();
      return CprintAuthResult(CprintAuthStage.failed, e.message);
    } catch (e) {
      s.close();
      // 未预期的异常（SocketException / 解析错误 / 超时）。
      // 原始 `$e` 里通常是 `SocketException: OS Error...` 这种，直接显示
      // 只会让人以为 App 坏了，所以按「网络类 / 其它」分开说。
      debugPrint('[cprint] authorize 未预期异常：$e');
      final net = e is Exception &&
          (e.toString().contains('SocketException') ||
              e.toString().contains('TimeoutException') ||
              e.toString().contains('HandshakeException') ||
              e.toString().contains('ClientException'));
      return CprintAuthResult(
        CprintAuthStage.failed,
        net
            ? '网络不太稳定，云打印没连上，请稍后重试。'
            : '云打印连接失败，请稍后重试。',
      );
    }
  }

  /// 跑 ①→⑤：SSoPage → authcenter → doAuth。返回 ST（成功时非空）。
  ///
  /// 单独抽出来是为了**失败时能重试一次**：TGT 有可能是别处用掉的死票，
  /// 清掉重登一次通常就好，而这比让用户看到「授权失败」体验好得多。
  static Future<String?> _ssoToCprint(
      CampusSession s, String tgt, String password) async {
    // 🔴 `backurl` 是**必填**的。少了它服务端不是「忽略参数」，
    //    而是把整个 /Auth/SSoPage 当成不存在的 action 直接 404：
    //    {"Message":"No HTTP resource was found that matches the request URI ..."}
    //    2026-11-25 实机踩到（vcode42 的「云打印入口返回 404」就是这个），
    //    用 curl 对拍确认：无 backurl → 404，带 backurl → 200 + 授权地址。
    final r = await s.get(
      '$_api/Auth/SSoPage?backurl=${Uri.encodeComponent(backUrl)}',
      headers: const {'Accept': 'application/json, text/plain, */*'},
    );
    if (!r.ok) {
      // 技术细节只进日志。用户看到「云打印入口返回 404」既不懂也帮不上忙，
      // 实机截图里正是这句话（m10676）。
      debugPrint('[cprint] SSoPage HTTP ${r.statusCode}');
      throw CampusException('图书馆云打印这段时间连不上，请过一会儿再试。');
    }
    final j = CampusSession.tryJson(r.body);
    final authUrl = (j?['result'] ?? '').toString();
    if (authUrl.isEmpty) {
      debugPrint('[cprint] SSoPage 无 result：${r.body.length} 字节');
      throw CampusException('图书馆云打印改版了，暂时连不上，请过一会儿再试。');
    }

    // ② 拿 service：Location 里 `service=` 后面那串（urlencoded）
    final step = await s.get(authUrl, followRedirects: false);
    var service = '';
    final loc = step.location ?? '';
    if (loc.isNotEmpty) {
      final q = Uri.tryParse(loc)?.queryParameters ?? const <String, String>{};
      service = (q['service'] ?? '').trim();
    }
    if (service.isEmpty) {
      // 有的部署直接回 200 + 一段 JS 跳转，这里不猜，直接报错
      debugPrint('[cprint] authcenter 无 service：status=${step.statusCode} loc=$loc');
      throw CampusException('学校统一认证没有正常跳转，请稍后重试。');
    }

    // ③④ 只换票不消费
    var st = await CasSessionCenter.stFor(s, service);
    if (st == null) {
      // TGT 废了：重登一次再换
      final again = await CasSessionCenter.ensureTgt(s,
          username: _username, password: password);
      if (again == null) throw CampusException('统一认证票据已失效，请重新授权');
      st = await CasSessionCenter.stFor(s, service);
    }
    if (st == null) throw CampusException('换不到云打印的通行票据');

    // ⑤ doAuth 之后系统会连续 302 三次，最后一跳下发 OSESSIONID。
    //    这里**跟随重定向**，让 CampusSession 逐跳抓 Set-Cookie。
    final sep = service.contains('?') ? '&' : '?';
    final chain = await s.get(
      '$service${sep}ticket=${Uri.encodeComponent(st)}',
      headers: {'Referer': '${CasClient.casBase}/'},
    );
    if (!chain.ok) {
      debugPrint('[cprint] doAuth HTTP ${chain.statusCode}');
      throw CampusException('图书馆云打印登录没走完，请重新授权一次。');
    }
    return st;
  }

  /// 校验会话是否真的有效（`code:0`）。
  ///
  /// 用 GET 而不是站点前端那样的 POST：实测 GET 稳定返回 JSON，而 POST 在
  /// 没有 `Content-Length` 时会被服务端回 411（`dart:io` 发空 body 时不保证带上）。
  static Future<_CheckResult?> _check(CampusSession s) async {
    final r = await s.get(
      '$_api/Auth/Check?timestamp=${DateTime.now().millisecondsSinceEpoch}',
    );
    final j = CampusSession.tryJson(r.body);
    if (j == null) return null;
    final result = j['result'];
    var name = '';
    if (result is Map) {
      name = (result['szTrueName'] ?? result['szLogonName'] ?? '').toString();
    }
    return _CheckResult(
      code: _asInt(j['code']),
      message: (j['message'] ?? '').toString(),
      trueName: name,
    );
  }

  /// 拉一次扫描件列表。会话失效（`code:4`）时**自动重授权并重试一次**。
  static Future<CprintScanResult> list() async {
    final first = await _listOnce();
    if (!first.needReauth) return first;
    final again = await authorize(force: true);
    if (!again.ok) {
      return CprintScanResult(
        errorCode: CprintError.notLoggedIn,
        message: again.message,
        items: const [],
      );
    }
    return _listOnce();
  }

  static Future<CprintScanResult> _listOnce() async {
    final s = _session;
    if (s == null) {
      return const CprintScanResult(
        errorCode: CprintError.notLoggedIn,
        message: '还没有连接云打印',
        items: [],
      );
    }
    try {
      final r = await s.get(
        '$_api/Scan/Get?timestamp=${DateTime.now().millisecondsSinceEpoch}',
      );
      final j = CampusSession.tryJson(r.body);
      if (j == null) {
        return CprintScanResult(
          errorCode: -1,
          message: '云打印返回的内容看不懂，请稍后重试。',
          items: const [],
        );
      }
      final parsed = CprintScanItem.parseList(j);
      // 站点忽略 `sort` 参数，排序必须客户端做（复刻它的 `x_sorttime`）。
      parsed.items.sort((a, b) => b.sortKey.compareTo(a.sortKey));
      return parsed;
    } on CampusException catch (e) {
      return CprintScanResult(
          errorCode: -1, message: e.message, items: const []);
    }
  }

  /// 删除一份扫描件。只能删自己名下、且没被别处标记为过期的。
  static Future<CprintScanResult> delete(String jobId) async {
    final first = await _deleteOnce(jobId);
    if (!first.needReauth) return first;
    final again = await authorize(force: true);
    if (!again.ok) {
      return CprintScanResult(
          errorCode: CprintError.notLoggedIn,
          message: again.message,
          items: const []);
    }
    return _deleteOnce(jobId);
  }

  static Future<CprintScanResult> _deleteOnce(String jobId) async {
    final s = _session;
    if (s == null) {
      return const CprintScanResult(
          errorCode: CprintError.notLoggedIn, message: '还没有连接云打印', items: []);
    }
    try {
      final r = await s.postJson('$_api/Scan/Del', {'dwJobId': jobId});
      final j = CampusSession.tryJson(r.body);
      if (j == null) {
        return const CprintScanResult(
            errorCode: -1, message: '删除失败：云打印没有返回可识别的内容', items: []);
      }
      final code = _asInt(j['code']);
      // 🔴 这个接口失败时 `message` 是空串，不能靠它，只能按 code 映射。
      final msg = code == 0
          ? '已删除'
          : code == CprintError.deleteFailed
              ? '删除失败，请稍后重试'
              : '删除失败（代码 $code）';
      return CprintScanResult(errorCode: code, message: msg, items: const []);
    } on CampusException catch (e) {
      return CprintScanResult(errorCode: -1, message: e.message, items: const []);
    }
  }

  // ───────────────────────── 云端打印任务 ─────────────────────────

  /// 上传一个文件去打印（网页版「云打印」页）。
  ///
  /// ## 三个实测出来的硬约束（2026-11-25，全部用真账号打过）
  ///
  /// 1. **必须 `/api/client/CloudPrint/Upload`**。网页版 JS 里写的是不带 /api 的
  ///    那条（`cp_cprint.js:149`），实测 404 —— 那个 JS 是给另一套部署的。
  /// 2. **PDF 在这台服务器上会挂死**：同一个 URL 传 PDF 会 45~120 秒超时且任务
  ///    不进队列，传 PNG/JPG 秒回。所以界面上要劝用户「PDF 先转成图片」。
  /// 3. **结果是 302 的 Location**：`result.html?code=0&fee=20&message=`，
  ///    `fee` 单位是分。接口从头到尾不返回 JSON。
  ///
  /// [color] true=彩色；[paperId] -1=不指定 / 9=A4 / 8=A3；
  /// [duplex] 1=单面 / 2=双面短边 / 3=双面长边。
  static Future<CprintUploadResult> upload({
    required String fileName,
    required List<int> bytes,
    String? contentType,
    bool color = false,
    int paperId = -1,
    int duplex = 1,
    int copies = 1,
  }) async {
    final first = await _uploadOnce(
      fileName: fileName,
      bytes: bytes,
      contentType: contentType,
      color: color,
      paperId: paperId,
      duplex: duplex,
      copies: copies,
    );
    if (first.code != CprintError.notLoggedIn) return first;
    final again = await authorize(force: true);
    if (!again.ok) return CprintUploadResult(code: -1, feeFen: 0, message: again.message);
    return _uploadOnce(
      fileName: fileName,
      bytes: bytes,
      contentType: contentType,
      color: color,
      paperId: paperId,
      duplex: duplex,
      copies: copies,
    );
  }

  static Future<CprintUploadResult> _uploadOnce({
    required String fileName,
    required List<int> bytes,
    String? contentType,
    required bool color,
    required int paperId,
    required int duplex,
    required int copies,
  }) async {
    final s = _session;
    if (s == null) {
      return CprintUploadResult(
          code: CprintError.notLoggedIn, feeFen: 0, message: '还没有连接云打印');
    }
    try {
      // 字段顺序照抄网页版 FormData 的追加顺序，服务端对顺序没要求，
      // 但真机出问题时能少一个变量。
      final fields = <String, String>{
        'dwColor': color ? '2' : '1',
        'dwPaperId': '$paperId',
        'dwDuplex': '$duplex',
        'dwFrom': '0',
        'dwTo': '0',
        'dwCopies': '${copies < 1 ? 1 : copies}',
        'BackURL': 'result.html',
      };
      final r = await s.postMultipart(
        '$_api/CloudPrint/Upload',
        fields: fields,
        fileField: 'szPath',
        fileName: fileName,
        fileBytes: bytes,
        fileContentType: contentType ?? 'application/octet-stream',
        // 🔴 不能跟随：结果就在 302 的 Location 里，跟过去只剩一个空 HTML。
        followRedirects: false,
      );
      if (r.statusCode == 413) {
        return const CprintUploadResult(
            code: -1, feeFen: 0, message: '文件太大，图书馆云打印不收，请压缩后再试。');
      }
      final loc = r.location ?? '';
      if (loc.isEmpty) {
        debugPrint('[cprint] upload HTTP ${r.statusCode} 无 Location');
        return const CprintUploadResult(
            code: -1, feeFen: 0, message: '上传没有成功，请稍后再试。');
      }
      final parsed = CprintUploadResult.parseLocation(loc);
      if (!parsed.ok) {
        debugPrint('[cprint] upload 失败 code=${parsed.code} msg=${parsed.message}');
        return CprintUploadResult(
          code: parsed.code,
          feeFen: parsed.feeFen,
          // 技术编号只进日志：用户看到「代码 33558534」既不懂也做不了什么。
          message: parsed.message.isEmpty
              ? '上传没有成功，请稍后再试。'
              : parsed.message,
        );
      }
      return parsed;
    } on CampusException catch (ex) {
      return CprintUploadResult(code: -1, feeFen: 0, message: ex.message);
    }
  }

  /// 打印任务列表（网页版「打印文档」页）。会话失效自动重授权一次。
  static Future<CprintJobResult> printJobs() async {
    final first = await _printJobsOnce();
    if (!first.needReauth) return first;
    final again = await authorize(force: true);
    if (!again.ok) {
      return CprintJobResult(errorCode: CprintError.notLoggedIn, message: again.message);
    }
    return _printJobsOnce();
  }

  static Future<CprintJobResult> _printJobsOnce() async {
    final s = _session;
    if (s == null) {
      return const CprintJobResult(errorCode: CprintError.notLoggedIn, message: '还没有连接云打印');
    }
    try {
      final r = await s.get(
        '$_api/PrintJob/Get?timestamp=${DateTime.now().millisecondsSinceEpoch}',
      );
      final j = CampusSession.tryJson(r.body);
      if (j == null) {
        return CprintJobResult(
            errorCode: -1, message: '打印任务返回的内容看不懂，请稍后重试。');
      }
      final code = _asInt(j['code']);
      if (code != 0) {
        return CprintJobResult(
          errorCode: code,
          message: code == CprintError.notLoggedIn
              ? '登录状态已失效，请重新授权'
              : '打印任务读取失败，请稍后重试。',
        );
      }
      return CprintJobResult(errorCode: 0, message: '', jobs: CprintPrintJob.parseList(j));
    } on CampusException catch (ex) {
      return CprintJobResult(errorCode: -1, message: ex.message);
    }
  }

  /// 删一条打印任务。`dwOldJobId` 要一起传（网页版就是传同一个 id）。
  static Future<CprintScanResult> deletePrintJob(String jobId) async {
    final first = await _deletePrintJobOnce(jobId);
    if (!first.needReauth) return first;
    final again = await authorize(force: true);
    if (!again.ok) {
      return CprintScanResult(
          errorCode: CprintError.notLoggedIn, message: again.message, items: const []);
    }
    return _deletePrintJobOnce(jobId);
  }

  static Future<CprintScanResult> _deletePrintJobOnce(String jobId) async {
    final s = _session;
    if (s == null) {
      return const CprintScanResult(
          errorCode: CprintError.notLoggedIn, message: '还没有连接云打印', items: []);
    }
    try {
      final r = await s.postJson(
          '$_api/PrintJob/Del', {'dwJobId': jobId, 'dwOldJobId': jobId});
      final j = CampusSession.tryJson(r.body);
      if (j == null) {
        return const CprintScanResult(
            errorCode: -1, message: '删除失败：云打印没有返回可识别的内容', items: []);
      }
      final code = _asInt(j['code']);
      final raw = '${j['message'] ?? ''}'.trim();
      final msg = code == 0
          ? '已删除'
          : raw.isNotEmpty
              ? raw
              : '删除失败（代码 $code）';
      return CprintScanResult(errorCode: code, message: msg, items: const []);
    } on CampusException catch (ex) {
      return CprintScanResult(errorCode: -1, message: ex.message, items: const []);
    }
  }

  /// 取某一页预览图（PNG 的 base64）。没有预览时返回 null。
  ///
  /// 站点返回 `{"code":0,"result":"iVBORw0KGgo…"}`，界面自己拼
  /// `data:image/png;base64,` 给 `Image.memory` 之前先 base64Decode。
  static Future<Uint8List?> previewPage({
    required String jobId,
    required String createTime,
    int pageNo = 1,
  }) async {
    var bytes = await _previewOnce(jobId: jobId, createTime: createTime, pageNo: pageNo);
    if (bytes != null) return bytes;
    final again = await authorize(force: true);
    if (!again.ok) return null;
    return _previewOnce(jobId: jobId, createTime: createTime, pageNo: pageNo);
  }

  static Future<Uint8List?> _previewOnce({
    required String jobId,
    required String createTime,
    required int pageNo,
  }) async {
    final s = _session;
    if (s == null) return null;
    try {
      final r = await s.get(
        '$_api/PrintJob/PreviewPage?timestamp=${DateTime.now().millisecondsSinceEpoch}'
        '&dwJobId=$jobId&dwCreateTime=$createTime&pageNo=$pageNo',
      );
      final j = CampusSession.tryJson(r.body);
      if (j == null) return null;
      final b64 = '${j['result'] ?? ''}'.trim();
      if (b64.isEmpty) return null;
      return base64Decode(b64);
    } catch (ex) {
      debugPrint('[cprint] preview 失败：$ex');
      return null;
    }
  }

  // ───────────────────────── 打印点 ─────────────────────────

  /// 打印点（网页版「打印点」页）：服务商 + 每台机器的状态。
  static Future<CprintStationResult> stations() async {
    final first = await _stationsOnce();
    if (!first.needReauth) return first;
    final again = await authorize(force: true);
    if (!again.ok) {
      return CprintStationResult(
          errorCode: CprintError.notLoggedIn, message: again.message);
    }
    return _stationsOnce();
  }

  static Future<CprintStationResult> _stationsOnce() async {
    final s = _session;
    if (s == null) {
      return const CprintStationResult(
          errorCode: CprintError.notLoggedIn, message: '还没有连接云打印');
    }
    try {
      final rs = await s.get('$_api/Station/GetSrvList');
      final js = CampusSession.tryJson(rs.body);
      final srvs = js == null ? const <CprintSrv>[] : CprintSrv.parseList(js);
      final rl = await s.get(
        '$_api/Station/GetList?timestamp=${DateTime.now().millisecondsSinceEpoch}',
      );
      final jl = CampusSession.tryJson(rl.body);
      if (jl == null) {
        return CprintStationResult(
            errorCode: -1, message: '打印点返回的内容看不懂，请稍后重试。');
      }
      final code = _asInt(jl['code']);
      if (code != 0) {
        return CprintStationResult(
          errorCode: code,
          message: code == CprintError.notLoggedIn
              ? '登录状态已失效，请重新授权'
              : '打印点读取失败，请稍后重试。',
        );
      }
      return CprintStationResult(
        errorCode: 0,
        message: '',
        srvs: srvs,
        stations: CprintStation.parseList(jl),
      );
    } on CampusException catch (ex) {
      return CprintStationResult(errorCode: -1, message: ex.message);
    }
  }

  // ───────────────────────── 使用记录 ─────────────────────────

  /// 使用记录（网页版「使用记录」页）。
  ///
  /// [type] 1=打印记录 / 4=扫描记录 / 2=复印记录（站点 `data-type` 原值）。
  /// 日期传 `yyyyMMdd`；不传时按网页版默认给「今天往前 1000 天 ~ 今天」。
  static Future<CprintRecordPage> records({
    int type = 1,
    String begin = '',
    String end = '',
    int pageNo = 1,
    int rowCount = 15,
  }) async {
    final first =
        await _recordsOnce(type: type, begin: begin, end: end, pageNo: pageNo, rowCount: rowCount);
    if (!first.needReauth) return first;
    final again = await authorize(force: true);
    if (!again.ok) {
      return CprintRecordPage(
        items: const [],
        pageNo: 1,
        totalPage: 0,
        errorCode: CprintError.notLoggedIn,
        message: again.message,
      );
    }
    return _recordsOnce(type: type, begin: begin, end: end, pageNo: pageNo, rowCount: rowCount);
  }

  static Future<CprintRecordPage> _recordsOnce({
    required int type,
    required String begin,
    required String end,
    required int pageNo,
    required int rowCount,
  }) async {
    final s = _session;
    if (s == null) {
      return const CprintRecordPage(
        items: [],
        pageNo: 1,
        totalPage: 0,
        errorCode: CprintError.notLoggedIn,
        message: '还没有连接云打印',
      );
    }
    try {
      final r = await s.postJson(
        '$_api/Report/DetailPageEx?timestamp=${DateTime.now().millisecondsSinceEpoch}',
        {
          'dwBeginDate': begin,
          'dwEndDate': end,
          'dwType': type,
          'dwPageNo': pageNo,
          'dwRowCount': rowCount,
        },
      );
      final j = CampusSession.tryJson(r.body);
      if (j == null) {
        return const CprintRecordPage(
          items: [],
          pageNo: 1,
          totalPage: 0,
          errorCode: -1,
          message: '使用记录返回的内容看不懂，请稍后重试。',
        );
      }
      final page = CprintRecordPage.parse(j);
      if (page.errorCode != 0) {
        return CprintRecordPage(
          items: const [],
          pageNo: page.pageNo,
          totalPage: page.totalPage,
          errorCode: page.errorCode,
          message: page.errorCode == CprintError.notLoggedIn
              ? '登录状态已失效，请重新授权'
              : '使用记录读取失败，请稍后重试。',
        );
      }
      return page;
    } on CampusException catch (ex) {
      return CprintRecordPage(
        items: const [],
        pageNo: 1,
        totalPage: 0,
        errorCode: -1,
        message: ex.message,
      );
    }
  }

  /// 下载用的会话（下载器拿它发 `Scan/Download`）。
  static CampusSession? get session => _session;

  /// 清空所有状态：退出登录 / 换账号 / 会话彻底失效时调。
  static Future<void> clear() async {
    _session?.close();
    _session = null;
    _trueName = null;
    _username = '';
    await CprintSessionStore.clear();
  }

  /// 只清站点会话、保留身份（换密码重授权时用）。
  static Future<void> clearSessionOnly() async {
    _session?.close();
    _session = null;
    await CprintSessionStore.clear();
  }

  /// CAS 登录失败时给用户看的文案（区分「密码错」和「被锁」）。
  static String _loginFailureText() {
    final st = CasSessionCenter.lastLoginStatus;
    switch (st) {
      case CasClient.badCredential:
        return '统一认证密码不对，请到「我的 → 登录」里改一下密码';
      case CasClient.locked:
        return '账号被临时锁定，请等一会儿再试（别连续重试，会越锁越久）';
      case CasClient.throttled:
        return '登录太频繁，请等 8 秒再试';
      default:
        return '统一认证登录失败，请检查网络后重试';
    }
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}') ?? 0;
  }
}

/// `Auth/Check` 的解析结果（内部用，不暴露给页面）。
class _CheckResult {
  final int code;
  final String message;
  final String trueName;

  const _CheckResult({
    required this.code,
    required this.message,
    required this.trueName,
  });
}
