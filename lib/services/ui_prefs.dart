import 'package:flutter/material.dart';

/// 界面与显示：全局**字体缩放** + **动效强度** 的运行时设置。
///
/// 设计要点：
///  · 字体缩放走 [MediaQuery.textScaler]，**全局生效**（所有文字一起变大变小），
///    而不是逐个页面改字号；
///  · 动效强度只影响**过渡类动画**（切页、落位），不影响功能逻辑；
///  · 两项都存 SharedPreferences，启动时读取（见 StorageService）。
class UiPrefs {
  UiPrefs._();

  /// 字体缩放：0.85 ~ 1.30。
  static const double minTextScale = 0.85;
  static const double maxTextScale = 1.30;

  /// 动效强度：0（关闭动效）~ 1（完整动效）。
  static const double minMotion = 0.0;
  static const double maxMotion = 1.0;

  static double textScale = 1.0;
  static double motion = 1.0;

  /// 振动反馈开关（关掉后完成待办/滑动等不再震动）。
  static bool haptics = true;

  /// 任一项变化都通知（首页/底栏据此重建）。
  static final ValueNotifier<int> notifier = ValueNotifier<int>(0);

  /// 字体缩放对应的 TextScaler（MediaQuery 用）。
  static TextScaler get textScaler => TextScaler.linear(textScale);

  /// 动效强度为 0 时，页面应跳过过渡动画。
  static bool get motionOff => motion <= 0.01;

  /// 按动效强度缩放一个时长（0 强度 → 几乎瞬时）。
  static Duration dur(Duration base) {
    if (motionOff) return const Duration(milliseconds: 1);
    final ms = (base.inMilliseconds * motion).round();
    return Duration(milliseconds: ms < 1 ? 1 : ms);
  }

  static void setTextScale(double v) {
    final c = v.clamp(minTextScale, maxTextScale);
    if ((textScale - c).abs() < 0.001) return;
    textScale = c;
    notifier.value++;
  }

  static void setHaptics(bool v) {
    if (haptics == v) return;
    haptics = v;
    notifier.value++;
  }

  static void setMotion(double v) {
    final c = v.clamp(minMotion, maxMotion);
    if ((motion - c).abs() < 0.001) return;
    motion = c;
    notifier.value++;
  }
}
