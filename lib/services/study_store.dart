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

  /// 写缓存。**空档案一律不写；但「未配置」这个结论要写**（见类文档第 2 条）。
  ///
  /// 🔴 此前是 `if (archive.blocks.isEmpty) return false;` —— 把
  /// `StudyArchive.unconfigured()`（blocks 恒空）一起挡掉了，而它正是类文档
  /// 第 2 条明确要缓存的那种档案。后果：教务没配培养方案的学生**永远读不到缓存**，
  /// 每次进页面都要重走一次 10 个节点的 POST + 课表抓取（3~5 秒），还可能撞 CAS 验证码。
  ///
  /// 📐 **2026-11-04 审查 P1 追加**：这个「放行」放得太宽 —— 它无条件覆盖同一个
  ///    key，于是**一次瞬时网络失败就把整份 full 档案抹成 unconfigured**。
  ///    `_buildDegraded` 的三个 unconfigured 分支（`study_client.dart` 的成绩
  ///    401 / 课表空 / 培养方案空）全是**降级态，不是「学生真的没配」的结论**。
  ///    用户 135 门课、GPA 3.62 的档案，抓一次失败就变成「未配置培养方案」，
  ///    而且因为 `updatedAt` 被刷新，`isFresh()`（若有调用方）也会认为这是新数据。
  ///
  ///    修法：内存里已有 full 档案时，**降级态不许覆盖它**，只更新一个「上次
  ///    尝试时间」供下次重试用。真要让用户看到「未配置」，得先清缓存。
  static Future<bool> save(StudyArchive archive) async {
    if (archive.blocks.isEmpty && !archive.isUnconfigured) return false;

    // 降级态 vs 已有完整档案：只允许降级态在「本来就没有完整档案」时落盘。
    if (archive.isUnconfigured) {
      final existing = await load();
      if (existing != null && !existing.isUnconfigured && existing.blocks.isNotEmpty) {
        // 保住旧档案，只记一笔「这次抓取失败过」。
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kLastFailedAt, DateTime.now().toIso8601String());
        return false;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kArchive, jsonEncode(archive.toJson()));
    await prefs.setString(
        _kUpdatedAt, DateTime.now().toIso8601String());
    await prefs.remove(_kLastFailedAt);
    return true;
  }

  static const String _kLastFailedAt = 'study_archive_last_failed_at';

  /// 上次抓取失败的时刻（供页面显示「这是旧数据，刷新失败」）。
  static Future<DateTime?> loadLastFailedAt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kLastFailedAt);
      if (raw == null || raw.isEmpty) return null;
      return DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kArchive);
    await prefs.remove(_kUpdatedAt);
  }
}
