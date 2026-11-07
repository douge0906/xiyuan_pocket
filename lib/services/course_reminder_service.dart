import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'course_storage.dart';
import 'notification_service.dart';

/// 上课提醒服务（v2.2.21）：WakeUp 式「本地精确闹钟」提醒。
///
/// 原理：App 把未来 7 天的课程提醒一次性预排进系统闹钟（AlarmManager 精确闹钟），
/// 到点由**系统**唤起发通知栏通知——App 进程被杀、不在后台都能响，无需服务器推送。
///
/// - 排程时机：App 启动、课表数据变更（保存/导入/删除）、开机（BootReceiver）；
/// - 通知 id 段：`_idBase + dayIndex*_dayStride + startSlot` = 100000..100132
///   （7 天 × 每天 20 个槽位，只用 1..12；13..19 空槽留给「同节重叠的第二门起」，
///   取消时按 0..140 全段扫，覆盖更宽）；
///   ⚠️ 待办用的是 `Todo.notifyId`（0x40000000 + hash & 0x0FFFFFFF），
///   下限 1073741824 远高于本段上限 100140，**物理上不相交**；
/// - 提前量：默认 10 分钟，可在设置页配置（`_kLeadMinutes`，v2.3.0 起）；
/// - 所有异常静默吞掉，绝不影响 App 主体。
class CourseReminderService {
  static const String _kEnabled = 'course_reminder_enabled';
  static const int _idBase = 100000;
  static const int _dayStride = 20; // 每天预留 20 个 id（最多 12 节课）
  static const int _days = 7; // 预排未来 7 天
  static const String _kLeadMinutes = 'course_reminder_lead_minutes'; // v2.3.0 可配置
  static const String _kHangCountdown = 'course_reminder_hang_countdown'; // v2.3.7

  /// 安卓通知岛（Android 16 实时更新 / 流体云）开关。
  ///
  /// 🔴 与「倒计时」不同：通知岛要求通知**常驻**（ongoing）+ **系统倒计时**，
  ///    而「不悬挂」模式通知 5 秒就撤下 → 永远进不了胶囊。
  ///    这里单开一个开关，两条通道互不干扰。
  static const String _kLiveUpdate = 'course_reminder_live_update';
  static const int _shortDismissSeconds = 5; // 「不悬挂」模式下通知展示时长
  static const String _kStats = 'course_reminder_stats'; // v2.3.8 排程统计（页面展示用）

  /// 默认上课时间块（与 course_grid_widgets.dart 的 kDefaultCourseBlocks 保持一致）。
  /// key=节次，value=该节开始时刻（时:分）。
  static const Map<int, String> _defaultSlotStart = {
    1: '08:00', 2: '08:55', 3: '10:10', 4: '11:05',
    5: '13:45', 6: '14:40', 7: '15:55', 8: '16:50',
    9: '18:45', 10: '19:40', 11: '20:35', 12: '21:40',
  };

