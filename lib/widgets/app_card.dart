import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 统一卡片外壳（2026-11-03，UI P0-2）。
///
/// 为什么要有它：改这个组件之前，全工程有 14 处各写一遍的 `BoxDecoration`
/// 卡片。它们**碰巧长得一样**——靠的是每个人抄的时候都抄对了。
/// 只要有一个人下次少写 `border` 或把 `cardShadow` 换成自己调的
/// `BoxShadow(blurRadius: 8)`，界面就开始「差一点点整齐」，
/// 而这正是看起来不正规的根因。
///
/// ## 🔴 radius 故意不给默认值
///
/// 现有 14 处的圆角**并不统一**：10 处是 [AppTheme.radiusLg]、4 处是
/// [AppTheme.radiusMd]。如果这里给一个默认值，那 10 处会在「无感重构」
/// 的名义下被悄悄改小，而现有测试**一条都发现不了**——它们只测逻辑不测像素。
///
/// 所以强制每处显式写出它现在的值，改完视觉必须零变化。
///
/// ## 内部固定三件事
///
/// 1. 底色走 [AppThemeContext.cardColor]（暗色 `0xFF1E1E1E` / 亮色白）
/// 2. 轮廓走 [AppTheme.cardShadowFor] 里的「隐形描边」（0 模糊 + 扩 1px 的
///    6% 黑）—— **不再用 1px 实线 `Border.all`**
/// 3. 纵深走同一组阴影的另外两层
///
/// 想改「全 App 卡片长什么样」，改 [AppTheme.cardShadowFor] 即可。
///
/// ## 🔴 2026-11-03：阴影代替边框
///
/// 原来这里**同时**画 `Border.all` 和一层 `alpha 0.04` 阴影：浅色下阴影
/// 几乎看不见（等于没纵深），1px `#E5E7EB` 又是一道硬线（等于不轻盈）。
/// 现在改成多层柔和阴影，第一层用 `spreadRadius: 1 / blurRadius: 0` 的
/// 6% 黑做「隐形描边」——观感上仍有一圈边界，但不会在深色模式下变成
/// 一道亮线。`bordered` 因此默认改为 `false`，只有确实需要硬线的高亮态
/// 才显式传 `bordered: true`。
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    required this.radius,
    this.padding,
    this.margin,
    this.color,
    this.bordered = false,
    this.clipBehavior = Clip.none,
  });

  /// 卡片内容。
  final Widget child;

  /// 圆角大小。**必填**，取值应为 [AppTheme.radiusMd] 或 [AppTheme.radiusLg]。
  final double radius;

  /// 内边距。默认不加（由内容自己控制，保持与改造前一致）。
  final EdgeInsetsGeometry? padding;

  /// 外边距。默认不加。
  final EdgeInsetsGeometry? margin;

  /// 底色。默认 [AppThemeContext.cardColor]，只有「高亮态」这类
  /// 需要临时换底色的场景才传。
  final Color? color;

  /// 是否**额外**画 1px 实线描边。默认 `false`（轮廓由阴影的第 1 层
  /// 「隐形描边」提供）；只有高亮实色块这类确实需要硬边的场景才传 true。
  final bool bordered;

  /// 裁剪方式。需要内容不溢出圆角时传 [Clip.antiAlias]。
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Container(
      // 顺序与改造前逐字一致：decoration 在前，child 在后。
      decoration: BoxDecoration(
        color: color ?? context.cardColor,
        borderRadius: BorderRadius.circular(radius),
        // 🔴 2026-11-03：轮廓必须用 `Border.all`（画在盒子**内侧**）。
        //   曾经用 `BoxShadow(spreadRadius: 1)` 做「隐形描边」，它是盒子
        //   外侧扩 1px —— 一旦父级有裁剪（ListView 默认 Clip.hardEdge、
        //   ClipRRect）那 1px 就被切掉，表现为「卡片某几条边突然没有」。
        //   Border.all 永远不会被父级裁掉。
        border: Border.all(
          color: bordered ? context.borderColor : AppTheme.cardStrokeColor(isDark),
        ),
        boxShadow: AppTheme.cardShadowFor(isDark),
      ),
      clipBehavior: clipBehavior,
      padding: padding,
      margin: margin,
      child: child,
    );
  }
}
