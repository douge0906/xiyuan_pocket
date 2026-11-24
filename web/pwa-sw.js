// 掌上锡院网页版 · 轻量 Service Worker
//
// 定位：**只负责 PWA 安装能力，不接管任何请求**。
//
// 为什么不再用 Flutter 生成的 flutter_service_worker.js：
// 那份脚本会在 install 阶段把整个应用外壳（含 canvaskit 引擎与两个 3.4MB 的
// skwasm）全部预缓存，首访要多下十几 MB；而它的资源键又不带 `/h5/` 前缀，
// 在 /h5/ 下实际接管不到任何资源 —— 代价是真的，收益是零。
//
// 现在：注册在首帧之后（不挡首屏），fetch 事件不调用 respondWith，
// 浏览器照常走网络。Chrome 的「可安装」判定要求存在带 fetch 监听的 SW，
// 这里的监听器就满足这一条，同时不改变任何请求行为。
//
// 想彻底去掉 SW 时，构建加 `--pwa-strategy=none` 并删掉本文件即可。

self.addEventListener('install', function () {
  self.skipWaiting();
});

self.addEventListener('activate', function (event) {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('fetch', function () {
  // 不拦截：交给浏览器默认处理（网络优先，不缓存）。
});
