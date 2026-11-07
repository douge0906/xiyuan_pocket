import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/academic_term.dart';
import '../providers/grade_provider.dart';
import 'api_service.dart';
import 'course_sync_service.dart';
import 'dorm_service.dart';
import '../models/study_models.dart';
import 'exam_storage.dart';
import 'login_sync_progress.dart';
import 'study_store.dart';
import 'textbook_storage.dart';
import 'widget_sync_service.dart';

/// 登录成功后的自动同步（2026-11-04 重做进度反馈）。
///
/// 用户要求：「登录成功 自动同步成绩 中.... 同步成功。 自动同步...中 ...
/// 同步成功 一行一个功能」—— 所以这里把每一步的状态推进到
/// [LoginSyncProgress]，由登录后弹出的进度条读它。
///
/// 四条规矩：
/// 1. **串行**：共用同一个教务会话与 csrftoken，并发容易互相踩；
/// 2. **失败不阻断**：任何一项失败只标「失败」并继续下一项，不影响登录；
/// 3. **不覆盖好数据**：沿用各存储自己的缓存策略（写失败即保持旧值）；
/// 4. **顺序固定**：课表 → 成绩 → 考试 → 教材 → 一卡通，与进度条一致。
class LoginPrefetchService {
  LoginPrefetchService._();

  /// 并发闸门：一次登录只跑一趟；登录动作本身已经是低频事件。
  /// （之前用 `_done` 做进程内一次性，导致第二次登录不再同步 —— 用户报告
  ///  「登录后未自动同步」，所以改成「每次登录都跑，但不并发」。）
  static bool _running = false;

  /// 跑一遍全部同步。[runCourses] = false 时跳过课表那一步
  /// （登录流程里课表由 `CourseSyncService.sync` 单独跑，因为它要处理冲突）。
  static Future<void> run(
    ProviderContainer container, {
    bool runCourses = false,
  }) async {
    if (_running) return;
    _running = true;
    try {
      if (runCourses) {
        await _courses(container);
      } else {
        // 课表由调用方负责，这里只把它标成就绪，进度条不会卡住。
        LoginSyncProgress.done(LoginSyncStep.courses, note: '已单独同步');
      }
      await _prefetch(container);
    } finally {
      LoginSyncProgress.skipRest(note: '已跳过');
      _running = false;
    }
  }

  /// 同步课表（登录流程也会单独调一次，包一层只为推进度）。
  static Future<void> _courses(ProviderContainer container) async {
    LoginSyncProgress.running(LoginSyncStep.courses);
    try {
      final r = await CourseSyncService.sync(container);
      LoginSyncProgress.mark(
        LoginSyncStep.courses,
        r.ok ? LoginSyncStatus.done : LoginSyncStatus.failed,
        note: r.ok ? '${r.totalCourses} 门课' : r.message,
      );
    } catch (_) {
      LoginSyncProgress.failed(LoginSyncStep.courses, note: '网络异常');
    }
  }

  static Future<void> _prefetch(ProviderContainer container) async {
    // 学期码唯一真源见 models/academic_term.dart（原来这里 month>=8 的写法
    // 在 1 月会把寒假算成「第二学期」，导致预取全空）。
    final term0 = currentAcademicTerm();
    final year = term0.year;
    final term = term0.term;

    // 成绩：**必须走网络查询**。
    // 注意：gradeProvider.load() 只是「从本地缓存重新载入」，不发请求 ——
    // 之前用它做预取等于什么都没做（用户反馈「登录后成绩没同步」）。
    LoginSyncProgress.running(LoginSyncStep.grades);
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
      LoginSyncProgress.mark(
        LoginSyncStep.grades,
        semesters.isEmpty ? LoginSyncStatus.failed : LoginSyncStatus.done,
        note: semesters.isEmpty ? '暂无成绩' : '${semesters.length} 个学期',
      );
    } catch (_) {
      LoginSyncProgress.failed(LoginSyncStep.grades, note: '网络异常');
    }

    // 考试
    LoginSyncProgress.running(LoginSyncStep.exams);
    try {
      final resp = await ApiService.fetchExams(xnm: '$year', xqm: '$term');
      final data = resp['data'] as Map<String, dynamic>? ?? {};
      final raw = (data['exams'] as List<dynamic>?) ?? const [];
      final parsed =
          raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (parsed.isNotEmpty) {
        await ExamStorage.saveExams(parsed,
            semester: data['semester'] as String?);
        await WidgetSyncService.syncExamWidget();
      }
      LoginSyncProgress.mark(
        LoginSyncStep.exams,
        parsed.isEmpty ? LoginSyncStatus.failed : LoginSyncStatus.done,
        note: parsed.isEmpty ? '暂无考试' : '${parsed.length} 场',
      );
    } catch (_) {
      LoginSyncProgress.failed(LoginSyncStep.exams, note: '网络异常');
    }

