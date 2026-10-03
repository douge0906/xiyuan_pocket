import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';

/// 校园地图（内置图片，纯离线）。
///
/// 图片随包发布（`assets/images/campus_map.jpg`，1920×1004 的校园卫星图）。
/// 交互：双指缩放 + 拖动 + **旋转 90°** + **全屏**。
/// 不联网、不需要定位权限、不调用任何地图 SDK。
class CampusMapPage extends StatefulWidget {
  const CampusMapPage({super.key});

  @override
  State<CampusMapPage> createState() => _CampusMapPageState();
}

class _CampusMapPageState extends State<CampusMapPage> {
  /// 图片原始宽高比（决定 InteractiveViewer 的子控件尺寸，
  /// 子控件与图片等大 → 拖动能严格限制在图片范围内，不会拖出空白）。
  static const double _aspect = 1920 / 1004;

  final TransformationController _tc = TransformationController();
  double _scale = 1.0;

  /// 旋转 90° 的次数（0..3）。图片长边朝上时看着更顺眼，用户可自行切。
  int _quarterTurns = 0;

  /// 全屏：隐藏 AppBar 与系统栏，只留地图。
  bool _fullscreen = false;

  bool get _rotated => _quarterTurns.isOdd;

  @override
  void initState() {
    super.initState();
    _tc.addListener(_onTransform);
  }

  void _onTransform() {
    final s = _tc.value.getMaxScaleOnAxis();
    if ((s - _scale).abs() > 0.01 && mounted) {
      setState(() => _scale = s);
    }
  }

  @override
  void dispose() {
    _tc.removeListener(_onTransform);
    _tc.dispose();
    // 离开页面务必还原系统栏与方向，否则会影响其它页面
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(_portrait);
    super.dispose();
  }

  static const List<DeviceOrientation> _portrait = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ];

  void _reset() {
    _tc.value = Matrix4.identity();
    setState(() {
      _scale = 1.0;
      _quarterTurns = 0;
    });
  }

  void _rotate() {
    setState(() => _quarterTurns = (_quarterTurns + 1) % 4);
    // 旋转后原来的位移/缩放对新朝向没意义，回到初始视角更直观
    _tc.value = Matrix4.identity();
    _scale = 1.0;
  }

  void _toggleFullscreen() {
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    if (next) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      // 全屏时允许横屏，横着看地图更完整
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(_portrait);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? Colors.grey.shade400 : const Color(0xFF6B7280);
    final resetEnabled = _scale > 1.01 || _quarterTurns != 0;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF121212) : AppTheme.backgroundColor,
      appBar: _fullscreen
          ? null
          : AppBar(
              title: const Text('校园地图',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
              foregroundColor: isDark ? Colors.white : AppTheme.primaryColor,
              elevation: 0.5,
              actions: [
                IconButton(
                  onPressed: resetEnabled ? _reset : null,
                  tooltip: '还原',
                  icon: const Icon(Icons.fit_screen_rounded),
                ),
                IconButton(
                  onPressed: _rotate,
                  tooltip: '旋转 90°',
                  icon: const Icon(Icons.rotate_90_degrees_cw_rounded),
                ),
                IconButton(
                  onPressed: _toggleFullscreen,
                  tooltip: '全屏',
                  icon: const Icon(Icons.fullscreen_rounded),
                ),
              ],
            ),
      body: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: InteractiveViewer(
                transformationController: _tc,
                minScale: 1.0,
                maxScale: 6.0,
                // 拖动范围钳在图片内（子控件与图片等大，所以不会露出空白）
                boundaryMargin: EdgeInsets.zero,
                clipBehavior: Clip.hardEdge,
                child: AspectRatio(
                  // 旋转 90° 后宽高互换，外层比例也要跟着换，否则会出现留白
                  aspectRatio: _rotated ? 1 / _aspect : _aspect,
                  child: RotatedBox(
                    quarterTurns: _quarterTurns,
                    child: Image.asset(
                      'assets/images/campus_map.jpg',
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
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
                  '双指缩放 · 拖动 · 右上角可旋转 / 全屏',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: muted),
                ),
              ),
            ),
          ),
          // 全屏时没有 AppBar，用一个悬浮按钮退出
          if (_fullscreen)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 8,
              child: Material(
                color: Colors.black.withOpacity(0.45),
                shape: const CircleBorder(),
                child: IconButton(
                  onPressed: _toggleFullscreen,
                  tooltip: '退出全屏',
                  icon: const Icon(Icons.fullscreen_exit_rounded,
                      color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
