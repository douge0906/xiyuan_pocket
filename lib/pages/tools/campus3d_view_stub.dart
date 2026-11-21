import 'package:flutter/material.dart';

/// 非 Web 平台占位：不会走到这里（安卓走 WebView）。
///
/// 存在的意义只是让条件导入在安卓 / iOS 编译时也有一个可解析的符号，
/// 避免引入 `dart:html`（那个库在移动端不可用）。
Widget buildCampus3DWebView({required String assetKey}) {
  return const Center(child: Text('当前平台不支持 3D 地图'));
}
