import 'dart:convert';
import 'package:home_widget/home_widget.dart';
import '../models/course_model.dart';
import 'course_storage.dart';

/// 桌面小组件（今日课表）Flutter 侧同步服务。
///
/// 职责：读取本地课程表，计算「今天有哪些课」，把 JSON 写入 home_widget
/// 的共享存储并广播刷新，交给原生 `TodayWidgetProvider` 渲染。原生侧不依赖
/// Flutter 引擎，App 未运行时也能按缓存数据显示（系统每 30~60 分钟自动刷新）。
///
/// 数据通路（v1.0.0 起，替换原先手写 MethodChannel 的 `updateTodayCourses`）：
///   Dart: HomeWidget.saveWidgetData('widget_today_courses', json)
///   Dart: HomeWidget.updateWidget(qualifiedAndroidName: ...) → 广播 APPWIDGET_UPDATE
///   原生: WidgetDataStore.read() 读同一份存储 → TodayWidgetRenderer 渲染
class WidgetSyncService {
  /// 共享存储 key（与原生 `WidgetDataStore.KEY` 必须一致）。
  static const String _storageKey = 'widget_today_courses';

  /// iOS（WidgetKit）小组件 kind，供将来 iOS 侧使用；Android 忽略。
  static const String _iOSWidgetName = 'TodayWidget';

  /// 需要刷新的原生 Provider 全限定类名。
  /// home_widget 用 `Class.forName` 解析后发送 APPWIDGET_UPDATE 广播，
  /// 触发各自 `onUpdate` → 渲染 + 排下一个精准闹钟（等价于旧通道里的 updateAll）。
  static const List<String> _providerClasses = <String>[
    'icu.wxxydouge.wxxy_pocket.widget.SmallWidgetProvider',
    'icu.wxxydouge.wxxy_pocket.widget.MediumWidgetProvider',
    'icu.wxxydouge.wxxy_pocket.widget.LargeWidgetProvider',
  ];

  /// 默认上课时间块（与课程表主页一致：11 节，节次 → 开始/结束时刻）。
  /// 自定义时间块存在时优先用自定义。
  static const Map<int, String> _defaultSlotTimes = {
    1: '08:00-08:45',
    2: '08:55-09:40',
    3: '10:10-10:55',
    4: '11:05-11:50',
    5: '13:45-14:30',
    6: '14:40-15:25',
    7: '15:55-16:40',
    8: '16:50-17:35',
    9: '18:45-19:30',
    10: '19:40-20:25',
    11: '20:35-21:20',
  };

  /// 默认上课时间块（分钟制）：节次 → 开始/结束分钟数（与主页默认块一致）。
  /// 供原生侧「下一节课」按当前时间精确切换使用。
  static const Map<int, (int, int)> _defaultSlotMinutes = {
    1: (8 * 60, 8 * 60 + 45),
    2: (8 * 60 + 55, 9 * 60 + 40),
    3: (10 * 60 + 10, 10 * 60 + 55),
    4: (11 * 60 + 5, 11 * 60 + 50),
    5: (13 * 60 + 45, 14 * 60 + 30),
    6: (14 * 60 + 40, 15 * 60 + 25),
    7: (15 * 60 + 55, 16 * 60 + 40),
    8: (16 * 60 + 50, 17 * 60 + 35),
    9: (18 * 60 + 45, 19 * 60 + 30),
    10: (19 * 60 + 40, 20 * 60 + 25),
    11: (20 * 60 + 35, 21 * 60 + 20),
  };

