import 'package:flutter/material.dart';

import 'storage_service.dart';

/// 「需要登录才能用」的统一闸门。
///
/// 「登录」= 本机已保存统一认证账号（纯本地，无云端账号）。
///
/// 全 App 的登录校验都走这里，保证**提示文案与交互完全一致**：
/// 未登录时在**屏幕下方弹出一条横条**，而不是让用户进到页面里才发现用不了。
///
/// 使用方式：
/// ```dart
/// if (!await AuthGate.ensureLoggedIn(context)) return;   // 未登录已弹提示，直接中止
/// ```
class AuthGate {
  AuthGate._();

  /// 未登录时的提示文案（**全 App 唯一一处**，改这里即全局生效）。
  static const String loginRequiredMessage = '请登录后才能使用';

  /// 本机是否已登录（存了统一认证账号）。
  static Future<bool> isLoggedIn() async {
    final cfg = await StorageService.loadUserConfig();
    return cfg.username.trim().isNotEmpty;
  }

  /// 校验登录态。
  ///
  /// 已登录 → 返回 true，调用方继续；
  /// 未登录 → 下方弹横条提示并返回 false，调用方**必须中止后续跳转/请求**。
  static Future<bool> ensureLoggedIn(BuildContext context) async {
    if (await isLoggedIn()) return true;
    if (!context.mounted) return false;
    showLoginRequired(context);
    return false;
  }

  /// 仅弹提示（供「已自行判定未登录」的调用方复用，避免重复读配置）。
  static void showLoginRequired(BuildContext context) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text(loginRequiredMessage),
        duration: Duration(seconds: 2),
      ));
  }
}