import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/study_models.dart';

/// 「我的学业」本地缓存 + 状态推导。
///
/// 三条规矩（本项目踩过的坑，别改）：
///
/// 1. **空档案不写缓存**。教务维护或改版时会返回空结构，照写就会把已有数据抹掉
///    —— 这是本项目最高频的 bug 模式（`ExamStorage.saveExams` 同一个守卫）。
/// 2. **`unconfigured` 可以写**，但只写它自己的标记，不覆盖 [StudyMode.full] 的旧数据。
///    「教务没给你配培养方案」是一个确定的结论，值得缓存，免得每次进来都白等一次网络。
/// 3. **读取永不抛异常**，解析失败返回 null，界面按「没有缓存」处理。
class StudyStore {
  static const String _kArchive = 'study_archive_v1';
  static const String _kUpdatedAt = 'study_archive_at_v1';

  /// 缓存有效期：24 小时。培养方案一周都不会变，没必要每次进页面都抓 10 个板块
  /// （实测一轮 10 次 POST + 135 门课，约 3–5 秒）。
  static const Duration cacheTtl = Duration(hours: 24);

  static Future<StudyArchive?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kArchive);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      return StudyArchive.fromJson(Map<String, dynamic>.from(map));
    } catch (_) {
      return null;
    }
  }

  static Future<DateTime?> loadUpdatedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kUpdatedAt);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// 缓存是否还新鲜。没有缓存 → false（必须去抓）。
  static Future<bool> isFresh() async {
    final at = await loadUpdatedAt();
    if (at == null) return false;
    final a = await load();
    if (a == null) return false;
    return DateTime.now().difference(at) < cacheTtl;
  }

  /// 写缓存。**空档案 / 无板块的正常档案一律不写**（见类文档第 1 条）。
  static Future<bool> save(StudyArchive archive) async {
    if (archive.blocks.isEmpty) return false;
    // 页面结构变了（抛异常那条路）不会走到这里；这里只拦「抓到的确实是空的」。
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kArchive, jsonEncode(archive.toJson()));
    await prefs.setString(
        _kUpdatedAt, DateTime.now().toIso8601String());
    return true;
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kArchive);
    await prefs.remove(_kUpdatedAt);
  }
}
