// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
//
// Web 端 3D 地图：用 iframe 直接加载打包进 assets 的单文件 HTML。
//
// 为什么单独一个文件：`webview_flutter` 只有 android / ios 实现，Web 端没有；
// 而 Web 端要用到 `dart:html` 与 `dart:ui_web`，这两个库在安卓上不存在。
// 所以按「条件导入」分家：安卓走 WebView（campus3d_view_io.dart），Web 走这里。
//
// HTML 本身是完全自包含的（796 KB，无任何外链、无模块 import、无 fetch），
// 所以 file:// 与 assets/ 两种来源都跑得起来。

import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

/// 每实例一个 viewType，避免复用时 Flutter 报「viewType 已注册」。
int _viewSeq = 0;

Widget buildCampus3DWebView({required String assetKey}) {
  return _Campus3DIframe(assetKey: assetKey);
}

class _Campus3DIframe extends StatefulWidget {
  const _Campus3DIframe({required this.assetKey});

  final String assetKey;

  @override
  State<_Campus3DIframe> createState() => _Campus3DIframeState();
}

class _Campus3DIframeState extends State<_Campus3DIframe> {
  late final String _viewType;

  @override
  void initState() {
    super.initState();
    _viewType = 'campus3d-iframe-${_viewSeq++}';
    // 不能直接写 assetKey 当 URL：Web 产物里资源实际落在 <base href>assets/<key>，
    // 部署在子路径（线上是 /h6/）时更是必须走基准地址。
    // ui_web.assetManager.getAssetUrl 会拼上 base href 并补足 URL 编码，
    // 与 Flutter 自己加载 asset 时用的是同一套规则。
    final url = ui_web.assetManager.getAssetUrl(widget.assetKey);
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final iframe = html.IFrameElement()
        ..src = url
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..allow = 'fullscreen'
        ..setAttribute('allowfullscreen', 'true');
      return iframe;
    });
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}
