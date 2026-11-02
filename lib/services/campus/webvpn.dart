import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/block/aes.dart' show AESEngine;

import 'campus_session.dart';
import 'cas_client.dart';

/// 学校 WebVPN（深澜 Srun）—— 校外访问校内接口的通道。
///
/// 原理（2026-10-25 实测网关 + 参考 Wxxy-CampusHub 的 campus-webvpn）：
///   ① 认证：CAS 的 TGT 换 WebVPN 的 ST，回跳后拿到 `wengine_vpn_ticket…` cookie；
///   ② 寻址：目标 host 用 AES-128-CFB 加密成 hex，拼成
///      `https://webvpn.cwxu.edu.cn/{scheme}[-port]/{hexHost}/{path}?{query}`；
///   ③ 网关解密后替你在校内发请求，响应原样回来。
///
/// 与系统级 VPN 的区别：这是**纯 HTTPS**，不装客户端、不要系统权限，App 自己就能做。
class WebVpn {
  WebVpn._();

  static const String gateway = 'https://webvpn.cwxu.edu.cn';

  /// 深澜固定密钥（key 与 IV 相同）。学校未改默认值 —— 2026-10-25 实测网关
  /// 重定向里的 hex 段与社区向量逐字一致（`wxcas.cwxu.edu.cn` 那段）。
  static const String _secret = 'wrdvpnisthebest!';

  /// 网关登录态的 cookie 名（深澜按域名转下划线生成）。
  static const String ticketCookie = 'wengine_vpn_ticketwebvpn_cwxu_edu_cn';

  /// CAS 给 WebVPN 的 service。`?cas_login=true` 是网关要求的，必须原样带上；
  /// 因为它自带 query，追加 ticket 时要用 `&` 而不是 `?`（见 [CasClient.ssoTo]）。
  static String get loginService => '$gateway/login?cas_login=true';

  static final Uint8List _key = Uint8List.fromList(utf8.encode(_secret));

  /// AES-128-CFB128（流式，密文长度 = 明文长度，无 padding）。
  ///
  /// 手写而不直接用 `CFBBlockCipher`：host 通常只有 10~18 字节，不足一块时要
  /// 精确控制「末块不参与反馈」，手写更容易对齐 golden 向量。
  static Uint8List _cfb(Uint8List input, {required bool encrypt}) {
    // 🔴 keystream 恒用 **AES 加密方向**（CFB 的定义）：解密方向只影响
    //    反馈块取密文还是明文，绝不能用 AESEngine 的解密模式 —— 那样算出来的
    //    不是 keystream，解密会得到乱码（2026-10-25 单测踩到）。
    final engine = AESEngine()..init(true, KeyParameter(_key));
    final out = Uint8List(input.length);
    final feedback = Uint8List.fromList(_key); // CFB 的 IV = key
    final keystream = Uint8List(16);
    for (var off = 0; off < input.length; off += 16) {
      engine.processBlock(feedback, 0, keystream, 0);
      final n = input.length - off < 16 ? input.length - off : 16;
      for (var i = 0; i < n; i++) {
        out[off + i] = input[off + i] ^ keystream[i];
      }
      // 反馈块取密文（加密取 out，解密取 input）；末块不足 16 字节补 0，
      // 但此后不再有块，补位不影响结果。
      feedback.fillRange(0, 16, 0);
      if (encrypt) {
        feedback.setRange(0, n, out, off);
      } else {
        feedback.setRange(0, n, input, off);
      }
    }
    return out;
  }

