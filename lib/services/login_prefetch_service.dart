import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/grade_provider.dart';
import 'api_service.dart';
import 'exam_storage.dart';
import 'storage_service.dart';
import 'textbook_storage.dart';

/// 登录成功后的静默预取（2026-10-20）。
///
/// 用户要求：「登录时自动获取成绩、考试、教材」——
/// 登录本来就要走一次 CAS，顺手把三样拉回来，进页面就不用再等。
///
/// 三条规矩：
/// 1. **串行**：共用同一个教务会话与 csrftoken，并发容易互相踩；
/// 2. **全程静默**：任何一项失败都只跳过它，不弹提示、不影响登录；
/// 3. **不覆盖好数据**：沿用各存储自己的缓存策略（写失败即保持旧值）。
class LoginPrefetchService {
  LoginPrefetchService._();

  /// 并发闸门：一次登录只跑一趟；登录动作本身已经是低频事件。
  /// （之前用 `_done` 做进程内一次性，导致第二次登录不再同步 —— 用户报告
  ///  「登录后未自动同步」，所以改成「每次登录都跑，但不并发」。）
  static bool _running = false;

  static Future<void> run(ProviderContainer container) async {
    if (_running) return;
    _running = true;
    try {
      await _prefetch(container);
    } finally {
      _running = false;
    }
  }

  static Future<void> _prefetch(ProviderContainer container) async {
    // 成绩：**必须走网络查询**。
    // 注意：gradeProvider.load() 只是「从本地缓存重新载入」，不发请求 ——
    // 之前用它做预取等于什么都没做（用户反馈「登录后成绩没同步」）。
    try {
      final r = await ApiService.pushGrades();
      final semesters = (r['semesters'] as List<dynamic>?) ?? const [];
      if (semesters.isNotEmpty) {
        await container.read(gradeProvider.notifier).save(
              semesters: semesters,
              summary: r['summary'] as Map<String, dynamic>?,
              student: r['student'] as Map<String, dynamic>?,
            );
      }
    } catch (_) {
      // 静默
    }

    final now = DateTime.now();
    final year = now.month >= 8 ? now.year : now.year - 1;
    final term = now.month >= 8 ? 3 : 12; // 3=第一学期，12=第二学期

    // 考试
    try {
      final resp = await ApiService.fetchExams(xnm: '$year', xqm: '$term');
      final data = resp['data'] as Map<String, dynamic>? ?? {};
      final raw = (data['exams'] as List<dynamic>?) ?? const [];
      final parsed =
          raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (parsed.isNotEmpty) {
        await ExamStorage.saveExams(parsed,
            semester: data['semester'] as String?);
      }
    } catch (_) {
      // 静默
    }

    // 教材
    try {
      final resp = await ApiService.fetchTextbooks(xnm: '$year', xqm: '$term');
      final data = resp['data'] as Map<String, dynamic>? ?? {};
      final raw = (data['books'] as List<dynamic>?) ?? const [];
      final parsed =
          raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (parsed.isNotEmpty) {
        await TextbookStorage.saveBooks(parsed,
            semester: data['semester'] as String?);
      }
    } catch (_) {
      // 静默
    }

    // 一卡通余额（失败就算了，登录不受影响）
    try {
      final res = await ApiService.fetchCardBalance();
      final data = (res['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final value = data['balance'];
      if (value is num) {
        await StorageService.saveCardBalanceCache(value.toDouble());
      }
    } catch (_) {
      // 静默
    }
  }
}
