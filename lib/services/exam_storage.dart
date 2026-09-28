import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 考试本地缓存：把「考试查询」结果存到 SharedPreferences，
/// 供首页「今日概览」计算最近一场考试的倒计时（离线可用，无需每次联网）。
class ExamStorage {
  static const String _kExams = 'exam_cache_list';
  static const String _kSemester = 'exam_cache_semester';
  static const String _kUpdatedAt = 'exam_cache_updated_at';

  /// 保存考试列表（原样保存查询返回的 Map 列表）。
  ///
  /// ⚠️ **空列表不写**：教务维护或改版时，`JwglClient.queryExams` 会**返回空而不是抛错**
  /// （见其 `emptyMeansEmpty: true`），页面若照写就会把已有缓存清空 ——
  /// 这正是本项目最高频的 bug 模式（「失败 → 静默返回空 → 空被当有效结果写回 → 抹掉好东西」）。
  /// 与 `TextbookStorage.saveBooks` 保持同一守卫。
  static Future<void> saveExams(
    List<Map<String, dynamic>> exams, {
    String? semester,
  }) async {
    if (exams.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kExams, jsonEncode(exams));
    if (semester != null) await prefs.setString(_kSemester, semester);
    await prefs.setString(_kUpdatedAt, DateTime.now().toIso8601String());
  }

  /// 读取缓存的考试列表
  static Future<List<Map<String, dynamic>>> loadExams() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kExams);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (_) {
      return [];
    }
  }

  /// 读取缓存学期
  static Future<String?> loadSemester() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kSemester);
  }

  /// 读取缓存更新时间（用于提示「上次更新于…」）
  static Future<DateTime?> loadUpdatedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kUpdatedAt);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// 找出「从今天起最近的一场考试」，没有则返回 null。
  /// 依赖考试项的 date 字段（格式如 2026-06-15）。
  static Future<ExamCountdown?> nextExam() async {
    final exams = await loadExams();
    if (exams.isEmpty) return null;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    ExamCountdown? best;
    for (final e in exams) {
      final date = _parseDate(e['date'] as String?);
      if (date == null) continue;
      if (date.isBefore(today)) continue; // 已过去的不算
      final days = date.difference(today).inDays;
      if (best == null || days < best.daysLeft) {
        best = ExamCountdown(
          name: (e['name'] as String?)?.trim().isNotEmpty == true
              ? (e['name'] as String).trim()
              : '未命名考试',
          date: date,
          daysLeft: days,
          classroom: (e['classroom'] as String?)?.trim() ?? '',
          startTime: (e['start_time'] as String?)?.trim() ?? '',
        );
      }
    }
    return best;
  }

  static DateTime? _parseDate(String? raw) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return null;
    // 支持 2026-06-15 / 2026/06/15 / 2026年6月15日
    final m = RegExp(r'(\d{4})\D+(\d{1,2})\D+(\d{1,2})').firstMatch(s);
    if (m == null) return null;
    try {
      return DateTime(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
      );
    } catch (_) {
      return null;
    }
  }
}

/// 最近考试倒计时数据
class ExamCountdown {
  final String name;
  final DateTime date;
  final int daysLeft; // 0=今天，1=明天...
  final String classroom;
  final String startTime;

  const ExamCountdown({
    required this.name,
    required this.date,
    required this.daysLeft,
    this.classroom = '',
    this.startTime = '',
  });
}
