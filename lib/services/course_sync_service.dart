import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/course_model.dart';
import '../providers/course_provider.dart';
import 'api_service.dart';
import 'course_reminder_service.dart';
import 'course_storage.dart';

/// 一次课表同步的结果。
///
/// 页面只关心两件事：**成没成**、**该给用户看什么话**。所以这里把
/// 「教务没返回课程」「网络/登录失败」都收敛成 [ok] + [message]，
/// 调用方不需要再分情况判异常。
class CourseSyncResult {
  const CourseSyncResult({
    required this.ok,
    required this.message,
    this.fetched = 0,
    this.totalCourses = 0,
  });

  /// 成功且**真的写进了课表**。
  final bool ok;

  /// 给用户看的一句话（中文，可直接丢进 SnackBar）。
  final String message;

  /// 本次从教务取回的课程数。
  final int fetched;

  /// 合并后课表里的课程总数。
  final int totalCourses;

  /// 已有一趟在跑时的返回值（不是失败，只是被挡下了）。
  static const CourseSyncResult busy =
      CourseSyncResult(ok: false, message: '正在同步中，请稍候');
}

/// 从教务系统同步课表 —— 也就是原来「教务系统一键导入」按钮背后的那条链路。
///
/// **为什么抽成服务**：同步现在有三个触发点（刷新键 / 登录成功后 / 启动时自动），
/// 逻辑写在课表页里的话，其它两处就得靠页面存活才能跑；抽出来谁都能调。
///
/// 🔴 两条不可动摇的约定（这个项目里反复踩过）：
///   1. **失败 ≠ 空**。教务没返回课程、或者中途抛异常时，一律**原样保留**已有课表。
///      [CourseStorage.mergeServerCourses] 里也再挡了一层「空列表直接返回」。
///   2. **合并而不是覆盖**。只替换 `source == server` 的课程，
///      用户手工添加（`manual`）的课一门都不动。
class CourseSyncService {
  CourseSyncService._();

  /// 并发闸门：同一时刻只允许一趟同步在跑。
  ///
  /// 启动时自动同步、登录后自动同步、用户又手点刷新——这三件事在同一秒里
  /// 撞上是完全可能的。没有闸门就会出现「同时抓两次教务、两次合并」，
  /// 教务那边也会多挨一倍的请求。
  static bool _running = false;

  /// 是否正有一趟同步在跑（页面用来显示转圈）。
  static bool get isRunning => _running;

  /// 同步当前学期的课表。
  ///
  /// 学期参数不再写死：由 [CourseStorage.semesterArgsFor] 按当前日期推出
  /// 学年/学期，与 [CourseStorage.defaultSemesterStart] 的估算**互为反函数**。
  /// （原先按钮上的面板默认「当年 + 第1学期」，2~7 月用它自动同步会抓到
  ///   秋季学期的课，然后把正确的课表覆盖掉。）
  static Future<CourseSyncResult> sync(ProviderContainer container) async {
    if (_running) return CourseSyncResult.busy;
    _running = true;
    try {
      final (xnm, xqm) = CourseStorage.semesterArgsFor(DateTime.now());

      // 不传账密：用本机已保存的统一认证凭证（未登录会在这里抛错）。
      final resp = await ApiService.fetchSchedule(xnm: xnm, xqm: xqm);
      final data = resp['data'] as Map<String, dynamic>? ?? const <String, dynamic>{};
      final rawList = data['courses'] as List<dynamic>? ?? const <dynamic>[];

      final parsed = <Course>[];
      for (final item in rawList) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item);
        // ⚠️ 抓取器返回的是**字符串**字段：
        //    weekday = "1".."7"，slots = "1-2"（区间串）。
        //    这里必须转换，不能直接当成 int / start_slot。
        final wd = parseWeekday(m['weekday']);
        if (wd == null) continue;
        final (start, end) = parseSlots(m['slots'], m['start_slot'], m['end_slot']);
        final name = (m['name'] ?? '').toString().trim();
        parsed.add(Course(
          id: 'srv_${name}_$wd-$start',
          name: name.isEmpty ? '未命名' : name,
          teacher: (m['teacher'] ?? '').toString().trim(),
          classroom: (m['classroom'] ?? '').toString().trim(),
          weekday: wd,
          startSlot: start,
          endSlot: end,
          weeks: (m['weeks'] ?? '').toString().trim(),
          colorValue: colorForName(name),
          source: CourseSource.server,
        ));
      }

