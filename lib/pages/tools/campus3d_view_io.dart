// 安卓 / iOS 端 3D 地图：用 WebView 加载打包进 assets 的单文件 HTML。
//
// `webview_flutter` 只有 android / ios 实现，Web 端没有，所以 Web 端走
// `campus3d_view_web.dart` 的 iframe 方案，两边由条件导入分派。
//
// HTML 本身完全自包含（无外链、无模块 import、无 fetch），
// 离线可跑，不联网、不申请定位权限。

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

Widget buildCampus3DWebView({required String assetKey}) {
  return _Campus3DWebView(assetKey: assetKey);
}

class _Campus3DWebView extends StatefulWidget {
  const _Campus3DWebView({required this.assetKey});

  final String assetKey;

  @override
  State<_Campus3DWebView> createState() => _Campus3DWebViewState();
}

class _Campus3DWebViewState extends State<_Campus3DWebView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFEDECEA));
    // loadFlutterAsset 会落到 file:///android_asset/<key>，并自动开启
    // setAllowFileAccess（见 webview_flutter_android 的 loadFlutterAsset 实现）。
    _controller.loadFlutterAsset(widget.assetKey);
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
