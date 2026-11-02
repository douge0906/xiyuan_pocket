import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import '../../theme/app_theme.dart';


/// 课表背景图**框选**：拖动/缩放定位，确定后按框裁出图片。
///
/// 为什么自己做而不上 `image_cropper`：那是原生插件（Android 走 uCrop），
/// 要改 Manifest、还要赌它在 Flutter 3.24 下能编过；而 `image` 包是纯 Dart，
/// 本项目已在用（验证码识别），拿它按坐标裁剪就够了。
class CourseBgCropPage extends StatefulWidget {
  const CourseBgCropPage({super.key, required this.sourcePath});

  final String sourcePath;

  @override
  State<CourseBgCropPage> createState() => _CourseBgCropPageState();
}

class _CourseBgCropPageState extends State<CourseBgCropPage> {
  final _ctl = TransformationController();
  Size? _imageSize;
  Rect? _cropRect;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bytes = await File(widget.sourcePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      // ⚠️ mounted 必须先判：initState 里直接调本方法（不 await），
      //    用户选完图立刻返回、或图片损坏 decodeImage 返回 null 时，
      //    页面已 dispose，setState 会抛「setState() called after dispose()」。
      if (!mounted) return;
      if (decoded == null) {
        setState(() => _error = '无法解析这张图片');
        return;
      }
      setState(() => _imageSize =
          Size(decoded.width.toDouble(), decoded.height.toDouble()));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// 让图片初始就 cover 裁剪框。
  void _fitInitial(Rect crop) {
    final sz = _imageSize;
    if (sz == null) return;
    // cover：取两个方向缩放比的较大者，保证框内不留白
    final scale = math.max(crop.width / sz.width, crop.height / sz.height);
    final dx = crop.center.dx - sz.width * scale / 2;
    final dy = crop.center.dy - sz.height * scale / 2;
    _ctl.value = Matrix4.identity()
      ..translate(dx, dy)
      ..scale(scale);
  }

  Future<void> _confirm() async {
    final sz = _imageSize;
    final crop = _cropRect;
    if (sz == null || crop == null) return;
    setState(() => _busy = true);
    try {
      // 首帧的 postFrameCallback 可能还没跑到 → 矩阵仍是 identity，
      // 直接反算会得到越界矩形，表现为「点了完成没反应」（2026-10-26）
      if (_ctl.value.isIdentity()) _fitInitial(crop);

      // 视口坐标 → 图片坐标（InteractiveViewer 的逆变换）
      final inv = Matrix4.inverted(_ctl.value);
      final pts = [
        MatrixUtils.transformPoint(inv, crop.topLeft),
        MatrixUtils.transformPoint(inv, crop.topRight),
        MatrixUtils.transformPoint(inv, crop.bottomRight),
        MatrixUtils.transformPoint(inv, crop.bottomLeft),
      ];
      var left = pts.map((p) => p.dx).reduce((a, b) => a < b ? a : b);
      var top = pts.map((p) => p.dy).reduce((a, b) => a < b ? a : b);
      var right = pts.map((p) => p.dx).reduce((a, b) => a > b ? a : b);
      var bottom = pts.map((p) => p.dy).reduce((a, b) => a > b ? a : b);

      // 夹在图片范围内
      left = left.clamp(0.0, sz.width);
      top = top.clamp(0.0, sz.height);
      right = right.clamp(0.0, sz.width);
      bottom = bottom.clamp(0.0, sz.height);

      final w = (right - left).round();
      final h = (bottom - top).round();
      if (w < 8 || h < 8) {
        setState(() {
          _busy = false;
          _error = '选区太小，请放大图片';
        });
        return;
      }

      final bytes = await File(widget.sourcePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw '无法解析这张图片';

      final cropped = img.copyCrop(
        decoded,
        x: left.round(),
        y: top.round(),
        width: w,
        height: h,
      );
      final out = File(
          '${Directory.systemTemp.path}/course_bg_crop_${DateTime.now().millisecondsSinceEpoch}.png');
      await out.writeAsBytes(Uint8List.fromList(img.encodePng(cropped)));

      if (!mounted) return;
      Navigator.of(context).pop(out.path);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final sz = _imageSize;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        toolbarHeight: 48,
        title: const Text('框选背景图',
            style: TextStyle(fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
        leading: TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消', style: TextStyle(color: Colors.white70)),
        ),
        leadingWidth: 64,
        actions: [
          TextButton(
            onPressed: (_busy || sz == null) ? null : _confirm,
            child: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('完成',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70)),
              ),
            )
          : LayoutBuilder(
              builder: (context, box) {
                // 裁剪框：宽度留 24 边距，比例 1:1.3（接近课表区域的纵向比例）
                final w = box.maxWidth - 24;
                final h = (w * 1.3).clamp(120.0, box.maxHeight - 120);
                final crop = Rect.fromCenter(
                  center: Offset(box.maxWidth / 2, box.maxHeight / 2),
                  width: w,
                  height: h,
                );
                if (_cropRect != crop) {
                  _cropRect = crop;
                  if (sz != null) {
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) => _fitInitial(crop));
                  }
                }
                if (sz == null) {
                  return const Center(
                      child: CircularProgressIndicator(color: Colors.white));
                }
                return Stack(
                  children: [
                    Positioned.fill(
                      child: InteractiveViewer(
                        transformationController: _ctl,
                        constrained: false,
                        minScale: 0.2,
                        maxScale: 6,
                        boundaryMargin: const EdgeInsets.all(double.infinity),
                        child: SizedBox(
                          width: sz.width,
                          height: sz.height,
                          child: Image.file(File(widget.sourcePath),
                              fit: BoxFit.fill, gaplessPlayback: true),
                        ),
                      ),
                    ),
                    // 遮罩（框外压暗）
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(painter: _MaskPainter(crop)),
                      ),
                    ),
                    // 框线
                    Positioned.fromRect(
                      rect: crop,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.9),
                                width: 1.5),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 20,
                      child: Text(
                        '双指缩放 · 拖动定位 · 框内即为背景',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: AppTheme.fontSmall,
                            color: Colors.white.withValues(alpha: 0.55)),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

/// 框外压暗。
class _MaskPainter extends CustomPainter {
  _MaskPainter(this.crop);

  final Rect crop;

  @override
  void paint(Canvas canvas, Size size) {
    // evenOdd：外框 + 裁剪框两条子路径 → 中间自动挖空
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(crop);
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.62));
  }

  @override
  bool shouldRepaint(covariant _MaskPainter old) => old.crop != crop;
}
