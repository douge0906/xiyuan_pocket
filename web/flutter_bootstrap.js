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
//
// 字体回退基址本地化（R5）：
// Flutter 引擎在遇到系统里没有的字符时，会从 fontFallbackBaseUrl 拉
// Noto 回退字体，默认基址是 https://fonts.gstatic.com/s/ —— 跨境线路，
// 国内手机上要么慢要么直接不通，于是中文一直显示成豆腐块。
// 我们把引擎会用到的 725 个分片镜像到本站 api 站（该段已带
// Access-Control-Allow-Origin: * 与一年 immutable 缓存），把基址指过去。
//
// 注意两个坑：
// 1) 引擎是用 fetch() 跨域拉字体的，必须对方返回 CORS 头；
//    本站 api 站的 /static/ 段已经有 Access-Control-Allow-Origin: *。
// 2) 不能用 window.flutterConfiguration —— 它已被引擎标记 deprecated，
//    会打弃用警告，而且与 initializeEngine(config) 互斥（引擎里是断言，
//    同时用直接抛错）。所以走 engineInitializer.initializeEngine(config)。
//
// 基址必须带结尾斜杠：引擎是直接拼 prefix + 'notosanssc/v37/xxx.woff2'。
//
// loader 收到 config 之后，会在主包注入完成后自动调用
// engineInitializer.initializeEngine(config) 并 runApp —— 这正是引擎推荐的
// 新配置通道，不需要我们再包一层 onEntrypointLoaded。
_flutter.loader.load({
  config: {
    fontFallbackBaseUrl: 'https://api.wxxydouge.icu/static/fonts/',
  },
});
