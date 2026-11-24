import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
// 3D 地图的双端实现：
//   安卓 / iOS → WebView 加载 assets 里的单文件 HTML（campus3d_view_io.dart）
//   Web       → iframe + HtmlElementView（campus3d_view_web.dart）
//   其它      → 占位提示（campus3d_view_stub.dart）
// 条件导入按 dart.library.js_util 区分 Web（与 Flutter 自身 HtmlElementView 一致），
// 按 dart.library.io 区分移动端。
import 'campus3d_view_stub.dart'
    if (dart.library.js_util) 'campus3d_view_web.dart'
    if (dart.library.io) 'campus3d_view_io.dart';

/// 校园地图（3D 白模，内置离线单文件）。
///
/// 页面内容是 `assets/map/campus3d.html` —— 1.8 MB 的完全自包含单文件，
/// 内联了 45 栋建筑轮廓（量自学校官方总平面图，与地面贴图逐像素对齐）、
/// 4 个校门与明湖／田径场等地物名。双指缩放、拖动、点楼看详情、按分类筛选
/// 都在 HTML 内部实现；不联网、不需要定位权限、不调用任何地图 SDK。
///
/// 移动端做过这些取舍（源码在 `D:/workdsh/campus3d`，改完 `vite build`
/// 再把 `dist/index.html` 拷过来即可）：
/// * 关闭 MSAA（`antialias:false`）、`powerPreference:'high-performance'`；
/// * 像素总量封顶 ~1.1 M，按设备 DPR 自适应；
/// * 阴影贴图 1024²，且 `shadowMap.autoUpdate=false` —— 场景完全静态，
///   每帧重算深度图是纯浪费；只在装配完成后标脏一次；
/// * 完全静止时跳过 `renderer.render`，标签仅在相机移动时每 2 帧排一次；
/// * 射线拾取 hover 60ms / 点击 120ms 节流。
///
/// 「切换方向」在竖屏 / 横屏之间切换，默认竖屏。
class CampusMapPage extends StatefulWidget {
  const CampusMapPage({super.key});

  @override
  State<CampusMapPage> createState() => _CampusMapPageState();
}

class _CampusMapPageState extends State<CampusMapPage> {
  /// 3D 地图资源。WebView 的 loadFlutterAsset 与 Web 的 iframe 用的是同一个
  /// 相对路径（就是 pubspec.yaml 里 assets 段写的那个）。
  static const String _map3dAsset = 'assets/map/campus3d.html';

  static const List<DeviceOrientation> _portrait = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ];
  static const List<DeviceOrientation> _landscapeOrientations = [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  /// 默认竖屏（false）；true 为横屏。
  bool _landscape = false;

  @override
  void initState() {
    super.initState();
    // 进入页面即锁定为默认竖屏，并显示系统栏。
    _applyOrientation();
  }

  @override
  void dispose() {
    // 离开页面务必还原竖屏与系统栏，否则会影响其它页面。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(_portrait);
    super.dispose();
  }

  void _applyOrientation() {
    if (_landscape) {
      SystemChrome.setPreferredOrientations(_landscapeOrientations);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations(_portrait);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void _toggleOrientation() {
    setState(() => _landscape = !_landscape);
    _applyOrientation();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('校园地图',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: context.cardColor,
        actions: [
          IconButton(
            onPressed: _toggleOrientation,
            tooltip: '切换方向',
            icon: Icon(_landscape
                ? Icons.stay_current_portrait_rounded
                : Icons.stay_current_landscape_rounded),
          ),
        ],
      ),
      body: buildCampus3DWebView(assetKey: _map3dAsset),
    );
  }
}
