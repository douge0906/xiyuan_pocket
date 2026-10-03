import 'package:shared_preferences/shared_preferences.dart';

/// 本地已读状态管理。
///
/// 用途：给**学校公告**（教务处直抓）与已订阅的校园资讯渠道打「已读」标记，
/// 未读的新公告在列表上显示红点。
///
/// 键名前缀约定：调用方用 `school_<id>` / `<channelId>_<id>` 区分来源，
/// 避免不同栏目的 id 撞车。
class MessageReadStorage {
  static const String _kReadIds = 'message_read_ids';

  static Future<Set<String>> loadReadIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_kReadIds) ?? []).toSet();
  }

  static Future<void> markRead(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(_kReadIds) ?? []).toSet()..add(id);
    await prefs.setStringList(_kReadIds, set.toList());
  }

  static Future<bool> isRead(String id) async {
    final set = await loadReadIds();
    return set.contains(id);
  }

  /// 取消已读（消息列表右滑「标记未读」用）。
  ///
  /// 注意：学校公告的未读还受「发布日期 ≥ 未读基准线」约束 —— 旧公告本就
  /// 不是「新公告」，取消已读后也不会重新出现红点，这是设计如此。
  static Future<void> markUnread(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(_kReadIds) ?? []).toSet()..remove(id);
    await prefs.setStringList(_kReadIds, set.toList());
  }

  static Future<void> markAllRead(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(_kReadIds) ?? []).toSet()..addAll(ids);
    await prefs.setStringList(_kReadIds, set.toList());
  }
}