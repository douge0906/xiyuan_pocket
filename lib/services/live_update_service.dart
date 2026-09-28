import 'package:flutter/services.dart';

/// Android 16 实时更新（Live Updates / OPPO 流体云）状态诊断（v2.3.6）。
///
/// 原生侧全部反射读取，缺 API 时字段为 null（不抛异常）：
/// - supported：系统是否为 Android 16+
/// - promoPermission：Manifest 声明的 POST_PROMOTED_NOTIFICATIONS 权限是否已授予
/// - canPost：系统当前是否允许本应用发布提升通知（用户可在系统设置关闭）
/// - activeCount / promotedCount / promotableCount：活跃通知数 / 已提升数 / 可提升数
/// - lastTitle：最近一条通知的标题（便于确认看到的是新通知）
class LiveUpdateService {
  static const MethodChannel _ch =
      MethodChannel('icu.wxxydouge.wxxy_pocket/live_update');

  static Future<Map<String, dynamic>> status() async {
    try {
      final res = await _ch.invokeMethod<Map<dynamic, dynamic>>('status');
      if (res == null) return {};
      return res.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return {};
    }
  }

  /// 跳转系统「实时更新」设置页；失败回退本应用通知设置。
  static Future<bool> openSettings() async {
    try {
      return await _ch.invokeMethod<bool>('openSettings') ?? false;
    } catch (_) {
      return false;
    }
  }
}
