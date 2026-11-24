// 安卓 / iOS 端的「命名窗口」占位实现。
//
// Web 端见 `web_window_web.dart`（条件导入）。
//
// 安卓上不需要这个能力：充值页走 `RechargeWebViewPage` 内嵌 WebView，
// 所以这里只需要一个永不生效的兜底。

/// Web 端之外没有「命名窗口」这个概念，返回 false 表示不支持。
bool openNamedWindow(String url, String name) => false;
