// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
//
// Web 端「桥接」需要的浏览器动作。
//
// 为什么单独一个文件：`dart:html` / `dart:js_util` 只有浏览器里才有，
// 安卓端引用会编译失败，所以按「条件导入」分家
// （先例：`lib/services/web_window_web.dart` + `web_window_stub.dart`）。
//
// 为什么用 `dart:js_util` 直接调原生 `window.open`：`dart:html` 的 `open`
// 声明返回非空 `WindowBase`，底层返回 null 时它会包一层代理对象交上来，
// 看不出「被弹窗拦截」。原生 `window.open` 被拦截时返回 null —— 这正是
// 我们要判定的两件事（能不能开窗）。

import 'dart:html' as html;
import 'dart:js_util' as js_util;

/// 当前打开的命名窗口的原始句柄（关窗时要用）。
Object? _openHandle;

/// 打开（或复用）命名窗口。
///
/// 返回 false = 浏览器拦截了这个调用（弹窗拦截器）。
bool openBridgeWindow(String url, String name) {
  try {
    final w =
        js_util.callMethod<Object?>(html.window, 'open', <Object?>[url, name]);
    _openHandle = w;
    return w != null;
  } catch (_) {
    _openHandle = null;
    return false;
  }
}

/// 监听来自 [origin] 的 `postMessage`。
///
/// 只放行 origin 完全一致的来源（桥页跑在网关 origin 上），返回取消监听的函数。
void Function() listenBridgeMessages(
  String origin,
  void Function(Map<String, dynamic>) onMessage,
) {
  final sub = html.window.onMessage.listen((event) {
    if (event.origin != origin) return;
    final data = event.data;
    if (data is! Map) return;
    onMessage(data.map((k, v) => MapEntry(k.toString(), v)));
  });
  return () {
    sub.cancel();
  };
}

/// 关闭命名窗口。
///
/// 只在**确实打开过**的时候才关：`window.open('', name)` 在窗口不存在时
/// 会凭空造一个空白窗口（闪一下），所以这里只关自己持有的句柄。
void closeBridgeWindow(String name) {
  final handle = _openHandle;
  _openHandle = null;
  if (handle == null) return;
  try {
    js_util.callMethod<Object?>(handle, 'close', <Object?>[]);
  } catch (_) {
    // 关不掉就算了，用户手动关也一样。
  }
}
