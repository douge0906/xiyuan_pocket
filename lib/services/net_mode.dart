import 'package:flutter/foundation.dart';

import 'campus/campus_session.dart';
import 'campus_net_monitor.dart';
import 'campus/webvpn.dart';

/// 内网地址（电费/一卡通平台）。故意写死而不引用 [DormService.base] ——
/// 否则本文件与 dorm_service 形成循环 import。地址变了这里和 dorm_service 一起改。
const String _intranetBase = 'http://10.3.100.110';

/// 内网接口该走哪条路。
enum CampusNetMode {
  /// 校园网内，内网直连（最快）
  direct,

  /// 校外，经学校 WebVPN 网关（需 CAS 登录态）
  webvpn,

  /// 都不通：既不在校园网，网关也连不上
  offline,
}

/// 内网可达性探测（2026-10-25）。
///
/// 与 [CampusNetMonitor] 的分工：
///  - CampusNetMonitor 看的是「手机连着校园 WiFi 吗」，用于界面提示；
///  - 本类看的是「内网接口能不能真的调到」，决定请求走直连还是走网关。
///
/// **只探一次**（用户要求：进 App 探一次即可），后续一律复用结果，
/// 需要重新探测时由「手动更新」按钮显式 [probe] 一次。
class NetMode {
  NetMode._();

  static final ValueNotifier<CampusNetMode> notifier =
      ValueNotifier<CampusNetMode>(CampusNetMode.direct);

  static CampusNetMode get current => notifier.value;

  static bool _probed = false;
  static bool _bound = false;

  /// 上次探测成功的时刻。**探测结果必须会过期** ——
  /// 否则启动时在校外探成 webvpn，之后连上校园网也永远走网关
  /// （2026-10-26 反馈「连着校园网还是走 VPN」）。
  static DateTime? _probedAt;

  /// 探测结果的保鲜期。超过这个时长、或回到前台、或查询失败时都会重探。
  static const Duration _ttl = Duration(seconds: 60);

  /// 保证探测结果新鲜（过期就同步重探一次）。
  static Future<void> ensureFresh() async {
    final at = _probedAt;
    if (!_probed || at == null || DateTime.now().difference(at) > _ttl) {
      await probe(force: true);
    }
  }
  static DateTime _lastAutoProbe = DateTime.fromMillisecondsSinceEpoch(0);

  /// 绑定**全局**校园网监听（app 启动时调一次）。
  ///
  /// 之前只有首页卡片监听 WiFi 变化 —— 用户停在别的 tab 时切了网络，
  /// 探测不会重跑，于是「明明连了校园网还在走 WebVPN」（2026-10-26 反馈）。
  static void bind() {
    if (_bound) return;
    _bound = true;
    CampusNetMonitor.instance.status.addListener(() {
      final now = DateTime.now();
      if (now.difference(_lastAutoProbe) < const Duration(seconds: 20)) return;
      _lastAutoProbe = now;
      probe(force: true);
    });
  }

  /// 正在进行的探测。并发调用共享同一个 Future —— 启动时 main 与余额卡片
  /// 可能同时要结果，若各自起一次，后来者会立刻拿到默认值 `direct`（错判）。
  static Future<CampusNetMode>? _inflight;

  /// 是否已经探过（用于界面区分「还在探」和「确实不通」）。
  static bool get probed => _probed;

  /// 探测一次。`force=false` 且已探过时直接返回缓存结果；
  /// 已有探测在跑时返回同一个 Future（不做重复请求，也不会提前返回旧值）。
  static Future<CampusNetMode> probe({bool force = false}) {
    if (_probed && !force) return Future<CampusNetMode>.value(current);
    final running = _inflight;
    if (running != null) return running;
    final fut = _run();
    _inflight = fut;
    return fut;
  }

  static Future<CampusNetMode> _run() async {
    try {
      final mode = await _detect();
      if (mode != current) notifier.value = mode;
      _probed = true;
      _probedAt = DateTime.now();
      return mode;
    } finally {
      _inflight = null;
    }
  }

  /// 能拿到任何 HTTP 响应（2xx/401/302 都算）就认为内网可达。
  static Future<bool> _reachable(String url) async {
    final s = CampusSession(timeout: const Duration(seconds: 3));
    try {
      final r = await s.get(url);
      return r.statusCode > 0 && r.statusCode < 500;
    } catch (_) {
      return false;
    } finally {
      s.close();
    }
  }

  static Future<CampusNetMode> _detect() async {
    // ① 直连判定：请求内网一个**匿名可读**的接口（片区目录）——
    //    能拿到任何 HTTP 响应（2xx/401 都算）就说明本机真能访问内网业务。
    //
    // 🔴 判据只用「有没有 HTTP 响应」，**不看响应内容**：
    //    曾经用 `body.contains('"code":200')` 判，平台 JSON 多一个空格就判失败，
    //    校内用户被误判成校外，所有内网请求被塞进网关，症状完全对不上
    //    （2026-10-26「无卡账号」就是这么来的）。
    // 并发试两个内网接口：任一拿到 HTTP 响应就说明本机在校园网内。
    // 单点探测曾在校园网内偶发失败 → 被误判成校外 → 白绕一圈网关。
    final ok = await Future.wait([
      _reachable('$_intranetBase/charge/feeitem'),
      _reachable('$_intranetBase/berserker-app/frontInfo?synAccessSource=app'),
    ]);
    if (ok.contains(true)) return CampusNetMode.direct;

    // ② 内网不通 → 看网关门能不能摸到（只探可达性，不在这一步登录）
    final gw = CampusSession(timeout: const Duration(seconds: 6));
    try {
      final r = await gw.get('${WebVpn.gateway}/', followRedirects: false);
      // 网关未登录会 302 到登录页；只要不是 5xx/0 就认为路是通的
      if (r.statusCode > 0 && r.statusCode < 500) {
        return CampusNetMode.webvpn;
      }
    } catch (_) {
      // 网关也不通
    } finally {
      gw.close();
    }

    return CampusNetMode.offline;
  }
}
