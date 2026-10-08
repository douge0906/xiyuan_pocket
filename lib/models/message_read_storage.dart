import 'package:shared_preferences/shared_preferences.dart';

/// 本地已读状态 —— **所有消息列表共用的一套**。
///
/// 键的形态统一为 `<sourceId>:<id>`（即 `Message.key`）。
///
/// ## 为什么要做老键迁移
/// 重构前有两套并存的约定：教务处公告用 `school_<id>`、资讯栏目用
/// `<channelId>_<id>`。如果直接换成新形态而不迁移，老用户升级后**所有条目
/// 都会变回未读** —— 这种"静默数据回归"用户只会感觉"怎么突然全是红点"，
/// 极难自查。
///
/// 迁移策略：**只加不改**。把老键翻译成新键一并写入，老键原样保留
/// （旧页面在迁移完成前仍按老键判断，两边都能正常工作）。
/// 迁移只做一次，用 [_kMigrated] 标记。
class MessageReadStorage {
  static const String _kReadIds = 'message_read_ids';
  static const String _kMigrated = 'message_read_ids_migrated_v1';
  static const String _kUnreadBaseline = 'school_notice_unread_baseline';

  /// 已知的资讯栏目 id —— 用来识别 `<channelId>_<id>` 这种老键。
  static const List<String> _legacyChannelPrefixes = [
    'news',
    'express',
    'xgc',
    'tw',
  ];

  /// 读取已读集合（首次调用会顺带完成老键迁移）。
  static Future<Set<String>> loadReadIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = (prefs.getStringList(_kReadIds) ?? const []).toSet();
      if (prefs.getBool(_kMigrated) == true) return raw;

      final migrated = <String>{...raw};
      for (final k in raw) {
        final nk = migrateLegacyKey(k);
        if (nk != null) migrated.add(nk);
      }
      await prefs.setStringList(_kReadIds, migrated.toList(growable: false));
      await prefs.setBool(_kMigrated, true);
      return migrated;
    } catch (_) {
      return {};
    }
  }

  /// 老键 → 新键。不是老键就返回 `null`。
  ///
  /// 判据：**新键一定带 `:`，老键一定不带** —— 这是最省事也最不会误判的
  /// 一条（比逐个正则匹配 `school_` / 栏目名稳得多，栏目以后还会增加）。
  static String? migrateLegacyKey(String key) {
    if (key.contains(':')) return null;
    if (key.startsWith('school_')) {
      return 'jwc:${key.substring('school_'.length)}';
    }
    for (final p in _legacyChannelPrefixes) {
      final prefix = '${p}_';
      if (key.startsWith(prefix)) {
        return '$p:${key.substring(prefix.length)}';
      }
    }
    return null;
  }

  static Future<void> markRead(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(_kReadIds) ?? []).toSet()..add(key);
    await prefs.setStringList(_kReadIds, set.toList());
  }

  static Future<bool> isRead(String key) async {
    final set = await loadReadIds();
    return set.contains(key);
  }

  /// 取消已读（消息列表「标记未读」用）。
  ///
  /// 注意：教务处的未读还受「发布日期 ≥ 未读基准线」约束 —— 早于基准线的
  /// 旧公告本就不是「新公告」，取消已读后也不会重新出现红点，这是设计如此。
  static Future<void> markUnread(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(_kReadIds) ?? []).toSet()..remove(key);
    await prefs.setStringList(_kReadIds, set.toList());
  }

  static Future<void> markAllRead(List<String> keys) async {
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(_kReadIds) ?? []).toSet()..addAll(keys);
    await prefs.setStringList(_kReadIds, set.toList());
  }

  /// 未读红点基准线（天级字符串）：首次打开消息页时记录当天。
  ///
  /// 「日期不早于基准线」的条目才算新增，未读即标红点 —— 否则用户第一次
  /// 打开就会看到几百条历史公告全是红点。
  static Future<String> loadOrInitUnreadBaseline() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getString(_kUnreadBaseline);
      if (existing != null && existing.isNotEmpty) return existing;
      final today = DateTime.now().toIso8601String().substring(0, 10);
      await prefs.setString(_kUnreadBaseline, today);
      return today;
    } catch (_) {
      return '';
    }
  }
}
