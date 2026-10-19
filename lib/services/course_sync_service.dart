import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/course_model.dart';
import '../models/course_table.dart';
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
    this.conflicts = const <CourseConflict>[],
    this.selfConflicts = const <CourseConflict>[],
  });

  /// 成功且**真的写进了课表**。
  final bool ok;

  /// 给用户看的一句话（中文，可直接丢进 SnackBar）。
  final String message;

  /// 本次从教务取回的课程数。
  final int fetched;

  /// 合并后课表里的课程总数。
  final int totalCourses;

  /// 本次同步检出的「教务课 ↔ 本地课」时间冲突（2026-10-13，任务三）。
  /// 非空时由课表页弹「怎么处理」的对话框。
  final List<CourseConflict> conflicts;

  /// 教务课表**自己内部**的重叠（例如某晚两门课撞在一起，2026-10-13）。
  /// 用户改不了教务，只做**提示**，不给删除选项。
  final List<CourseConflict> selfConflicts;

  /// 要不要给用户弹冲突提示（两类冲突任一非空）。
  bool get hasAnyConflict => conflicts.isNotEmpty || selfConflicts.isNotEmpty;

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
  static Future<CourseSyncResult> sync(
    ProviderContainer container, {
    /// 非空 = 把这次同步的结果**写进一份新课表**（「导入一份新课表」走这条），
    /// 原课表原样不动；空 = 照常合并进当前那份。
    String? asNewTableName,

    /// 新课表的第 1 周（对话框里用户选的）。给 null 就按学期估算。
    DateTime? asNewTableStart,
  }) async {
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
        final c = courseFromRaw(Map<String, dynamic>.from(item));
        if (c != null) parsed.add(c);
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

      // 「导入一份新课表」→ 新建一份，原课表原样保留，并自动切过去。
      // 注意是**导入成功这一刻**才建表 —— 用户中途取消就什么都不产生，
      // 不需要再写「回滚空表 + 切回原来那份」那套逻辑（在线版同理）。
      final asNew = asNewTableName;
      final List<Course> merged;
      var conflicts = const <CourseConflict>[];
      // 教务自己排课就撞上的（用户改不了，只提示）—— 先算，两条路径都要用。
      final selfConflicts = CourseStorage.detectSelfConflicts(parsed);
      if (asNew != null) {
        await CourseStorage.createTable(
          name: asNew,
          courses: parsed,
          semesterStart: asNewTableStart,
          // 第 1 周是用户在对话框里选的 → 记成 user，别再弹「请确认第 1 周」
          semesterStartSource: CourseTable.srcUser,
          // 2026-10-13：这是「导入一份（他人的）课表」→ 标记为 imported，
          // 今后自动更新/手动刷新都不会写它（防止被我的教务覆盖）。
          kind: CourseTable.kindImported,
        );
        await notifier.load();
        merged = await CourseStorage.loadCourses();
      } else {
        // 🔴 2026-10-13：**只写"本人的课表"**。
        //    原来写的是「当前激活那份」—— 用户导入他人的课表并切过去之后，
        //    自动更新/手动刷新会把我自己的教务课表灌进去，把别人的课表覆盖掉。
        final targetId = await CourseStorage.resolveSyncTargetId();
        if (targetId == null) {
          return const CourseSyncResult(
            ok: false,
            message: '当前没有「我的课表」可更新（现有课表都是导入或手动建的）',
          );
        }
        final res = await notifier.mergeServerInto(targetId, parsed);
        merged = res.merged;
        conflicts = res.conflicts;
        final targetName =
            (await CourseStorage.loadTables()).firstWhere((t) => t.id == targetId).name;
        final activeId = await CourseStorage.activeTableId();
        if (activeId != targetId) {
          // 目标不是当前看的那份 → 明确告诉用户写了哪份，避免"我明明在看这份"
          return CourseSyncResult(
            ok: true,
            fetched: parsed.length,
            totalCourses: merged.length,
            message: '已更新「$targetName」，共 ${merged.length} 门课程（当前查看的是导入的课表，未改动）'
                '${selfConflicts.isEmpty ? '' : '，教务课表内有 ${selfConflicts.length} 处冲突'}',
            conflicts: conflicts,
            selfConflicts: selfConflicts,
          );
        }
      }

      // 开学日期不是无条件写 —— 见 shouldAdoptSemesterStart 的说明。
      // 新建那份分支里，第 1 周是用户亲手选的（或本来就没选、该由估算填），
      // 已经在 createTable 里落好了，这里不要再覆盖。
      if (asNew == null) {
        final computed = CourseStorage.autoSemesterStart(xnm, xqm);
        final stored = await CourseStorage.loadSemesterStart();
        if (shouldAdoptSemesterStart(stored, computed)) {
          await notifier.setSemesterStart(computed);
        }
      }

      // 课表变了 → 上课提醒要跟着重排（本地通知的时刻来自课程表）。
      unawaited(CourseReminderService.rescheduleAll());

      return CourseSyncResult(
        ok: true,
        fetched: parsed.length,
        totalCourses: merged.length,
        message: _syncMessage(merged.length, conflicts.length, selfConflicts.length),
        conflicts: conflicts,
        selfConflicts: selfConflicts,
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

  /// 拼同步结果的一句话（把两类冲突都说清楚，2026-10-13）。
  static String _syncMessage(int total, int crossCount, int selfCount) {
    final parts = <String>['课表已同步，共 $total 门课程'];
    if (selfCount > 0) parts.add('教务课表内有 $selfCount 处冲突');
    if (crossCount > 0) parts.add('与本地课程有 $crossCount 处冲突');
    return parts.join('，');
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

  /// 把抓取器返回的**一行课程 JSON** 转成 [Course]（全 App **唯一**的解析入口）。
  ///
  /// 抓取器有两种形状，都要吃下：
  ///  · **个人课表**（「我的课表同步」和「账密导入他人课表」走这条）：
  ///    `weekday` 可能是字符串，节次**只有区间串** `slots: "1-2"`，
  ///    **没有** `start_slot` / `end_slot`；
  ///  · **班级课表**（跨专业自选）：`weekday` / `start_slot` / `end_slot` 都是 int。
  ///
  /// 🔴 2026-10-16：账密导入那条链路此前**自己抄了一份**只读 `start_slot` 的解析，
  ///    而个人课表根本没有这个字段 → 每门课都吃到兜底值 1
  ///    ⇒ 用户看到「账密导入他人课表，全部导入到第一节」。
  ///    现在两条链路共用这一份，杜绝再各写各的。
  ///
  /// [prefix] 只影响生成的课程 id（同步用 `srv`、导入用 `imp`）。
  /// 返回 null = 星期认不出来，该条应当**跳过**（绝不生成"第一节"的假课）。
  static Course? courseFromRaw(Map<String, dynamic> m, {String prefix = 'srv'}) {
    final wd = parseWeekday(m['weekday']);
    if (wd == null) return null;
    final (start, end) = parseSlots(m['slots'], m['start_slot'], m['end_slot']);
    final name = (m['name'] ?? '').toString().trim();
    return Course(
      id: '${prefix}_${name}_$wd-$start',
      name: name.isEmpty ? '未命名' : name,
      teacher: (m['teacher'] ?? '').toString().trim(),
      classroom: (m['classroom'] ?? '').toString().trim(),
      weekday: wd,
      startSlot: start,
      endSlot: end,
      weeks: (m['weeks'] ?? '').toString().trim(),
      colorValue: colorForName(name),
      source: CourseSource.server,
    );
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
