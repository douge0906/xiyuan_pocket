import 'dart:convert';

import 'captcha_solver.dart';
import 'campus_session.dart';

/// 无锡学院统一身份认证（CAS）客户端 —— 纯 Dart，客户端直连。
///
/// 流程（与学校前端一致）：
///   1. GET  /lyuapServer/kaptcha        取验证码图片 + uid
///   2. 本地识别验证码（CaptchaSolver）
///   3. POST /lyuapServer/v1/tickets     提交（密码经 RSA 无填充加密）→ 得 TGT
///   4. TGT 换 ST → 访问 service 建立子系统会话（如教务 JSESSIONID）
///
/// 密码**不落盘、不出设备**（除学校 CAS 外不发往任何第三方）。
class CasClient {
  static const String casBase = 'https://wxcas.cwxu.edu.cn';
  static const String jwglBase = 'https://jwgl.cwxu.edu.cn';
  static const String jwglService = '$jwglBase/sso/lyiotlogin';
  /// 融合门户（一卡通余额等在门户侧）
  static const String portalBase = 'https://my.cwxu.edu.cn';
  static const String portalService = '$portalBase/shiro-cas';

  /// CAS RSA 公钥（从学校前端 bundle 提取；硬编码，不动态获取 → 不存在被替换的风险）
  static const String rsaModulusHex =
      '00b5eeb166e069920e80bebd1fea4829d3d1f3216f2aabe79b6c47a3c18dcee5'
      'fd22c2e7ac519cab59198ece036dcf289ea8201e2a0b9ded307f8fb704136eaeb'
      '670286f5ad44e691005ba9ea5af04ada5367cd724b5a26fdb5120cc95b6431604'
      'bd219c6b7d83a6f8f24b43918ea988a76f93c333aa5a20991493d4eb1117e7b1';
  static const int rsaExponent = 65537;

  /// RSA「无填充」加密（与 CAS 前端 P() 函数一致）：
  /// 把密码按字节小端拼成整数 m，算出 m^e mod n，转 16 进制字符串。
  /// Dart 内置 BigInt.modPow 足够，**不需要 pointycastle 等第三方库**。
  static String rawRsaEncrypt(String password) {
    final n = BigInt.parse(rsaModulusHex, radix: 16);
    final e = BigInt.from(rsaExponent);
    final b256 = BigInt.from(256);
    var m = BigInt.zero;
    var base = BigInt.one;
    for (final code in password.codeUnits) {
      m += BigInt.from(code) * base;
      base *= b256;
    }
    return m.modPow(e, n).toRadixString(16);
  }

  /// 登录结果
  static const String ok = 'ok';
  static const String badCredential = 'bad_credential';
  static const String captchaFailed = 'captcha_failed';
  static const String networkError = 'network_error';

  /// CAS 登录并拿到 TGT。返回 (状态, TGT 或 null, 说明)。
  ///
  /// [maxAttempts] 次内未登录成功即放弃；验证码识别失败会自动换一张重试。
  static Future<CasLoginResult> login(
    CampusSession session,
    String username,
    String password, {
    String service = jwglService,
    int maxAttempts = 12,
  }) async {
    final encrypted = rawRsaEncrypt(password);
    var lastNote = '';

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      // 1) 取验证码
      Map<String, dynamic>? cap;
      try {
        final r = await session.get('$casBase/lyuapServer/kaptcha', headers: {
          'Referer': '$casBase/lyuapServer/login',
          'Origin': casBase,
        });
        cap = CampusSession.tryJson(r.body);
      } catch (e) {
        return CasLoginResult(networkError, null, '取验证码失败：$e');
      }
      if (cap == null) {
        lastNote = '验证码接口返回异常';
        continue;
      }

      final uid = (cap['uid'] ?? '').toString();
      final content = (cap['content'] ?? '').toString();
      final b64 =
          content.contains(',') ? content.split(',').last : content;

      // 2) 本地识别
      String? answer;
      try {
        answer = CaptchaSolver.solve(base64Decode(b64));
      } catch (_) {
        answer = null;
      }
      if (answer == null || answer.isEmpty) {
        lastNote = '验证码识别失败，换一张重试';
        continue;
      }

      // 3) 提交登录
      Map<String, dynamic>? j;
      try {
        final r = await session.postForm(
          '$casBase/lyuapServer/v1/tickets',
          {
            'username': username,
            'password': encrypted,
            'service': service,
            'loginType': '',
            'id': uid,
            'code': answer,
            'otpcode': '',
          },
          headers: {
            'Referer': '$casBase/lyuapServer/login',
            'Origin': casBase,
          },
        );
        j = CampusSession.tryJson(r.body);
      } catch (e) {
        lastNote = '提交登录失败：$e';
        continue;
      }
      if (j == null) {
        lastNote = '登录响应不是 JSON';
        continue;
      }

      final tgt = j['tgt'];
      if (tgt is String && tgt.isNotEmpty) {
        return CasLoginResult(ok, tgt, '登录成功（第 ${attempt + 1} 次尝试）');
      }

      final data = j['data'];
      final code = data is Map ? (data['code'] ?? '').toString() : '';
      if (code == 'PASSERROR') {
        return const CasLoginResult(badCredential, null, '学号或密码不正确');
      }
      // CODEFALSE / 其他 → 换验证码重试
      lastNote = code.isEmpty ? '登录未返回票据（$code）' : '验证码错误，重试';
    }
    return CasLoginResult(captchaFailed, null,
        lastNote.isEmpty ? '多次尝试未成功，请稍后重试' : lastNote);
  }

  /// 用 TGT 换 ST 并访问 service，建立子系统会话（cookie 落在 [session] 里）。
  static Future<bool> ssoTo(
    CampusSession session,
    String tgt, {
    String service = jwglService,
  }) async {
    final rSt = await session.postForm(
      '$casBase/lyuapServer/v1/tickets/$tgt',
      {'service': service},
      headers: {'Referer': '$casBase/'},
    );
    var st = rSt.body.trim();
    final j = CampusSession.tryJson(st);
    if (j != null && j['ticket'] is String) st = j['ticket'] as String;
    if (st.isEmpty) return false;

    // 跟随重定向建立会话（手机端 80/443 都通，不像云服务器只有 443）
    await session.get(
      '$service?ticket=$st',
      headers: {'Referer': '$casBase/'},
    );
    return true;
  }

  /// 一步到位：登录 + 建立子系统会话。
  static Future<CasLoginResult> loginAndSso(
    CampusSession session,
    String username,
    String password, {
    String service = jwglService,
    int maxAttempts = 12,
  }) async {
    final res = await login(session, username, password,
        service: service, maxAttempts: maxAttempts);
    if (res.status != ok) return res;
    try {
      final ok2 = await ssoTo(session, res.tgt!, service: service);
      if (!ok2) return const CasLoginResult(networkError, null, '换取子系统票据失败');
    } catch (e) {
      return CasLoginResult(networkError, null, '建立会话失败：$e');
    }
    return res;
  }
}

class CasLoginResult {
  final String status; // ok / bad_credential / captcha_failed / network_error
  final String? tgt;
  final String note;

  const CasLoginResult(this.status, this.tgt, this.note);

  bool get ok => status == CasClient.ok;
}
