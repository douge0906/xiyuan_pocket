import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_prefs.dart';
import 'nav_prefs.dart';

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

    return removed;
  }
}
