import 'web_window_stub.dart'
    if (dart.library.js_util) 'web_window_web.dart';

/// Web 端「充值三段跳」：网关登录 → 预热 → 充值页。
///
/// 为什么要在服务端代跑内网链路之后，还要让浏览器自己去网关登一次：
/// 服务端的 cookie 罐在服务端，浏览器拿不到；浏览器要访问包装后的内网地址，
/// 必须自己持有 `webvpn.cwxu.edu.cn` 这个 origin 的会话 cookie。
/// 实测（`C:/tmp/_probe_gw3.py`）：包装地址即使用 query 带 ticket 也一律
/// 302 → `/login`；只有 `GET /login?cas_login=true&ticket=ST` 这一个端点
/// 会真正处理票据。所以第一段必须是网关登录地址。
///
/// 为什么不用 `url_launcher`：`url_launcher_web` 的 `launchUrl` 写死
/// `_window.open(url, target, 'noopener,noreferrer')` —— 带 noopener 时浏览器
/// **不会复用**同名窗口；而 Chrome 一次用户手势只放行 1 个新窗口，
/// 三段就开不出来。`web_window_web.dart` 用原生 `window.open(url, name)`
/// （不带 noopener）：同名窗口会被复用，后续导航不算「新开窗口」。
///
/// 为什么第一步先开空白页：三段地址都要等服务端返回，第一段拿不到地址之前
/// 就已经离开了用户手势（网络往返会超过浏览器的手势有效期），新窗口会被
/// 弹窗拦截。所以**在用户点击的那一刻**先开一个同名的空白窗口占位，
/// 后面拿到的地址都往这个窗口里导航。
class WebRechargeFlow {
  const WebRechargeFlow._();

  /// 命名窗口名（一卡通与电费共用同一个，避免开一堆标签页）。
  static const String windowName = 'xiyuan_recharge';

  /// 网关登录后停多久再导航下一步。
  ///
  /// 网关登录是 302 链 + `Set-Cookie`，浏览器必须先收到并写入 cookie，
  /// 紧接着把同一个标签页导航走会把那个请求掐掉。所以这里给一段缓冲。
  ///
  /// 2026-11-25：原为 2500ms，手机浏览器上等得人难受；压到 1200ms
  /// （网关 cookie 落盘通常几百毫秒，1200ms 足够）。
  static const Duration gatewaySettle = Duration(milliseconds: 1200);

  /// 预热页到充值页之间的缓冲。
  ///
  /// 2026-11-25：原为 1500ms，压到 800ms。两段缓冲合计 2000ms，
  /// 连同弹窗开销，总等待控制在 2.5 秒内。
  static const Duration warmupSettle = Duration(milliseconds: 800);

  /// 按顺序打开三段地址。
  ///
  /// [gatewayLoginUrl] 网关登录地址（可空 → 跳过第一段）。
  /// [warmupUrl] 预热地址（可空 → 跳过第二段）。
  /// [url] 最终充值页。
  ///
  /// 返回 null = 成功；非 null = 失败原因（中文，直接给用户看）。
  static Future<String?> launch({
    required String url,
    String? gatewayLoginUrl,
    String? warmupUrl,
    void Function(String message)? onProgress,
  }) async {
    if (url.isEmpty) return '充值页准备失败，请稍后重试';

    // ① 先占位：必须在用户手势内开窗，否则会被弹窗拦截。
    onProgress?.call('正在打开充值窗口…');
    if (!openNamedWindow('about:blank', windowName)) {
      // 失败就在这一刻给用户，不要拖到流程末尾。
      return _popupBlocked;
    }

    // ② 网关登录：让浏览器自己拿到网关会话 cookie。
    if (gatewayLoginUrl != null && gatewayLoginUrl.isNotEmpty) {
      onProgress?.call('正在登录校园网网关…');
      if (!openNamedWindow(gatewayLoginUrl, windowName)) return _popupBlocked;
      await Future<void>.delayed(gatewaySettle);
    }

    // ③ 预热：让平台侧把登录态带进浏览器（只有一卡通需要）。
    if (warmupUrl != null && warmupUrl.isNotEmpty) {
      onProgress?.call('正在准备充值页面…');
      if (!openNamedWindow(warmupUrl, windowName)) return _popupBlocked;
      await Future<void>.delayed(warmupSettle);
    }

    // ④ 充值页。
    onProgress?.call('正在打开充值页面…');
    if (!openNamedWindow(url, windowName)) return _popupBlocked;
    return null;
  }

  /// 弹窗被拦截时的统一提示（任何一步失败都立刻返回这句）。
  static const String _popupBlocked =
      '浏览器拦截了新标签页，请允许本页弹出窗口后重试';
}