  static String _hex(Uint8List bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  /// 把 host 加密成 `hex(key) + hex(密文)`（前 32 字符恒为 IV 段）。
  static String encryptHost(String host) {
    final ct = _cfb(Uint8List.fromList(utf8.encode(host)), encrypt: true);
    return _hex(_key) + _hex(ct);
  }

  /// 解密 `hex(key)+hex(密文)` 还原 host（调试 / 自测用）。
  static String decryptHost(String hexText) {
    final bytes = Uint8List.fromList([
      for (var i = 0; i + 1 < hexText.length; i += 2)
        int.parse(hexText.substring(i, i + 2), radix: 16),
    ]);
    if (bytes.length <= 16) return '';
    final pt = _cfb(Uint8List.sublistView(bytes, 16), encrypt: false);
    return utf8.decode(pt, allowMalformed: true);
  }

  /// 是否内网地址（只有内网才需要包装，公网一律直连）。
  static bool needsWrap(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return false;
    final h = uri.host.toLowerCase();
    if (h == Uri.parse(gateway).host.toLowerCase()) return false;
    final parts = h.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    return false;
  }

  /// 包装 URL。**幂等**：非内网地址、或已经是网关域 → 原样返回。
  ///
  /// 幂等很重要 —— [CampusSession] 的每一跳重定向都会再调一次。
  static String wrapUrl(String url) {
    if (!needsWrap(url)) return url;
    final uri = Uri.parse(url);
    final scheme = uri.scheme;
    final defaultPort = scheme == 'https' ? 443 : 80;
    final seg =
        (uri.hasPort && uri.port != defaultPort) ? '$scheme-${uri.port}' : scheme;
    final b = StringBuffer('$gateway/$seg/${encryptHost(uri.host)}')
      ..write(uri.path.isEmpty ? '/' : uri.path);
    if (uri.hasQuery) b.write('?${uri.query}');
    if (uri.hasFragment) b.write('#${uri.fragment}');
    return b.toString();
  }

  /// 用 CAS 的 TGT 登录网关（种 cookie → 换 ST → 回跳 → 校验落点）。
  ///
  /// 返回 **null 表示成功**，否则是给界面看的失败原因。
  ///
  /// 为什么要校验落点：网关对无效/过期票据也可能回 200 或 302 到登录页，
  /// 光看「请求成功」会得到假登录态，后续内网请求全被弹回登录页、
  /// 表现为「无卡账号」「请检查网络」这类完全误导的提示（2026-10-26 踩到）。
  static Future<String?> login(CampusSession s, String tgt) async {
    try {
      // ① 先访问网关根，让网关下发初始 ticket cookie（回跳必须带上）。
      //    不跟跳：这里只要 cookie，跟随会白跑一次登录页 HTML。
      await s.get('$gateway/', followRedirects: false);
    } catch (_) {
      return 'VPN不可达';
    }

    // ② TGT 换 WebVPN 的 ST（service 必须是网关注册的原值）
    var st = '';
    try {
      final rSt = await s.postForm(
        '${CasClient.casBase}/lyuapServer/v1/tickets/$tgt',
        {'service': loginService},
        headers: {'Referer': '${CasClient.casBase}/'},
      );
      st = rSt.body.trim();
      final j = CampusSession.tryJson(st);
      if (j != null && j['ticket'] is String) st = j['ticket'] as String;
    } catch (_) {
      return 'VPN换票异常';
    }
    if (!st.startsWith('ST-')) return 'VPN换票失败';

    // ③ 带 ticket 回跳，走完 302 链（登录态靠同名 cookie 覆盖）
    try {
      await s.get(
        '$gateway/login?cas_login=true&ticket=${Uri.encodeComponent(st)}',
      );
    } catch (_) {
      return 'VPN回跳异常';
    }

    // ④ 真实验证：拿一个免鉴权的内网接口试一次。
    //
    // 不能用「最终 URL 里有没有 login 字样」判断 —— 登录成功后的门户落点本身就
    // 可能带 `name=loginTransit`，那样会把成功判成失败（2026-10-26 误报「VPN未登录」
    // 就是这条）。看响应体最实在：网关没放行时回的是登录页 HTML。
    try {
      final probe = await s.get(
        'http://10.3.100.110/berserker-app/frontInfo?synAccessSource=mobile',
      );
      if (probe.body.trimLeft().startsWith('<')) return 'VPN未登录';
    } catch (_) {
      return 'VPN验证失败';
    }
    return null;
  }
}