  /// 计算「今日课程」并同步给桌面小组件。可在 App 启动、课程变更、
  /// 回到前台等时机调用；失败静默（不影响主流程）。
  static Future<void> syncTodayCourses() async {
    try {
      final courses = await CourseStorage.loadCourses();
      final start = await CourseStorage.loadSemesterStart() ??
          CourseStorage.defaultSemesterStart(DateTime.now());
      final now = DateTime.now();
      final week = CourseStorage.teachingWeek(now, start);
      final slotTimes = await _timeText();

      final today = DateTime(now.year, now.month, now.day);
      final todayWeekday = now.weekday; // 1=周一...7=周日

      // 今天上课的课程（判定唯一真相源：Course.occursOn，v2.3.1 收敛）
      final todayCourses = <Course>[];
      for (final c in courses) {
        if (c.occursOn(todayWeekday, week)) {
          todayCourses.add(c);
        }
      }
      todayCourses.sort((a, b) => a.startSlot.compareTo(b.startSlot));

      final json = jsonEncode({
        'date': _ymd(today),
        'semesterWeek': week,
        'weekday': todayWeekday,
        'hasSchedule': todayCourses.isNotEmpty,
        'courses': todayCourses
            .map((c) => {
                  'name': c.name,
                  'teacher': c.teacher,
                  'classroom': c.classroom,
                  'startSlot': c.startSlot,
                  'endSlot': c.endSlot,
                  'color': c.colorValue,
                  'timeText': _timeFor(c, slotTimes),
                  // v2.2.14：分钟制起止时刻，供原生「下一节课」按当前时间精确切换
                  'startMinute': _slotMinute(c.startSlot, slotTimes, isStart: true),
                  'endMinute': _slotMinute(c.endSlot, slotTimes, isStart: false),
                })
            .toList(),
      });

      // ① 写入共享存储（HomeWidgetPreferences / key 原样），原生侧直接读取
      await HomeWidget.saveWidgetData<String>(_storageKey, json);
      // ② 通知三个尺寸的原生小组件重绘。
      //    逐个调用是因为 home_widget 一次只广播一个 Provider；三个均无实例时
      //    对应 onUpdate 会立即返回，无副作用。iOS 侧则按 kind 刷新。
      for (final provider in _providerClasses) {
        await HomeWidget.updateWidget(
          qualifiedAndroidName: provider,
          iOSName: _iOSWidgetName,
        );
      }
    } catch (_) {
      // 静默失败：小组件保持上次状态，不影响 App 使用
    }
  }

  /// 查询桌面上是否已添加了「今日课表」小组件（三个尺寸任一）。
  ///
  /// 走 home_widget 的 `getInstalledWidgets()`，替代原先手写的
  /// `icu.wxxydouge.wxxy_pocket/widget` MethodChannel。注意 Android 侧返回的是
  /// `shortClassName`（形如 `.widget.SmallWidgetProvider`），故用后缀匹配。
  static Future<bool> isWidgetInstalled() async {
    try {
      final widgets = await HomeWidget.getInstalledWidgets();
      return widgets.any((w) {
        final cls = w.androidClassName;
        if (cls == null || cls.isEmpty) return false;
        return cls.endsWith('SmallWidgetProvider') ||
            cls.endsWith('MediumWidgetProvider') ||
            cls.endsWith('LargeWidgetProvider');
      });
    } catch (_) {
      return false;
    }
  }

  /// 构建节次 → 时间文本映射：优先用户自定义时间块，否则默认表。
  static Future<Map<int, String>> _timeText() async {
    final blocks = await CourseStorage.loadTimeBlocks();
    if (blocks == null || blocks.isEmpty) return _defaultSlotTimes;
    final map = <int, String>{};
    for (final b in blocks) {
      final start = (b['start'] as int?) ?? 0;
      final time = (b['time'] as String?) ?? '';
      if (start <= 0 || time.isEmpty) continue;
      final lines = time.split('\n');
      if (lines.length >= 2) {
        map[start] = '${lines[0]}-${lines[1]}';
      }
    }
    return map;
  }

  static String _timeFor(Course c, Map<int, String> map) {
    final start = map[c.startSlot];
    final end = map[c.endSlot];
    if (start != null && end != null) {
      // start/end 形如 "08:00-08:45"，取开始时刻的首段与结束时刻的首段
      return '${start.split('-').first}-${end.split('-').first}';
    }
    // 兜底：显示节次
    return '第${c.startSlot}节'
        '${c.endSlot > c.startSlot ? '-${c.endSlot}节' : ''}';
  }

  /// 节次 → 分钟起止。优先用户自定义时间块；否则默认分钟表。
  /// [isStart] true 返回开始分钟，false 返回结束分钟。
  static int _slotMinute(int slot, Map<int, String> map, {required bool isStart}) {
    final t = map[slot];
    if (t != null) {
      final parts = t.split('-');
      if (parts.length >= 2) {
        final target = isStart ? parts.first.trim() : parts.last.trim();
        final hm = target.split(':');
        if (hm.length == 2) {
          final h = int.tryParse(hm[0]);
          final m = int.tryParse(hm[1]);
          if (h != null && m != null) return h * 60 + m;
        }
      }
    }
    final def = _defaultSlotMinutes[slot];
    if (def != null) return isStart ? def.$1 : def.$2;
    return isStart ? 8 * 60 : 8 * 60 + 45;
  }

  static String _ymd(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }
}