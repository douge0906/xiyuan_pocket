import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';
import '../widgets/hand_drawn_backgrounds.dart';
import 'app_locale.dart';
import 'campus/cas_session_center.dart';
import 'campus/cprint_client.dart';
import 'campus/cprint_scan_storage.dart';
import 'campus/cprint_session_store.dart';
import 'dorm_service.dart';
import 'home_prefs.dart';
import 'nav_prefs.dart';
import 'ui_prefs.dart';

/// 本地数据清理 —— 「退出登录」与「恢复出厂」共用。
///
/// 2026-10-20 重写：
/// 原来只按**固定键名**删，新增的键（导航布局、首页偏好、课表显示设置、
/// 小组件配置、登录失败计数…）全都漏掉 —— 用户反馈「恢复出厂，清了个寂寞」。
/// 现在改成**清空整个 SharedPreferences + 清空安全存储**，
/// 不再依赖一份永远会过期的键名清单。
///
/// 本应用不写磁盘文件（数据全在 SP 与 SecureStorage），所以两步就够。
class DataWipe {
  DataWipe._();

  /// 返回被清除的 SP 键数（仅用于提示，不含敏感值）。
  static Future<int> wipeAll() async {
    int removed = 0;

    try {
      final prefs = await SharedPreferences.getInstance();
      removed = prefs.getKeys().length;
      await prefs.clear();
      await prefs.reload();
    } catch (_) {
      // 清不掉也不能让退出流程卡住
    }

    try {
      const secure = FlutterSecureStorage();
      await secure.deleteAll();
    } catch (_) {}

    // 内存里的静态值也要回默认，否则「清完还是老样子」——
    // 磁盘清了但导航布局、首页板块还挂在内存里，要等杀进程才生效。
    try {
      await HomePrefs.ensureLoaded();
    } catch (_) {}
    try {
      await NavPrefs.reset();
    } catch (_) {}

    // 电费/一卡通的持久会话（含 WebVPN cookie）也要断，否则退出登录后旧会话仍可用
    try {
      DormService.clearToken();
    } catch (_) {}

    // 云打印扫描件：会话票（OSESSIONID）落在安全存储里，换账号后如果还留着，
    // 下一个人进来会看到上一个人的扫描件列表。必须一起清。
    try {
      CprintSessionStore.clear();
      CprintClient.clearSessionOnly();
    } catch (_) {}
    // CAS 的 TGT 也带学号归属，退出时不能留
    try {
      CasSessionCenter.clear();
    } catch (_) {}

    // 已下载的扫描件是这个人的资料，退出后不能留在本机
    try {
      await CprintScanStorage.clear();
    } catch (_) {}

    // 外观 8 项：磁盘清了、内存静态值还挂着，用户点完「清除全部数据」看到的
    // 仍是旧主题色 / 旧背景 / 旧字号，要杀进程才恢复 —— 与导航布局同一类问题。
    // 这里显式写默认值（不重新读盘）：SP 刚清空，读出来也是这些默认值，
    // 但少一次 I/O，也不会因为读失败而静默留在旧外观上。
    try {
      resetAppearanceInMemory();
    } catch (_) {}

    return removed;
  }
}

/// 把**内存里**的外观相关静态值全部回默认。
///
/// 与 `main.dart` 的 `loadAppearance()` 一一对应（那边负责「启动时按盘上设置
/// 恢复」，这边负责「数据清空后按默认值复位」）。两处的默认值必须一致，
/// 一致性由 `test/data_wipe_appearance_test.dart` 守住。
///
/// 不写盘：调用方 [DataWipe.wipeAll] 已经把 SharedPreferences 清空了，
/// 这里再写一遍反而会把刚清掉的键又加回去。
void resetAppearanceInMemory() {
  AppTheme.setMode(ThemeMode.light);
  AppTheme.setPrimary(AppTheme.defaultPrimary);
  AppTheme.setBackground(null);
  AppTheme.setBackgroundDark(null);
  handDrawnBackgroundNotifier.value = HandDrawnBackground.none;
  AppTheme.setRadiusScale(AppTheme.defaultRadiusScale);
  UiPrefs.setTextScale(1.0);
  UiPrefs.setMotion(1.0);
  UiPrefs.setHapticLevel(2);
  UiPrefs.setFontFamily('');
  AppLocale.current = AppLanguage.zh;
  AppLocale.notifier.value++;
}
