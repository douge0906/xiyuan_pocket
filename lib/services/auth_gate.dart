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

  /// 未登录横条上「去登录」按钮的文案。
  static const String goLoginLabel = '去登录';

  /// 未登录横条的停留时长。
  ///
  /// 比普通提示长（2s → 4s）：用户看到提示后要判断「怎么登录」，
  /// 时间太短根本来不及点那个「去登录」按钮。
  static const Duration loginRequiredDuration = Duration(seconds: 4);

  /// 本机是否已登录（存了统一认证账号）。
  static Future<bool> isLoggedIn() async {
    final cfg = await StorageService.loadUserConfig();
    return cfg.username.trim().isNotEmpty;
  }

  /// 校验登录态。
  ///
  /// 已登录 → 返回 true，调用方继续；
  /// 未登录 → 下方弹横条提示并返回 false，调用方**必须中止后续跳转/请求**。
  ///
  /// [onGoLogin]（可选）：横条右侧「去登录」按钮的点击回调。
  /// 调用方自己知道登录页在哪时传进来（例如工具入口 → 切到「我的」页），
  /// 没传就只弹提示，不挂按钮。
  static Future<bool> ensureLoggedIn(
    BuildContext context, {
    VoidCallback? onGoLogin,
  }) async {
    if (await isLoggedIn()) return true;
    if (!context.mounted) return false;
    showLoginRequired(context, onGoLogin: onGoLogin);
    return false;
  }

  /// 仅弹提示（供「已自行判定未登录」的调用方复用，避免重复读配置）。
  ///
  /// [onGoLogin]（可选）：给了就把「去登录」按钮挂上，用户点一下直接去登录页。
  static void showLoginRequired(
    BuildContext context, {
    VoidCallback? onGoLogin,
  }) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: const Text(loginRequiredMessage),
        duration: loginRequiredDuration,
        action: onGoLogin == null
            ? null
            : SnackBarAction(label: goLoginLabel, onPressed: onGoLogin),
      ));
  }
}
