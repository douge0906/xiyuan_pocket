// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
//
// Web 端「命名窗口」打开器。
//
// 为什么单独一个文件：`dart:html` 只有浏览器里才有，安卓端引用会编译失败。
// 所以按「条件导入」分家（先例：`lib/pages/tools/campus_map_page.dart`、
// `lib/pages/recharge_webview_page.dart`）。
//
// 为什么不能直接用 `url_launcher`：`url_launcher_web` 的 `launchUrl` 写死了
// `_window.open(url, target, 'noopener,noreferrer')` —— 带 noopener 时浏览器
// **不会复用**同名窗口，每次都是一个新标签页。而 Chrome 一次用户手势只放行
// 1 个新窗口，于是「网关登录 → 预热 → 充值页」三段就开不出来。
// 这里用原生 `window.open(url, name)`（不带 noopener）：同名窗口会被复用，
// 后续导航不算「新开窗口」，不受弹窗拦截。
//
// 为什么绕开 `html.window.open` 的返回值：`dart:html` 的 `open` 声明返回
// `WindowBase`（非空），底层返回 null 时它会包一层 `_DOMWindowCrossFrame`
// 交上来，看不出「被拦截」。所以这里用 `dart:js_util` 直接拿原始 JS 返回值：
// 原生 `window.open` 被弹窗拦截时返回 null。

import 'dart:html' as html;
import 'dart:js_util' as js_util;

/// 在浏览器里打开（或复用）一个命名窗口。
///
/// 返回 true 表示浏览器接受了这个调用；false 表示被拦截（例如被弹窗拦截）。
bool openNamedWindow(String url, String name) {
  try {
    final w = js_util.callMethod<Object?>(html.window, 'open', <Object?>[url, name]);
    return w != null;
  } catch (_) {
    return false;
  }
}
