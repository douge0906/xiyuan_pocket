import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

/// 考试本地缓存：把「考试查询」结果存到 SharedPreferences，
/// 供首页「今日概览」计算最近一场考试的倒计时（离线可用，无需每次联网）。
///
/// ## 来源标记（v1.7.x）
/// 每项带 `source`：`server`=教务同步，`manual`=用户手动添加。
/// 同步教务结果时只替换 `server` 项，**手动项原样保留、不被覆盖**；
/// 手动项也可单独删除。旧缓存没有 `source`/`id`，读取时按 `server` 规范化补齐。
class ExamStorage {
  static const String _kExams = 'exam_cache_list';
  static const String _kSemester = 'exam_cache_semester';
  static const String _kUpdatedAt = 'exam_cache_updated_at';

  /// 教务同步项来源。
  static const String sourceServer = 'server';

  /// 用户手动添加项来源。
  static const String sourceManual = 'manual';

  /// 生成教务项稳定指纹 id（同名同学期同时间视为同一场，便于去重/替换）。
  static String _serverId(Map<String, dynamic> e) {
    String p(String k) => (e[k] ?? '').toString().trim();
    return 'server|${p('name')}|${p('date')}|${p('start_time')}|${p('classroom')}';
  }

  /// 手动项稳定 id。
  static String _manualId() =>
      'manual_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 30)}';

  /// 规范化单条：补 `source`（缺省 server）与 `id`（旧缓存兼容）。
  static Map<String, dynamic> _normalize(Map<String, dynamic> e) {
    final out = Map<String, dynamic>.from(e);
    final source = (out['source'] ?? '').toString().trim();
    out['source'] = source == sourceManual ? sourceManual : sourceServer;
    if ((out['id'] ?? '').toString().isEmpty) {
      out['id'] = out['source'] == sourceManual ? _manualId() : _serverId(out);
    }
    return out;
  }

  /// 保存教务同步结果：**保留已有手动项，整体替换教务项**。
  ///
  /// ⚠️ **合并后为空才不写**：教务维护或改版时查询返回空而不是抛错，
  /// 页面若照写就会把已有缓存（含手动项）清空 —— 这正是本项目最高频的 bug 模式
  /// （「失败 → 静默返回空 → 空被当有效结果写回 → 抹掉好东西」）。
  static Future<void> saveExams(
    List<Map<String, dynamic>> serverExams, {
    String? semester,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await loadExams();
    final manual = existing.where((e) => e['source'] == sourceManual).toList();
    final server = [
      for (final e in serverExams) _normalize(Map<String, dynamic>.from(e)),
    ];
    final all = [...manual, ...server];
    if (all.isEmpty) return;
    await prefs.setString(_kExams, jsonEncode(all));
    if (semester != null) await prefs.setString(_kSemester, semester);
    await prefs.setString(_kUpdatedAt, DateTime.now().toIso8601String());
  }

  /// 添加一场手动考试（持久化，教务同步不会覆盖）。
  static Future<List<Map<String, dynamic>>> addManualExam(
    Map<String, dynamic> exam,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await loadExams();
    final entry = _normalize(Map<String, dynamic>.from(exam));
    entry['source'] = sourceManual;
    entry['id'] = _manualId();
    list.add(entry);
    await prefs.setString(_kExams, jsonEncode(list));
    await prefs.setString(_kUpdatedAt, DateTime.now().toIso8601String());
    return list;
  }

  /// 按 id 删除一场考试（手动项 / 教务项均可）。
  static Future<List<Map<String, dynamic>>> removeExam(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await loadExams()
      ..removeWhere((e) => (e['id'] ?? '').toString() == id);
    await prefs.setString(_kExams, jsonEncode(list));
    await prefs.setString(_kUpdatedAt, DateTime.now().toIso8601String());
    return list;
  }

  /// 读取缓存的考试列表（旧数据规范化补齐来源与 id）。
  static Future<List<Map<String, dynamic>>> loadExams() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kExams);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => _normalize((e as Map).cast<String, dynamic>()))
          .toList();
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
