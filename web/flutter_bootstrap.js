{{flutter_js}}
{{flutter_build_config}}

// 掌上锡院网页版 · 首屏加载器（自定义版）
//
// 为什么不用 Flutter 的默认模板：
// 默认模板是
//     _flutter.loader.load({ serviceWorkerSettings: { serviceWorkerVersion: ... } });
// loader 会**先 await loadServiceWorker()**（内部超时 4 秒），这一步与引擎/主包
// 下载是串行的，首访要额外等它跑完，白白拖慢首屏。
//
// 更糟的是旧版那个 SW 本身是坏的：它的 RESOURCES 资源键不带 `/h5/` 前缀，
// 而 SW 注册在 `/h5/flutter_service_worker.js`，取键后得到 `h5/main.dart.js`
// 不在清单里，fetch 事件直接放行 —— 它**一个 `/h5/` 资源都接管不到**，
// 只是一直把 5 个 CORE（含 1.6MB 的 main.dart.js）预缓存进浏览器。
// 纯负担、零收益。
//
// 所以这里不传 serviceWorkerSettings：loader 会直接跳过 SW
// （loadServiceWorker 里 `if (!t) return ... Skipping.`）。
// PWA 的「添加到桌面 / 离线」能力没有丢 —— 由 index.html 在**首帧之后**
// 注册一个轻量的 pwa-sw.js 来承担，登记时机不再挡首屏。
//
// 另外：Service Worker 版本号那个占位符在这里不再需要（写上去反而会让
// 构建工具提示 deprecated 的老写法）。
_flutter.loader.load();