      // 🔴 失败 ≠ 空：教务没返回课程 → 明确告知，且**不动**已有课表。
      //    （曾经这里照常「先删后加」，用户看到的就是「同步一下课表没了」。）
      if (parsed.isEmpty) {
        return const CourseSyncResult(
          ok: false,
          message: '教务系统没有返回课程，请稍后再试',
        );
      }

      final notifier = container.read(courseProvider.notifier);
      final merged = await notifier.mergeServer(parsed);

      // 开学日期不是无条件写 —— 见 shouldAdoptSemesterStart 的说明
      // （自动同步每次启动都跑，无条件写会把用户手动调过的开学日抹掉）。
      final computed = CourseStorage.autoSemesterStart(xnm, xqm);
      final stored = await CourseStorage.loadSemesterStart();
      if (shouldAdoptSemesterStart(stored, computed)) {
        await notifier.setSemesterStart(computed);
      }

      // 课表变了 → 上课提醒要跟着重排（本地通知的时刻来自课程表）。
      unawaited(CourseReminderService.rescheduleAll());

      return CourseSyncResult(
        ok: true,
        fetched: parsed.length,
        totalCourses: merged.length,
        message: '课表已同步，共 ${merged.length} 门课程',
      );
    } catch (e) {
      // 文案已由服务层统一成中文（未登录 / 会话过期 / 网络异常），直接展示即可。
      final msg = e.toString().replaceFirst('Exception: ', '').trim();
      return CourseSyncResult(
        ok: false,
        message: msg.isEmpty ? '同步失败，请稍后再试' : '同步失败：$msg',
      );
    } finally {
      _running = false;
    }
  }

  /// 同步拿到的开学日，该不该覆盖本机已存的？
  ///
  /// 规则：**没存过 → 写；存过且离得很近 → 不写；差得离谱（换学期了）→ 写。**
  ///
  /// 30 天这条线是刻意选的：用户在顶部「第 N 周」里手动微调，通常在一两周内；
  /// 而两个学期开学日相隔约半年。所以 30 天能干净地把「微调」和「换学期」分开。
  ///
  /// 为什么不能无条件写：同步现在是自动的、每次启动都跑。无条件写会把用户
  /// 手动调过的开学日每次都抹回估算值 —— 用户会觉得「我改了怎么又变回去了」。
  /// （原先只有手动点「导入」时才写，用户点按钮就预期它重算，所以那时没问题。）
  static bool shouldAdoptSemesterStart(DateTime? stored, DateTime computed) {
    if (stored == null) return true;
    return stored.difference(computed).inDays.abs() > 30;
  }

  /// 星期：抓取器给的是字符串（"1".."7"，个别版本会是「周一」），统一转成 1..7。
  /// 返回 null 表示无法识别 → 该条跳过。
  static int? parseWeekday(Object? v) {    if (v == null) return null;
    if (v is int) return (v >= 1 && v <= 7) ? v : null;
    final s = v.toString().trim();
    final n = int.tryParse(s);
    if (n != null) return (n >= 1 && n <= 7) ? n : null;
    const cn = {
      '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 7, '天': 7,
    };
    for (final e in cn.entries) {
      if (s.contains(e.key)) return e.value;
    }
    return null;
  }

  /// 节次：抓取器给的是区间串（"1-2" / "3~4"），兼容分开的 start_slot/end_slot。
  /// 多段（"1-2,3-4"）只取第一段。
  static (int, int) parseSlots(
      Object? slots, Object? startRaw, Object? endRaw) {
    final src = (slots ?? '').toString().split(',').first;
    final nums = RegExp(r'\d+')
        .allMatches(src)
        .map((m) => int.parse(m.group(0)!))
        .toList()
      ..sort();
    if (nums.isNotEmpty) return (nums.first, nums.last);
    final st = int.tryParse((startRaw ?? '').toString().trim());
    if (st != null) {
      return (st, int.tryParse((endRaw ?? '').toString().trim()) ?? st);
    }
    return (1, 1);
  }
}
