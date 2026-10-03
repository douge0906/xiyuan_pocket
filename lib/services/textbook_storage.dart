import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 教材本地缓存：把「我的教材」查询结果存进 SharedPreferences，
/// 供下次进入页面先显示（离线也能看），再后台刷新。
class TextbookStorage {
  static const String _kBooks = 'textbook_cache_list';
  static const String _kSemester = 'textbook_cache_semester';
  static const String _kUpdatedAt = 'textbook_cache_updated_at';

  /// 保存教材列表（原样保存查询返回的 Map 列表）。
  /// ⚠️ 空列表不写：抓取失败时若照写会把已有内容覆盖成空。
  static Future<void> saveBooks(
    List<Map<String, dynamic>> books, {
    String? semester,
  }) async {
    if (books.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBooks, jsonEncode(books));
    if (semester != null) await prefs.setString(_kSemester, semester);
    await prefs.setString(_kUpdatedAt, DateTime.now().toIso8601String());
  }

  static Future<List<Map<String, dynamic>>> loadBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kBooks);
    if (raw == null || raw.isEmpty || raw == '[]') return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<String?> loadSemester() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kSemester);
  }

  static Future<DateTime?> loadUpdatedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kUpdatedAt);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }
}
