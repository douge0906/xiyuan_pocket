import 'dart:io';

import 'package:flutter/services.dart';

/// 电池优化 / 后台限制的**真实状态**探测。
///
/// 为什么需要它（2026-11-03，用户需求「查找资料看能否主动探知电池优化 /
/// 后台运行是否被关」）：
///   以前这类项在设置页只能写成「需手动确认 · 系统不提供读取」，
///   让用户自己点一下打勾。实际上系统**给了**这几个 API，只是没在
///   Flutter 侧暴露：
///     · `PowerManager.isIgnoringBatteryOptimizations(pkg)` —— 是否已加白
///     · `UsageStatsManager.getAppStandbyBucket()` —— 待机分桶
///     · `ActivityManager.isBackgroundRestricted` —— 「限制后台运行」总闸
///   读不到时（老系统 / OEM 阉割 / 通道异常）仍然退回手动确认，
///   所以对老用户是纯增量、不会变差。
///
/// CLI 与通道见 `MainActivity.kt` 的 `xiyuan/power`。
class PowerStatus {
  static const MethodChannel _channel = MethodChannel('xiyuan/power');

  /// 通道不可用（非 Android / 老版本包）时置 true，不再重复试探。
  static bool _broken = false;

  /// 最近一次读到的原始状态；没读过就是 null。
  static Map<String, Object?>? _last;

  static Map<String, Object?>? get last => _last;

  /// 是否已把本应用加入电池优化白名单（`true` = 不受限制）。
  ///
  /// `null` = 读不到（老系统或通道异常），调用方应退回「手动确认」。
  static Future<bool?> ignoringBatteryOptimizations() async {
    final s = await read();
    final v = s?['ignoringBatteryOptimizations'];
    return v is bool ? v : null;
  }

  /// Android 9+ 的应用待机分桶：10=active / 20=working set / 30=frequent /
  /// 40=rare / 45=restricted。落到 40/45 时后台广播与闹钟都会被大幅限制。
  static Future<int?> standbyBucket() async {
    final s = await read();
    final v = s?['standbyBucket'];
    return v is int ? v : null;
  }

  /// Android 10+ 的「限制后台运行」总闸；开了之后专门吞后台广播。
  static Future<bool?> backgroundRestricted() async {
    final s = await read();
    final v = s?['backgroundRestricted'];
    return v is bool ? v : null;
  }

  /// 本应用是否拿到了「勿扰模式访问权」（`NotificationManager.
  /// isNotificationPolicyAccessGranted`）。
  ///
  /// `null` = 系统读不到（Android 6.0 以下 / 通道异常）。
  /// 这一项值钱的地方在于：**没拿到它，用户在系统里开了勿扰、或者装了
  /// 自动勿扰的第三方 App，本应用完全不知情** —— 提醒到点被系统静音，
  /// 用户只会觉得「又不响了」。
  static Future<bool?> dndAccess() async {
    final s = await read();
    final v = s?['dndAccess'];
    return v is bool ? v : null;
  }

  /// 一次把三项都读出来。读不到返回 null（**不是空 Map**，
  /// 空 Map 会让调用方误以为「每项都读到了，只是都是 null」）。
  static Future<Map<String, Object?>?> read({bool force = false}) async {
    if (_broken) return _last;
    if (!force && _last != null) return _last;
    if (!Platform.isAndroid) {
      _broken = true;
      return null;
    }
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('status');
      if (raw == null) return _last;
      _last = Map<String, Object?>.from(raw);
      return _last;
    } on MissingPluginException {
      // 老版本安装包没有这个通道：合法降级，不是错误。
      _broken = true;
      return null;
    } catch (_) {
      return _last;
    }
  }

  /// 打开系统的电池优化页。
  ///
  /// 原生侧按「能直接弹授权的 REQUEST_IGNORE_BATTERY_OPTIMIZATIONS →
  /// 电池优化列表 → 应用详情」逐个尝试，返回是否成功打开过某一页。
  static Future<bool> openSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('openBatterySettings');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开系统的「勿扰模式访问权」页。返回是否成功跳转。
  static Future<bool> openDndSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('openDndSettings');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 「上课提醒」通知渠道当前是否开着振动。
  ///
  /// `null` = 渠道还没建（用户还没收到过提醒）或系统读不到。
  /// Android 8.0+ 的振动开关**只在通知渠道里**，App 内部没有对应开关，
  /// 所以这一项只提供状态与跳转，不提供值可改的开关。
  static Future<bool?> channelVibration() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<bool>('channelVibration');
    } catch (_) {
      return null;
    }
  }

  /// 打开本应用的系统「通知」设置页（里面有各通知渠道的振动开关）。
  static Future<bool> openNotificationSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('openNotificationSettings');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 把状态翻译成一句人话，供设置页直接显示。
  ///
  /// `null` = 读不到，调用方应显示「需手动确认」。
  static String? describe(
    bool? ignoring, {
    int? bucket,
    bool? restricted,
  }) {
    if (restricted == true) {
      return '系统「限制后台运行」已开启，提醒和小组件都会被吞';
    }
    if (ignoring == false) {
      return '未加入电池优化白名单，深度睡眠时定时提醒可能不响';
    }
    if (bucket != null && bucket >= 40) {
      return '应用被系统判为「不常用」，后台任务会被限制';
    }
    if (ignoring == true) {
      return '已加入白名单，后台不受电池优化限制';
    }
    return null;
  }

  /// 三项里有没有任何一项明显有问题（用于给设置页顶部「待处理」计数）。
  static bool? problem({
    required bool? ignoring,
    int? bucket,
    bool? restricted,
  }) {
    if (ignoring == null && restricted == null && bucket == null) return null;
    if (restricted == true) return true;
    if (ignoring == false) return true;
    if (bucket != null && bucket >= 40) return true;
    return false;
  }
}
