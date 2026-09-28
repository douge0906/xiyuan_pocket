import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 全量本地数据清理（v2.4.0）—— 「退出登录」与「恢复出厂」共用。
///
/// 为什么集中一处：本地数据分散在**两处**，分散清理极易漏项
/// （v2.3.x 的退出登录只清了 token 与游客标记，
/// 课表/成绩/待办/已读/订阅/教程标记全残留 —— 用户反馈「退出无效」）。
///
///   ① SharedPreferences —— 配置、全部业务缓存、待办（待办也是 SP，非 SQLite）、引导标记
///   ② FlutterSecureStorage —— 学校密码
class DataWipe {
  DataWipe._();

  /// 固定键：直接按名删除。
  static const List<String> _keys = [
    // ── 账号 / 登录 ──
    'user_showdoc_url', 'user_username', 'user_password',
    'user_remember_password',
    'student_name',
    // 兼容旧键（历史版本遗留）
    'grade_push_showdoc_url', 'grade_push_username',
    'grade_push_password', 'grade_push_remember_password',
    // ── 业务缓存 ──
    'grade_cache_v1',           // 成绩
    'exam_cache_list',          // 考试
    'card_balance_cache_v1',    // 一卡通余额
    'message_read_ids',         // 消息已读集合
    // ── 待办（SP 存储，含备份/损坏快照）──
    'todo_list', 'todo_list_bak',
    // ── 引导 / 教程 ──
    // ── 提醒设置 ──
    'course_reminder_enabled', 'course_reminder_lead_minutes',
    'course_reminder_hang_countdown',
    // ── 外观（恢复出厂要回默认：浅色 + 墨黑）──
    'user_theme_mode', 'user_primary_color',
    // ── 「不再提示」标记 ──
    'disclaimer_dismissed', 'jwgl_notice_dismissed',
  ];

  /// 前缀键：按前缀扫描（这些键是动态拼出来的）。
  static const List<String> _prefixes = [
    'todo_list_corrupt_',     // 待办损坏快照
  ];

  /// 需要清除的安全存储键。
  static const List<String> _secureKeys = [
    'secure_school_password',
    // 旧版本可能残留的登录令牌 —— 留着以便升级安装时清掉，新版本不再产生
    'secure_auth_token',
  ];

  /// 清空全部本地数据。返回被清除的 SP 键数（用于提示，不含敏感值）。
  static Future<int> wipeAll() async {
    int removed = 0;

    // ① SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in _keys) {
        if (prefs.containsKey(k)) {
          await prefs.remove(k);
          removed++;
        }
      }
      // 动态键：遍历现存键名按前缀匹配（避免漏掉不确定数量的键）
      for (final k in prefs.getKeys().toList()) {
        if (_prefixes.any(k.startsWith)) {
          await prefs.remove(k);
          removed++;
        }
      }
    } catch (_) {}

    // ② 安全存储：学校密码 + 登录 token —— 不删的话「退出」后旧凭证仍可用
    try {
      const secure = FlutterSecureStorage();
      for (final k in _secureKeys) {
        await secure.delete(key: k);
        removed++;
      }
    } catch (_) {}

    return removed;
  }
}