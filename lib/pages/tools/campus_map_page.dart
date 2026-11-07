import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';

/// 校园地图（内置图片，纯离线）。
///
/// 默认显示手绘版（`assets/images/campus_map_illustrated.png`，1244×1073），
/// 通过右上角「切换地图」可切到卫星图（`assets/images/campus_map.jpg`，1920×1004）。
/// 「切换方向」在竖屏 / 横屏之间切换，默认竖屏。
/// 进入页面时整张地图完整可见（contain，不裁切）；双指放大后可拖动查看细节，
/// 图片文字始终不旋转。不联网、不需要定位权限、不调用任何地图 SDK。
class CampusMapPage extends StatefulWidget {
  const CampusMapPage({super.key});

  @override
  State<CampusMapPage> createState() => _CampusMapPageState();
}

class _CampusMapPageState extends State<CampusMapPage> {
  static const String _illustratedAsset =
      'assets/images/campus_map_illustrated.png';
  static const String _satelliteAsset = 'assets/images/campus_map.jpg';

  static const List<DeviceOrientation> _portrait = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ];
  static const List<DeviceOrientation> _landscapeOrientations = [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  final TransformationController _tc = TransformationController();

  /// 默认显示手绘地图。
  bool _useIllustrated = true;

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
    _tc.dispose();
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
    // 换了方向视口尺寸变了，缩放平移一并复位，保证整张图仍然完整可见。
    _tc.value = Matrix4.identity();
  }

  void _toggleMap() {
    setState(() => _useIllustrated = !_useIllustrated);
    // 换图回到「整张完整显示」的初始状态。
    _tc.value = Matrix4.identity();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_useIllustrated ? '已切换为手绘地图' : '已切换为卫星地图'),
        duration: const Duration(milliseconds: 1500),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final asset = _useIllustrated ? _illustratedAsset : _satelliteAsset;

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
          IconButton(
            onPressed: _toggleMap,
            tooltip: '切换地图',
            icon: Icon(
                _useIllustrated ? Icons.satellite_rounded : Icons.map_rounded),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            // 默认整张图完整显示（contain，不裁切）；放大后可拖动看细节。
            // boundaryMargin 为 0，缩放、拖动都不会露出空白以外的内容。
            child: InteractiveViewer(
              transformationController: _tc,
              minScale: 1.0,
              maxScale: 5.0,
              boundaryMargin: EdgeInsets.zero,
              clipBehavior: Clip.hardEdge,
              child: SizedBox.expand(
                child: Image.asset(
                  asset,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ),
          ),
          // 底部提示
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Text(
                  '双指缩放 · 拖动 · 右上角可切换方向或切换地图',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    color: context.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
