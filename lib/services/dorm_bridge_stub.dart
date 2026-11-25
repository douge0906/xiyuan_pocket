// 非 Web 环境（安卓 / iOS / 单元测试）的桥接占位实现。
//
// Web 端见 `dorm_bridge_web.dart`（条件导入分家）。
//
// 桥接只在浏览器里成立：它要开一个**顶层命名窗口**、并监听网关 origin 的
// `postMessage`。安卓端查电费走内网直连（`DormService._post`），
// 根本用不到这一层，所以这里只给一个永不生效的兜底。

import 'campus/jwgl_client.dart' show CampusException;

/// 桥接在非 Web 环境不可用。
Never _unsupported() =>
    throw CampusException('网页版不支持该功能，请使用安卓 App');

/// 打开（或复用）命名窗口 —— 非 Web 环境不支持。
bool openBridgeWindow(String url, String name) => _unsupported();

/// 监听网关 origin 的 `postMessage` —— 非 Web 环境不支持。
///
/// 返回值是「取消监听」的函数。
void Function() listenBridgeMessages(
  String origin,
  void Function(Map<String, dynamic>) onMessage,
) =>
    _unsupported();

/// 关闭命名窗口 —— 非 Web 环境不支持。
void closeBridgeWindow(String name) => _unsupported();