  /// 是否开启上课提醒（默认开启；权限未授予时系统会拦截通知， harmless）。
  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kEnabled) ?? true;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, value);
    if (!value) {
      await _cancelAll();
      await clearStats();
    } else {
      await rescheduleAll();
    }
  }

  /// 是否长时间悬挂倒计时（v2.3.7，默认关）：
  /// 开 = 通知常驻并实时倒数到上课时刻，上课瞬间自动消失；
  /// 关 = 通知只显示 5 秒后自动撤下，不占用状态栏。
  static Future<bool> hangCountdown() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kHangCountdown) ?? false;
  }

  /// 是否启用安卓通知岛（实时更新 / 流体云）。**默认开启**。
  ///
  /// 仅在系统为 Android 16+ 且用户授予了「实时更新」权限时才有效；
  /// 低版本系统会自动忽略（原生侧按 SDK_INT 判断）。
  static Future<bool> liveUpdateEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kLiveUpdate) ?? true;
  }

  static Future<void> setLiveUpdate(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLiveUpdate, value);
    await rescheduleAll(); // 模式变化 → 全量重排
  }

  static Future<void> setHangCountdown(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHangCountdown, value);
    await rescheduleAll(); // 模式变化 → 全量重排
  }

  /// 提前提醒分钟数（v2.3.0 可配置，默认 10，可选 5/10/15/20）。
  static Future<int> leadMinutes() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kLeadMinutes) ?? 10;
  }

  static Future<void> setLeadMinutes(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLeadMinutes, minutes);
    await rescheduleAll(); // 提前量变化 → 全量重排
  }

  /// 重排未来 7 天的课程提醒。返回成功排上的条数（供测试/设置页展示）。
  static Future<int> rescheduleAll() async {
    try {
      if (!await isEnabled()) return 0;
      // 🔴 先读课程、确认数据可用，再清空历史排程。
      //    原顺序是「先 _cancelAll() 再 loadCourses()」——loadCourses 抛异常时
      //    用户手机上全部上课提醒已被清掉，而异常被下面 catch 吞掉，
      //    结果是一条不响、设置页还显示「已排程 0 条」，完全无法自查。
      final courses = await CourseStorage.loadCourses();
      if (courses.isEmpty) {
        // 课表空就不必重建，但历史排程仍要清（改表/退课后的残留）。
        await _cancelAll();
        await _saveStats(0, null, '');
        return 0;
      }

      // 🔴 2026-11-04 审查 P0：这几步「与课程数据无关的读配置」**必须**在
      //    `_cancelAll()` 之前做完。
      //    原顺序是「_cancelAll() 之后才 leadMinutes/hangCountdown/
      //    liveUpdateEnabled/loadSemesterStart/_loadSlotStartMap」，而
      //    _cancelAll() 是 142 次串行平台调用 —— 清空与重建之间有一段
      //    真实存在的空窗。这五步里任意一步抛（SharedPreferences 拿不到、
      //    loadTimeBlocks 解析失败…），catch 只 debugPrint + return 0，
      //    此刻旧提醒已全删、新提醒一条没建 → 用户侧表现是「突然安静地
      //    再也不响」，设置页只显示「已排程 0 条」。
      //    把它们上移之后，最坏情况是「旧的还在、新的没建」，至少能响。
      final now = DateTime.now();
      final lead = await leadMinutes();
      final hang = await hangCountdown();
      final liveUpdate = await liveUpdateEnabled();
      final semesterStart = await CourseStorage.loadSemesterStart() ??
          CourseStorage.defaultSemesterStart(now);
      final slotStart = await _loadSlotStartMap();

      await _cancelAll();

      int scheduled = 0;
      final usedIds = <int>{};
      DateTime? nextAt;
      String nextCourse = '';

      for (var d = 0; d < _days; d++) {
        final day = DateTime(now.year, now.month, now.day + d);
        final week = CourseStorage.teachingWeek(day, semesterStart);
        final wd = day.weekday;

        for (final c in courses) {
          // 「这天有没有这节课」判定：唯一真相源 Course.occursOn（v2.3.1 收敛）
          if (!c.occursOn(wd, week)) continue;

          final hhmm = slotStart[c.startSlot];
          if (hhmm == null) continue;
          final parts = hhmm.split(':');
          final h = int.tryParse(parts[0]);
          final m = parts.length > 1 ? int.tryParse(parts[1]) : null;
          if (h == null || m == null) continue;

          final remindAt =
              DateTime(day.year, day.month, day.day, h, m)
                  .subtract(Duration(minutes: lead));
          if (!remindAt.isAfter(now)) continue;

          // 2026-11-04 审查 P1：同一节重叠的两门课，原先在这里
          // `if (!usedIds.add(id)) continue;` —— 第二条被**静默丢弃**，
          // 用户只看到第一门课的提醒，以为第二门「不重要」。
          //
          // 修法：每天预留 20 个槽位但正常课只用 1..12，把 **13..19 这 7 个
          // 空槽** 给重叠课用 —— 完全落在 `_cancelAll` 已扫的 0..140 段内，
          // 不需要改取消逻辑，也不会越界到别的 id 段。
          // 2026-11-04 审查 P3：`_dayStride = 20`，槽 20 一直是空的；
          // 边界从 `n <= 7` 放到 `n <= 8` 可以白捡一个名额。
          final baseId = _idBase + d * _dayStride + c.startSlot;
          var id = baseId;
          if (usedIds.contains(id)) {
            // 第 2 门起用 12+n（13..20）
            var n = 1;
            while (n <= 8 && usedIds.contains(_idBase + d * _dayStride + 12 + n)) {
              n++;
            }
            if (n > 8) {
              // 同节超过 9 门属脏数据，别再无限找；但必须留痕，
              // 否则用户永远不知道自己少了一条提醒。
              debugPrint(
                  '[CourseReminder] 同节课程过多，丢弃提醒：${c.name} '
                  '(weekday=$wd slot=${c.startSlot})');
              continue;
            }
            id = _idBase + d * _dayStride + 12 + n;
          }
          usedIds.add(id);

          // v2.3.8：记录最早一条提醒，供提醒设置页展示「下一条提醒」
          if (nextAt == null || remindAt.isBefore(nextAt)) {
            nextAt = remindAt;
            nextCourse = c.name;
          }

          // v2.3.0 通知信息优化：大标题=课程名，正文=教室/节次/时刻，展开显示完整信息
          // v2.3.3 系统原生实时倒计时：通知由系统逐秒倒数到上课时刻，上课瞬间自动消失
          final room = c.classroom.trim();
          final classStart = DateTime(day.year, day.month, day.day, h, m);
          final slotRange = c.endSlot > c.startSlot
              ? '第${c.startSlot}-${c.endSlot}节'
              : '第${c.startSlot}节';
          final ok = await NotificationService.schedule(
            id: id,
            title: '距上课 $lead 分钟 · ${c.name}',
            body: '$hhmm · ${room.isEmpty ? "地点未排" : room}',
            bigText: '上课时间：$hhmm（$slotRange）\n'
                '地点：${room.isEmpty ? "未排" : room}\n'
                '教师：${c.teacher.trim().isEmpty ? "未定" : c.teacher.trim()}\n'
                '点击打开课表',
            scheduledTime: remindAt,
            payload: 'course_reminder',
            course: true,
            // 悬挂模式：常驻 + 实时倒计时到上课；非悬挂模式：5 秒后自动撤下。
            //
            // 🔴 通知岛（实时更新）要求「常驻 + 系统倒计时」同时成立，
            //    所以开启通知岛时**必须**走 ongoing + countdownTarget，
            //    且不能设 autoDismissSeconds（否则 5 秒就被撤下 → 不常驻）。
            countdownTarget: (hang || liveUpdate) ? classStart : null,
            ongoing: hang || liveUpdate,
            autoDismissSeconds:
                (hang || liveUpdate) ? null : _shortDismissSeconds,
            liveUpdate: liveUpdate,
          );
          // 🔴 只有真的排上了才计数：schedule 在通知初始化失败 / 三级降级
          //    全崩时会静默放弃，一律 +1 会让设置页的「已排程 N 条」虚高。
          if (ok) scheduled++;
        }
      }
      await _saveStats(scheduled, nextAt, nextCourse);
      return scheduled;
    } catch (e) {
      // 提醒失败不能拖垮 App，但也绝不能一声不响地消失。
      debugPrint('[CourseReminder] rescheduleAll 失败: $e');
      return 0;
    }
  }

  /// 写入排程统计（条数 + 下一条提醒时间/课程名）。
  static Future<void> _saveStats(
      int count, DateTime? nextAt, String nextCourse) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kStats,
        jsonEncode({
          'count': count,
          'nextAt': nextAt?.toIso8601String() ?? '',
          'nextCourse': nextCourse,
          'savedAt': DateTime.now().toIso8601String(),
          'lead': await leadMinutes(),
        }),
      );
    } catch (_) {
      // 统计写失败不影响提醒
    }
  }

  /// 读取排程统计：{count, nextAt, nextCourse, savedAt, lead}；无记录返回空 Map。
  static Future<Map<String, dynamic>> stats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kStats);
      if (raw == null || raw.isEmpty) return {};
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  /// 关闭提醒时清空统计（避免页面显示过期的"已排 N 条"）。
  static Future<void> clearStats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kStats);
    } catch (_) {}
  }

  /// 发送一条测试提醒：3 秒后到达，120 秒实时倒计时（v2.3.6 按用户要求调整）。
  /// 用户按下后可退出 App / 锁屏，验证「App 不在前台也能收到通知栏提醒」与胶囊效果。
  ///
  /// 🔴 2026-11-04 审查 P1：原返回 `Future<void>`，调用方
  ///    `reminder_settings_page.dart` 只能看 `pendingCount() > 0` 判成功 ——
  ///    只要队列里本来有任意一条提醒（课程提醒开着就必然有），这个判据**恒真**。
  ///    于是排障的唯一入口永远报「测试已排定」，即使三级降级全失败。
  ///    现改为返回 `schedule()` 的真实结果。
  static Future<bool> fireTest() async {
    await NotificationService.requestPermission();
    // 🔴 2026-11-04 修「清理后台后无法触发测试通知」：
    //    原来是**只**排一条 3 秒后的定时通知。于是两件事混在一起：
    //      · 通知权限被拒 —— 插件仍可能返回 true（它只是把 show 交给系统，
    //        系统静默丢弃），界面上却报「测试已排定」；
    //      · 进程被清掉后这条完全依赖 AlarmManager —— 落到 inexact 通道
    //        会延迟到几小时之后。
    //    两种失败长得一模一样，用户没法判断该去开权限还是该去关省电。
    //    现在先立刻弹一条（不经过任何闹钟）：它到达就说明权限/渠道/悬浮都
    //    正常，剩下的问题只可能在后台闹钟那一环。
    final immediate = await NotificationService.showTestNotification();
    final lead = await leadMinutes();
    final postAt = DateTime.now().add(const Duration(seconds: 3));
    final ok = await NotificationService.schedule(
      id: _idBase - 1, // 测试专用 id，与正式排程段不冲突
      title: '测试提醒 · 倒计时演示',
      body: '正在实时倒数，120 秒后自动消失',
      bigText: '这是一条测试提醒：\n'
          '标题：距上课 $lead 分钟 · 课程名\n'
          '正文：上课时间 · 教室\n'
          '本通知到点自动消失，无需手动清除。',
      scheduledTime: postAt,
      payload: 'course_reminder_test',
      course: true,
      countdownTarget: postAt.add(const Duration(seconds: 120)),
      ongoing: true, // 与正式提醒一致（常驻才触发胶囊卡片），120 秒后自动消失
    );
    // 注意：**不要**在这里调 `NotificationHealth.instance.report()` ——
    // 它是「整体覆盖」语义（全量重排的最近结果），用一条测试去覆盖会把
    // 「已排上 N 条 / 失败 M 条」冲成 1/0，设置页的统计反而失真。
    //
    // 立刻那条失败 = 权限/渠道问题（连前台都发不出来），此时定时那条也
    // 没意义，按失败报。
    return immediate && ok;
  }

  /// 测试结果的两段式说明（页面 toast 用）。
  ///
  /// 之所以单独给一句话：光说「失败」用户不知道下一步该点哪里。
  static String describeTestResult({required bool ok}) {
    if (ok) {
      return '已发送：立刻那条应该已经弹出；3 秒后还有一条定时提醒，'
          '现在退出 App 或锁屏也能收到。';
    }
    return '没发出去。先点上面「通知权限」那一行完成授权；'
        '若已授权仍无反应，去系统设置把本应用「后台运行 / 自启动」打开。';
  }

  /// 取消全部课程提醒（含测试 id）。
  ///
  /// 2026-11-04 审查 P3：原来是 142 次**串行** `await` —— 哪怕一条都不存在也
  /// 要走完 142 个 MethodChannel 往返，而 `main.dart` 的启动、resume、
  /// 首帧权限回调三处都会触发它。改成并发：平台侧 `cancel` 是幂等的，
  /// 并发不会产生竞态，但把空窗从「142 个往返」压到「1 个往返」。
  static Future<void> _cancelAll() async {
    final ids = <int>[
      for (var i = 0; i <= _days * _dayStride; i++) _idBase + i,
      _idBase - 1,
    ];
    await Future.wait(ids.map(NotificationService.cancel));
  }

  /// 读取节次→开始时刻表：优先用户自定义时间块，未设置回退默认表。
  static Future<Map<int, String>> _loadSlotStartMap() async {
    final map = Map<int, String>.of(_defaultSlotStart);
    try {
      final blocks = await CourseStorage.loadTimeBlocks();
      if (blocks != null) {
        for (final b in blocks) {
          final start = (b['start'] as num?)?.toInt();
          final end = (b['end'] as num?)?.toInt();
          final time = (b['time'] as String?) ?? '';
          final first = time.split('\n').first.trim(); // '08:00\n08:45' → '08:00'
          if (start == null || end == null || !first.contains(':')) continue;
          for (var s = start; s <= end && s <= 12; s++) {
            map[s] = first;
          }
        }
      }
    } catch (_) {
      // 解析失败用默认表
    }
    return map;
  }
}
