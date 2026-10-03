import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'course_storage.dart';
import 'notification_service.dart';

/// 上课提醒服务（v2.2.21）：WakeUp 式「本地精确闹钟」提醒。
///
/// 原理：App 把未来 7 天的课程提醒一次性预排进系统闹钟（AlarmManager 精确闹钟），
/// 到点由**系统**唤起发通知栏通知——App 进程被杀、不在后台都能响，无需服务器推送。
///
/// - 排程时机：App 启动、课表数据变更（保存/导入/删除）、开机（BootReceiver）；
/// - 通知 id 段：100000..100139（dayIndex*20 + startSlot），与待办 id 段隔离；
/// - 提前量固定 10 分钟（页面 UI 如需可配置再扩展）；
/// - 所有异常静默吞掉，绝不影响 App 主体。
class CourseReminderService {
  static const String _kEnabled = 'course_reminder_enabled';
  static const int _idBase = 100000;
  static const int _dayStride = 20; // 每天预留 20 个 id（最多 12 节课）
  static const int _days = 7; // 预排未来 7 天
  static const String _kLeadMinutes = 'course_reminder_lead_minutes'; // v2.3.0 可配置
  static const String _kHangCountdown = 'course_reminder_hang_countdown'; // v2.3.7
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
      await _cancelAll();

      final courses = await CourseStorage.loadCourses();
      if (courses.isEmpty) return 0;

      final now = DateTime.now();
      final lead = await leadMinutes();
      final hang = await hangCountdown();
      final semesterStart = await CourseStorage.loadSemesterStart() ??
          CourseStorage.defaultSemesterStart(now);
      final slotStart = await _loadSlotStartMap();

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

          final id = _idBase + d * _dayStride + c.startSlot;
          if (!usedIds.add(id)) continue; // 同一天同一节重叠，只提醒第一条

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
          await NotificationService.schedule(
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
            // 悬挂模式：常驻 + 实时倒计时到上课；非悬挂模式：5 秒后自动撤下
            countdownTarget: hang ? classStart : null,
            ongoing: hang,
            autoDismissSeconds: hang ? null : _shortDismissSeconds,
          );
          scheduled++;
        }
      }
      await _saveStats(scheduled, nextAt, nextCourse);
      return scheduled;
    } catch (_) {
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
  static Future<void> fireTest() async {
    await NotificationService.requestPermission();
    final lead = await leadMinutes();
    final postAt = DateTime.now().add(const Duration(seconds: 3));
    await NotificationService.schedule(
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
  }

  /// 取消全部课程提醒（含测试 id）。
  static Future<void> _cancelAll() async {
    for (var i = 0; i <= _days * _dayStride; i++) {
      await NotificationService.cancel(_idBase + i);
    }
    await NotificationService.cancel(_idBase - 1);
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
