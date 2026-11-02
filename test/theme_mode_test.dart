import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/services/storage_service.dart';

/// 主题模式持久化的回归测试（2026-10-31 八次自检）。
///
/// 🔴 曾经的 bug：解析持久化的主题模式时，遇到 'system'（跟随系统）会
/// **强制迁移成浅色** —— 但设置页里「跟随系统」是真实存在的选项。
/// 用户选了跟随系统，重启后又变回浅色。
void main() {
  test('🔴 跟随系统模式能被原样读回（不被迁移成浅色）', () {
    expect(StorageService.parseThemeMode('system'), ThemeMode.system);
  });

  test('🔴 浅色 / 深色正常读回', () {
    expect(StorageService.parseThemeMode('light'), ThemeMode.light);
    expect(StorageService.parseThemeMode('dark'), ThemeMode.dark);
  });

  test('🔴 未知值兜底为浅色', () {
    expect(StorageService.parseThemeMode('不存在的值'), ThemeMode.light);
    expect(StorageService.parseThemeMode(null), ThemeMode.light);
  });
}
