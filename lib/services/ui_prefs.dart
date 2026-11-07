import 'package:flutter/material.dart';

/// 界面与显示：全局**字体缩放** + **动画时长** + **振动强度** 的运行时设置。
///
/// 设计要点：
///  · 字体缩放走 [MediaQuery.textScaler]，**全局生效**（所有文字一起变大变小），
///    而不是逐个页面改字号；
///  · [motion] 只影响**过渡类动画**时长（切页、落位、列表动画），
///    在「界面与显示」页里调，属高级项；
///  · [hapticLevel] 是**振动强度**四档，在设置页「通用设置」里用最右侧
///    一个按钮循环切换；
///  · 三者都存 SharedPreferences，启动时读取（见 StorageService）。
///
/// 🔴 2026-11-03（1.0.9）：原来「动效强度」把动画时长和触感混在一个滑杆里，
///    用户根本看不出「0.35 强度的动效」是什么，也说不清为什么点了只有
///    选中那一刻震一下。现在拆成两件互不相干的事：
///    · 动画时长 = 内部参数，留在「界面与显示」；
///    · 振动强度 = 用户能感知的四档，**所有点击都会震**（见 Haptics.tap）。
class UiPrefs {
  UiPrefs._();

  /// 字体缩放：0.85 ~ 1.30。
  static const double minTextScale = 0.85;
  static const double maxTextScale = 1.30;

  /// 动画时长系数：0（关闭动效）~ 1（完整动效）。
  static const double minMotion = 0.0;
  static const double maxMotion = 1.0;

  static double textScale = 1.0;
  static double motion = 1.0;

  /// 全局字体族（空串 = 跟随系统默认）。
  ///
  /// 2026-11-03：设置页「通用设置 · 字体设置」用。只收录 Android 系统里
  /// **一定存在**的三个族名，避免用户选到不存在的字体后整页回退成默认、
  /// 以为「设置没生效」。
  static String fontFamily = '';

  /// 可选字体：族名 → 显示名。空串是系统默认（各厂商 ROM 的中文字体）。
  static const List<(String, String)> fontChoices = [
    ('', '系统默认'),
    ('serif', '衬线（宋体）'),
    ('monospace', '等宽'),
  ];

  /// 字号档位：以 18 号为标准锚点，`-_18_+` 每点一下就是 1 号。
  static const int baseFontSize = 18;

  /// 当前档位对应的「字号」数字（用于 `-_18_+` 展示）。
  static int get fontSizeNumber => (baseFontSize * textScale).round();

  /// 按字号数字反推缩放比。
  static double scaleForFontSize(int size) => size / baseFontSize;

  /// 振动四档：关闭 / 轻 / 强 / 极强。下标即 [hapticLevel]。
  ///
  /// 强度参数在原生侧 `MainActivity.performHaptic`（见 `lib/services/haptics.dart`）：
  /// 轻 15ms/amplitude 80 · 强 25ms/160 · 极强 40ms/255。
  /// 不用 Flutter 的 `HapticFeedback` —— 它三档最终都是系统的
  /// `LONG_PRESS` 常量，手感一样重不起来，这就是用户说的「极强太弱」。
  static const List<String> hapticChoices = ['关闭', '轻', '强', '极强'];

  /// 当前振动档位（0..3），默认「强」。
  static int hapticLevel = 2;

  /// 任一项变化都通知（首页/底栏据此重建）。
  static final ValueNotifier<int> notifier = ValueNotifier<int>(0);

  /// 字体缩放对应的 TextScaler（MediaQuery 用）。
  static TextScaler get textScaler => TextScaler.linear(textScale);

  /// 动画强度为 0 时，页面应跳过过渡动画。
  static bool get motionOff => motion <= 0.01;

  /// 按动画强度缩放一个时长（0 强度 → 几乎瞬时）。
  static Duration dur(Duration base) {
    if (motionOff) return const Duration(milliseconds: 1);
    final ms = (base.inMilliseconds * motion).round();
    return Duration(milliseconds: ms < 1 ? 1 : ms);
  }

  /// 当前振动档位文案（「关闭」/「轻」/「强」/「极强」）。
  static String get hapticLabel => hapticChoices[hapticLevel];

  /// 振动是否开启（与 `hapticLevel > 0` 等价）。
  static bool get haptics => hapticLevel > 0;

  static void setTextScale(double v) {
    final c = v.clamp(minTextScale, maxTextScale);
    if ((textScale - c).abs() < 0.001) return;
    textScale = c;
    notifier.value++;
  }

  static void setHaptics(bool v) {
    setHapticLevel(v ? (hapticLevel == 0 ? 2 : hapticLevel) : 0);
  }

  static void setFontFamily(String v) {
    if (fontFamily == v) return;
    fontFamily = v;
    notifier.value++;
  }

  /// 按字号数字设置缩放（`-_18_+` 用）。
  static void setFontSizeNumber(int size) {
    final n = size.clamp(14, 24);
    setTextScale(scaleForFontSize(n));
  }

  /// 设置振动档位（0..3）。试震由调用方负责（`Haptics.fire(level)`）。
  static void setHapticLevel(int level) {
    final i = level.clamp(0, hapticChoices.length - 1);
    if (hapticLevel == i) return;
    hapticLevel = i;
    notifier.value++;
  }

  /// 最右侧那个按钮：点一下切到下一档，到「极强」后回到「关闭」。
  ///
  /// 返回切换后的档位，方便调用方立刻试震一下。
  static int cycleHapticLevel() {
    final next = (hapticLevel + 1) % hapticChoices.length;
    setHapticLevel(next);
    return next;
  }

  static void setMotion(double v) {
    final c = v.clamp(minMotion, maxMotion);
    if ((motion - c).abs() < 0.001) return;
    motion = c;
    notifier.value++;
  }
}
