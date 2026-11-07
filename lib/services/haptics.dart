import 'dart:async';

import 'package:flutter/services.dart';

import 'ui_prefs.dart';

/// 触感反馈（2026-11-03，1.0.9）。
///
/// 🔴 为什么不直接用 [HapticFeedback]：
///   Flutter 的 `HapticFeedback.lightImpact / mediumImpact / heavyImpact`
///   最终都落到 Android 的 `HapticFeedbackConstants.LONG_PRESS`
///   （走 `View.performHapticFeedback`），**强度由系统固定、App 调不了**，
///   而且受系统「触感反馈」总开关支配。三档在真机上手感几乎一样，
///   这就是用户说的「极强太弱」。
///
///   这里改走原生 `Vibrator` + `VibrationEffect.createOneShot(ms, amplitude)`，
///   时长与振幅都由 App 决定，三档才真正拉得开。
///
/// 通道：`xiyuan/haptics`（原生 `MainActivity.performHaptic`）
///   · `tap` → `{level: 1|2|3}`：轻 15ms/80、强 25ms/160、极强 40ms/255
///   · 原生侧把 level clamp 到 0..3，0 = 不震
class Haptics {
  Haptics._();

  static const MethodChannel _channel = MethodChannel('xiyuan/haptics');

  /// 原生调用失败（极少数 ROM 没有 Vibrator、或跑的是未接通道的旧版）
  /// 之后就不再重试，避免每次点击都抛一次 PlatformException。
  /// v1.0.9：改成**带冷却**的单向开关 —— 原来是永久置位，热重启时通道尚未注册
  /// 抛一次 MissingPluginException 就会让整个进程的点击永久不震，只能杀进程恢复。
  static int _brokenAtMs = 0;
  static bool get _broken {
    if (_brokenAtMs == 0) return false;
    return DateTime.now().millisecondsSinceEpoch - _brokenAtMs < 30000;
  }

  /// 上次真正触发振动的时刻，用于去抖（毫秒）。
  static int _lastAtMs = 0;

  /// 点一下。**所有可点击控件都应该走这里**。
  ///
  /// 档位取 [UiPrefs.hapticLevel]（0 关闭 / 1 轻 / 2 强 / 3 极强）。
  static void tap() => fire(UiPrefs.hapticLevel);

  /// 显式指定强度（0..3）。用于「选中档位时立刻试震一下」这类场景。
  ///
  /// 🔴 v1.0.9：80ms 内重复触发一律丢弃。
  ///    指针层（[TapHapticsScope]）已经给每次点击震一次，而
  ///    `general_settings_page._cycleHaptic` 与 `home_page._toggleTodo`
  ///    还会各补一次 `Haptics.fire` → 用户感知是「点一下抖两下」。
  ///    在通道入口统一去抖，比逐个删调用点更可靠（多指同时点也只会震一次）。
  static void fire(int level) {
    if (level <= 0 || _broken) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastAtMs < 80) return;
    _lastAtMs = now;
    // 不 await：触感是「触发即忘」的，等它有返回只会拖慢点击。
    unawaited(_invoke(level));
  }

  static Future<void> _invoke(int level) async {
    try {
      await _channel.invokeMethod<bool>('tap', {'level': level});
    } on MissingPluginException {
      // 通道不存在（非 Android 平台 / 旧构建）→ 冷却 30 秒，不是永久封死。
      _brokenAtMs = DateTime.now().millisecondsSinceEpoch;
    } catch (_) {
      // 其它异常（偶发 PlatformException）不封通道，下次照常尝试。
    }
  }
}
