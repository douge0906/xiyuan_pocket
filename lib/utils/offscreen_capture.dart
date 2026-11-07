import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 把一个 Widget 无条件渲染成**完整长图**（不受屏幕高度限制）。
///
/// 为什么需要这个（2026-11-03）：
///   页面里的 `RepaintBoundary` 只能截到「已经被布局并绘制过」的部分。
///   放在 `ListView` 里的内容只有可见的那几屏会被 build + layout + paint，
///   屏幕外的行**根本没进渲染树** —— 所以直接对页面里的 key 调 `toImage()`
///   永远只能拿到一屏。用户报的「导出只有一屏」就是这个原因。
///
/// 做法：在一棵**离屏渲染树**里把整块内容按「宽度固定、高度无界」重新走一遍
/// 完整的 layout / paint，再从我方那层 `RepaintBoundary` 的图层里取图。
/// 这棵树不挂在屏幕上的任何位置，所以不会闪、也不会被裁剪。
///
/// 关键约束（改之前先看这里）：
///   · `RenderView` 的约束**高度必须无界**，否则内容会被压成屏幕高；
///   · 必须手动 `flushLayout → flushCompositingBits → flushPaint`，
///     `toImage()` 在 `debugNeedsPaint == true` 时直接抛；
///   · 取得的 boundary 用**渲染树遍历**而不是 GlobalKey —— 离屏树是我们自己
///     搭的，根节点往下第一个 `RenderRepaintBoundary` 就是包住内容的那个；
///     GlobalKey 在这种手工挂载的树上 `currentContext` 取不到（实测 null）；
///   · 跑在 UI isolate 上，超大图会 OOM，所以按高度自适应 pixelRatio。
class OffscreenCapture {
  OffscreenCapture._();

  /// 渲染并返回 PNG 字节。失败返回 `null`（调用方只提示「导出失败」，不崩）。
  ///
  /// [width] 是逻辑宽度（一般传「屏幕宽 - 页面左右内边距」）。
  /// [pixelRatio] 是上限，实际会按内容高度自动下调，保证成图高度不超过 [maxPixels]。
  static Future<Uint8List?> capture(
    BuildContext context,
    Widget content, {
    required double width,
    double pixelRatio = 3.0,
    double maxPixels = 12000,
  }) async {
    final view = ui.PlatformDispatcher.instance.implicitView;
    if (view == null) return null;

    final buildOwner = BuildOwner(focusManager: FocusManager());
    final pipelineOwner = PipelineOwner();

    // 宽度收紧、高度无界 —— 内容想多高就多高。
    final rootConstraints =
        BoxConstraints(minWidth: width, maxWidth: width, minHeight: 0);
    final renderView = RenderView(
      view: view,
      configuration: ViewConfiguration(
        physicalConstraints: rootConstraints,
        logicalConstraints: rootConstraints,
        devicePixelRatio: 1.0,
      ),
    );
    pipelineOwner.rootNode = renderView;
    renderView.prepareInitialFrame();

    final theme = Theme.of(context);
    final root = RenderObjectToWidgetAdapter<RenderBox>(
      container: renderView,
      child: MediaQuery(
        // 图里不吃屏幕的 textScaler，否则导出的字号会跟着 App 内字号再放一遍。
        data: MediaQueryData(size: Size(width, 0), devicePixelRatio: 1.0),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Theme(
            data: theme,
            child: Material(
              type: MaterialType.transparency,
              child: RepaintBoundary(
                child: SizedBox(width: width, child: content),
              ),
            ),
          ),
        ),
      ),
    ).attachToRenderTree(buildOwner);

    ui.Image? image;
    try {
      buildOwner.buildScope(root);
      buildOwner.finalizeTree();
      pipelineOwner.flushLayout();
      pipelineOwner.flushCompositingBits();
      pipelineOwner.flushPaint();

      final boundary = _findBoundary(renderView);
      if (boundary == null || boundary.size.height <= 0) return null;

      // 自适应倍率：保证成图高度不超过 maxPixels。
      //
      // 📐 2026-11-04 审查 P1：原代码是
      //     `if (height * ratio > maxPixels) ratio = maxPixels / height;`
      //     `if (ratio < 1.0) ratio = 1.0;`
      //   —— 兜底「不低于 1.0」把护栏**彻底废掉了**：内容一旦高到
      //   `maxPixels / height < 1.0`，ratio 被拉回 1.0，成图高度回到 height
      //   本身，护栏等于不存在。而 `toImage()` 受 GPU 最大纹理限制
      //   （常见 8192 / 16384），超限直接抛异常，异常被下面的 assert 内
      //   `debugPrint` 吞掉（release 里连日志都没有）→ 用户只看到「导出失败」。
      //
      //   修法：护栏优先于「不低于 1.0」。ratio 可以小于 1（图会糊一点，
      //   但至少能导出）；同时对「即使压到下限仍超限」提前返回 null 并留
      //   可见日志，而不是让 toImage 抛。
      final height = boundary.size.height;
      final width = boundary.size.width;
      final longSide = height > width ? height : width;
      var ratio = pixelRatio;
      if (height * ratio > maxPixels) ratio = maxPixels / height;
      // 0.15 是下限：再低就完全不可读了，不如让调用方提示「内容太长」。
      const double minRatio = 0.15;
      if (ratio < minRatio) {
        debugPrint('[OffscreenCapture] 内容过高 '
            '(${height.toStringAsFixed(0)}dp)，需要 ratio '
            '${(maxPixels / height).toStringAsFixed(3)} < $minRatio，放弃导出');
        return null;
      }
      // GPU 纹理上限保守护栏：长边不超过 16384 像素。
      if (longSide * ratio > 16384) {
        ratio = 16384 / longSide;
        debugPrint('[OffscreenCapture] 命中纹理上限，ratio 下调至 '
            '${ratio.toStringAsFixed(3)}');
      }

      image = await boundary.toImage(pixelRatio: ratio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (e, st) {
      // release 里也别静默：导出失败是用户能直接看到的结果，
      // 没有日志的话「为什么导不出」永远查不到。
      debugPrint('[OffscreenCapture] 导出失败: $e\n$st');
      return null;
    } finally {
      image?.dispose();
      _unmount(root, buildOwner, pipelineOwner);
    }
  }

  /// 从 `RenderView` 往下找第一个 `RenderRepaintBoundary` —— 就是我们自己包的那层。
  static RenderRepaintBoundary? _findBoundary(RenderObject node) {
    RenderRepaintBoundary? found;
    void visit(RenderObject r) {
      if (found != null) return;
      if (r is RenderRepaintBoundary) {
        found = r;
        return;
      }
      r.visitChildren(visit);
    }

    final child = node is RenderView ? node.child : node;
    if (child != null) visit(child);
    return found;
  }

  /// 拆树：把离屏子树的 child 换成 null，让元素树正常卸载，避免泄漏。
  static void _unmount(
    RenderObjectToWidgetElement<RenderBox> root,
    BuildOwner buildOwner,
    PipelineOwner pipelineOwner,
  ) {
    try {
      final adapter = root.widget as RenderObjectToWidgetAdapter<RenderBox>;
      root.update(RenderObjectToWidgetAdapter<RenderBox>(
        container: adapter.container,
        child: null,
      ));
      buildOwner.buildScope(root);
      buildOwner.finalizeTree();
      pipelineOwner.flushLayout();
    } catch (_) {
      // 拆树失败不影响已经拿到的图片。
    }
  }
}
