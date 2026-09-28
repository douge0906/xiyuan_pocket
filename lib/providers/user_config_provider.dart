import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/storage_service.dart';

/// 用户配置状态：统一认证账密 / 主题 / 最后版本。
///
/// 与 [StorageService] 的关系：**底层持久化一字未改**，本类只是在它之上加一层
/// 可订阅状态。页面用 `ref.watch(userConfigProvider)` 读取，任何写入都会自动
/// 通知到所有订阅者，不必再各自 `loadUserConfig()`。
class UserConfigNotifier extends Notifier<UserConfig> {
  Future<void>? _pending;

  @override
  UserConfig build() {
    _pending = _reload();
    return const UserConfig();
  }

  /// 确保首次加载完成再返回（页面 initState / 使用前调用）
  Future<UserConfig> ensureLoaded() async {
    final p = _pending;
    if (p != null) {
      try {
        await p;
      } catch (_) {
        // 读取失败按默认值处理，不抛给界面
      }
      _pending = null;
    }
    return state;
  }

  Future<void> reload() => _reload();

  Future<void> _reload() async {
    state = await StorageService.loadUserConfig();
  }

  /// 整体写回（唯一写入口）
  Future<void> update(UserConfig config) async {
    await StorageService.saveUserConfig(config);
    state = config;
  }

  /// 局部更新：只改传入的字段，其余保持不变（更常用）
  Future<void> patch({
    String? showdocUrl,
    String? username,
    String? password,
    bool? rememberPassword,
    ThemeMode? themeMode,
  }) =>
      update(state.copyWith(
        showdocUrl: showdocUrl,
        username: username,
        password: password,
        rememberPassword: rememberPassword,
        themeMode: themeMode,
      ));
}

final userConfigProvider =
    NotifierProvider<UserConfigNotifier, UserConfig>(UserConfigNotifier.new);