    // 教材
    LoginSyncProgress.running(LoginSyncStep.textbooks);
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
      LoginSyncProgress.mark(
        LoginSyncStep.textbooks,
        parsed.isEmpty ? LoginSyncStatus.failed : LoginSyncStatus.done,
        note: parsed.isEmpty ? '暂无教材' : '${parsed.length} 本',
      );
    } catch (_) {
      LoginSyncProgress.failed(LoginSyncStep.textbooks, note: '网络异常');
    }

    // 一卡通余额（失败就算了，登录不受影响）
    LoginSyncProgress.running(LoginSyncStep.card);
    try {
      final res = await ApiService.fetchCardBalance();
      final data = (res['data'] as Map?)?.cast<String, dynamic>() ?? const {};
      final value = data['balance'];
      if (value is num) {
        await DormService.saveCardCache(value.toDouble());
        await WidgetSyncService.syncCardWidget();
        LoginSyncProgress.done(LoginSyncStep.card,
            note: '¥ ${value.toStringAsFixed(2)}');
      } else {
        LoginSyncProgress.failed(LoginSyncStep.card, note: '未取到余额');
      }
    } catch (_) {
      LoginSyncProgress.failed(LoginSyncStep.card, note: '网络异常');
    }

    // 我的学业（培养方案 / 已修课程 / GPA）。
    //
    // 用户反馈「我的学业没有自动导入」—— 以前只有进「我的学业」页面才会
    // 抓一次，登录后什么都不做，页面首屏永远是「暂无数据」。这里把它并进
    // 登录预取，第一次登录就能看到档案。
    //
    // StudyStore.save 自己带守卫：降级态（isUnconfigured）不会覆盖已有的
    // full 档案，所以一次网络抖动不会把 135 门课抹成「未配置培养方案」。
    LoginSyncProgress.running(LoginSyncStep.study);
    try {
      final resp = await ApiService.fetchStudy(xnm: '$year', xqm: '$term');
      final archive = resp['data'] as StudyArchive?;
      if (archive == null) {
        LoginSyncProgress.failed(LoginSyncStep.study, note: '未取到档案');
      } else {
        final saved = await StudyStore.save(archive);
        LoginSyncProgress.mark(
          LoginSyncStep.study,
          archive.blocks.isEmpty ? LoginSyncStatus.failed : LoginSyncStatus.done,
          note: archive.blocks.isEmpty
              ? (archive.isUnconfigured ? '教务未配置培养方案' : '暂无数据')
              : (saved ? '${archive.blocks.length} 个板块' : '已保留旧档案'),
        );
      }
    } catch (_) {
      LoginSyncProgress.failed(LoginSyncStep.study, note: '网络异常');
    }

    // 电费（只在宿舍已绑定时查；没绑定不弹窗，绑定入口在「我的」页）。
    //
    // 为什么静默：登录时宿舍还没绑的人占多数，这里只补「已绑定的人」
    // 首屏就有电费余额，不替用户做绑定的决定。绑定引导在
    // UserPage._afterLogin 里单独做（那里有 context，能弹窗）。
    LoginSyncProgress.running(LoginSyncStep.elec);
    try {
      final dorm = await DormStore.load();
      if (dorm == null) {
        LoginSyncProgress.failed(LoginSyncStep.elec, note: '未绑定宿舍');
      } else {
        final info = await DormService.query(dorm);
        if (info == null) {
          LoginSyncProgress.failed(LoginSyncStep.elec, note: '暂不可用');
        } else {
          await DormService.saveElecCache(info, dorm);
          if (info.balance != null) {
            await DormService.saveElecPoint(info.balance!,
                kwh: info.kwh, dorm: dorm);
          }
          LoginSyncProgress.done(LoginSyncStep.elec,
              note: info.balance == null
                  ? '已同步'
                  : '¥ ${info.balance!.toStringAsFixed(2)}');
        }
      }
    } catch (_) {
      LoginSyncProgress.failed(LoginSyncStep.elec, note: '网络异常');
    }
  }
}
