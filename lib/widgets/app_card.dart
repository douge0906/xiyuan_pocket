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
/// 2. 1px 描边走 [AppThemeContext.borderColor]
/// 3. 阴影走 [AppTheme.cardShadow]
///
/// 想改「全 App 卡片长什么样」，改这三处即可。
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    required this.radius,
    this.padding,
    this.margin,
    this.color,
    this.bordered = true,
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

  /// 是否画 1px 描边。默认画；高亮实色块不加线（否则显脏）。
  final bool bordered;

  /// 裁剪方式。需要内容不溢出圆角时传 [Clip.antiAlias]。
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    return Container(
      // 顺序与改造前逐字一致：decoration 在前，child 在后。
      decoration: BoxDecoration(
        color: color ?? context.cardColor,
        borderRadius: BorderRadius.circular(radius),
        border: bordered ? Border.all(color: context.borderColor) : null,
        boxShadow: AppTheme.cardShadow,
      ),
      clipBehavior: clipBehavior,
      padding: padding,
      margin: margin,
      child: child,
    );
  }
}
