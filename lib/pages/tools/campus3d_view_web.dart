// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
//
// Web 端 3D 地图：用 iframe 直接加载打包进 assets 的单文件 HTML。
//
// 为什么单独一个文件：`webview_flutter` 只有 android / ios 实现，Web 端没有；
// 而 Web 端要用到 `dart:html` 与 `dart:ui_web`，这两个库在安卓上不存在。
// 所以按「条件导入」分家：安卓走 WebView（campus3d_view_io.dart），Web 走这里。
//
// HTML 本身是完全自包含的（1.8 MB，无任何外链、无模块 import、无 fetch），
// 所以 file:// 与 assets/ 两种来源都跑得起来。

import 'dart:async';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/empty_state_art.dart';

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

  /// 资源地址（重试用）。
  late final String _url;

  /// 当前 iframe 元素：重试时重新赋 src 让浏览器再拉一次。
  html.IFrameElement? _iframe;

  /// 加载超时兜底：iframe 既不 load 也不 error 时不让用户对着白屏发呆。
  Timer? _loadTimer;

  /// 加载失败（error 事件或超时）→ 显示「地图加载失败，点击重试」。
  bool _failed = false;

  /// 加载超时上限：自包含 HTML 约 1.8 MB，20 秒足够慢网兜底。
  static const Duration _loadTimeout = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    _viewType = 'campus3d-iframe-${_viewSeq++}';
    // 不能直接写 assetKey 当 URL：Web 产物里资源实际落在 <base href>assets/<key>，
    // 部署在子路径（线上是 /h6/）时更是必须走基准地址。
    // ui_web.assetManager.getAssetUrl 会拼上 base href 并补足 URL 编码，
    // 与 Flutter 自己加载 asset 时用的是同一套规则。
    _url = ui_web.assetManager.getAssetUrl(widget.assetKey);
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final iframe = html.IFrameElement()
        ..src = _url
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..allow = 'fullscreen'
        ..setAttribute('allowfullscreen', 'true');
      _iframe = iframe;
      // 监听 load/error：之前这两个事件都没接，资源缺失时就是一片空白，
      // 用户完全不知道是「没加载出来」还是「这页本来就是空的」。
      iframe.onLoad.listen((_) => _handleLoad());
      iframe.onError.listen((_) => _handleError());
      _startTimeout();
      return iframe;
    });
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
    _loadTimer = null;
    super.dispose();
  }

  void _startTimeout() {
    _loadTimer?.cancel();
    _loadTimer = Timer(_loadTimeout, _handleError);
  }

  void _handleLoad() {
    _loadTimer?.cancel();
    _loadTimer = null;
    if (!mounted || !_failed) return;
    setState(() => _failed = false);
  }

  void _handleError() {
    _loadTimer?.cancel();
    _loadTimer = null;
    if (!mounted || _failed) return;
    setState(() => _failed = true);
  }

  /// 重试：重新给 iframe 赋一次 src，浏览器会重新请求资源。
  void _retry() {
    setState(() => _failed = false);
    final iframe = _iframe;
    if (iframe == null) return;
    _startTimeout();
    iframe.src = _url;
  }

  @override
  Widget build(BuildContext context) {
    // 失败提示做成「盖在 iframe 上面」，而不是把 iframe 换掉：
    // 换掉会让 iframe 脱离 DOM，重试时再赋 src 也看不到任何变化。
    final view = HtmlElementView(viewType: _viewType);
    if (!_failed) return view;
    return Stack(
      fit: StackFit.expand,
      children: [
        view,
        Container(
          color: context.scaffoldColor,
          child: Center(
            child: AppEmptyState(
              variant: EmptyArtVariant.offline,
              title: '地图加载失败，点击重试',
              subtitle: '请检查网络连接后重试；若仍失败可返回后重新进入校园地图',
              actionLabel: '重试',
              onAction: _retry,
            ),
          ),
        ),
      ],
    );
  }
}
