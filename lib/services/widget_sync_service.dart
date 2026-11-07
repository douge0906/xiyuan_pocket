import 'dart:convert';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:home_widget/home_widget.dart';
import '../models/course_model.dart';
import '../models/course_table.dart';
import 'countdown_store.dart';
import 'course_storage.dart';
import 'exam_storage.dart';
import 'storage_service.dart';
import 'widget_prefs.dart';
import 'widget_sync_status.dart';

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
/// 小组件组件类型（用户页入口状态用）。
enum WidgetComponent { schedule, exam, card, countdown }

class WidgetSyncService {
  /// 共享存储 key（与原生 `WidgetDataStore.KEY` 必须一致）。
  static const String _storageKey = 'widget_today_courses';
  static const String _examKey = 'widget_exam_data';
  static const String _cardKey = 'widget_card_data';
  static const String _countdownKey = 'widget_countdown_data';

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

  static const String _examProvider =
      'icu.wxxydouge.wxxy_pocket.widget.ExamWidgetProvider';
  static const String _cardProvider =
      'icu.wxxydouge.wxxy_pocket.widget.CardWidgetProvider';
  static const String _countdownProvider =
      'icu.wxxydouge.wxxy_pocket.widget.CountdownWidgetProvider';
  static const String _countdown2Provider =
      'icu.wxxydouge.wxxy_pocket.widget.CountdownWidget2Provider';

  /// 默认上课时间块（与课程表主页一致：12 节，节次 → 开始/结束时刻）。
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
    12: '21:40-22:25',
  };

  /// 默认上课时间块（分钟制）：节次 → 开始/结束分钟数（与主页默认块一致，12 节）。
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
    12: (21 * 60 + 40, 22 * 60 + 25),
  };

  /// 计算「今日课程」并同步给桌面小组件。可在 App 启动、课程变更、
  /// 回到前台等时机调用；失败静默（不影响主流程）。
  static Future<void> syncTodayCourses() async {
    try {
      // 2026-10-12：支持「小组件显示哪份课表」——
      // 设置里指定了就跟随那份；没指定（或那份已被删）则跟随当前激活的课表。
      final tables = await CourseStorage.loadTables();
      final wantedId = await WidgetPrefs.tableId();
      CourseTable? table;
      if (wantedId.isNotEmpty) {
        for (final t in tables) {
          if (t.id == wantedId) {
            table = t;
            break;
          }
        }
      }
      table ??= await CourseStorage.activeTable();

      final courses = table.courses;
      // 🔴 2026-11-04 修（子智能体 c940b976 报告 P1-1）：
      //    这里以前直接用 `table.semesterStart`，而它是表里**原样存的值**，
      //    没对齐到周一。全仓其它入口（loadSemesterStart / loadActiveSnapshot
      //    / saveSemesterStart）都会 `mondayOf` 对齐，课表页因此拿到周一。
      //    两条能写出非周一的路径：课表方案导入（course_transfer_service）
      //    与老数据迁移。开学日差 1 天，周末附近的教学周就会差整整一周 →
      //    单双周课错位、小组件与课表页显示不一致。
      final rawStart = table.semesterStart ??
          await CourseStorage.loadSemesterStart() ??
          CourseStorage.defaultSemesterStart(DateTime.now());
      final start = CourseStorage.mondayOf(
          DateTime(rawStart.year, rawStart.month, rawStart.day));
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
        // 教学周起点：原生侧跨零点重算「今天有哪些课」时要靠它推周次。
        // 下发的是**已对齐周一**的值（见上面 mondayOf），原生侧不再二次对齐。
        'semesterStart': _ymd(start),
        // 个性化设置：原生侧按这些字段决定主题 / 字号 / 显示哪些内容
        // 2026-11-05：课表组件也有独立外观；
        // `...` 展开在前，per-kind 的生效值覆盖同名字段。
        'prefs': <String, dynamic>{
          ...await WidgetPrefs.toJson(),
          ...await WidgetPrefs.appearanceFor('schedule'),
        },
        'courses': todayCourses
            .map((c) => {
                  'name': c.name,
                  'teacher': c.teacher,
                  'classroom': c.classroom,
                  'startSlot': c.startSlot,
                  'endSlot': c.endSlot,
                  // v1.6.9：色条跟随「课节色块色彩方案」——在 Dart 侧就把颜色算成
                  // 最终值下发，原生侧不用再实现一遍调色逻辑（改方案后重新同步即可）。
                  'color': courseColorFor(
                          c.colorValue, CourseStorage.schemeCache)
                      .toARGB32(),
                  'timeText': timeTextFor(c, slotTimes),
                  // v2.2.14：分钟制起止时刻，供原生「下一节课」按当前时间精确切换
                  'startMinute': _slotMinute(c.startSlot, slotTimes, isStart: true),
                  'endMinute': _slotMinute(c.endSlot, slotTimes, isStart: false),
                })
            .toList(),
        // 🔴 2026-11-04 修「跨零点后小组件取不到数据」：
        //    以前只下发「今天」的课，过了零点这份数据就废了，而重算只能靠
        //    Dart —— 全仓没有任何后台入口能跑 Dart（没注册 WorkManager /
        //    backgroundCallback）。于是早上第一次看桌面，小号组件永远停在
        //    「点击刷新今日课表」，直到用户打开一次 App。
        //    现在把**整学期**一并下发，由 Kotlin 在发现数据过期时就地重算。
        'allCourses': _allCourseDefs(courses, slotTimes),
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
      // ③ 记成功快照（2026-11-03）：只写不读没有意义 —— 自检卡要能证明
      //    「Dart 跑到了这一步」，否则原生侧 rawLength=0 时无从判断是
      //    「没调用」还是「调用了但抛异常」。
      await WidgetSyncStatus.recordSuccess(
        week: week,
        courseCount: todayCourses.length,
        tableName: table.name,
      );
    } catch (e, st) {
      // 静默失败：小组件保持上次状态，不影响 App 使用。
      // 但**必须留下证据**（2026-11-03）：此前这里是纯 `catch (_) {}`，
      // 于是「同步抛异常」与「今天没课」在界面上完全一样。
      await WidgetSyncStatus.recordFailure(e, st);
    } finally {
      // ②-b 同进程直调渲染（2026-11-04）。
      //
      // 上面那三次 `updateWidget` 只是 `sendBroadcast(ACTION_APPWIDGET_UPDATE)`，
      // 广播投递不到（ROM 拦隐式广播 / 组件被系统归档 / owner 正在恢复）时
      // `onUpdate` 根本不来，桌面上就永远是 `initialLayout` 的 XML 占位文字：
      // **既没有数据，也没有 onUpdate 里 setOnClickPendingIntent 打上去的点击
      // 响应** —— 这正是「点又点不了、又不显示数据，但 App 内自检正常」的形状。
      // 这条通道直接从 MethodChannel 调渲染器，绕开广播。
      //
      // 🔴 2026-11-04 晚：**这一步从 try 体里挪到了 finally**。
      //    原来它排在 `saveWidgetData` + 三次 `updateWidget` 之后，属于同一条
      //    线性链 —— 前面任何一步抛异常就直接跳进 catch，渲染这一步根本不会
      //    执行，桌面于是停在 XML 默认文字上。而 `saveWidgetData` 若已成功，
      //    数据其实是写进去了的，自检页会显示「数据正常」，进一步误导
      //    （用户原话：「app 内部组件自检又正常外部却无效」）。
      //    放进 finally 之后：无论存取/广播哪一步炸，渲染都会跑一次。
      await renderNow();
    }
  }

  /// 同步信息型组件（考试倒计时 / 校园卡余额）。
  /// 都不在小组件里联网，只展示本地缓存；App 启动或数据更新时推一次。
  static Future<void> syncInfoWidgets() async {
    // 2026-11-04 晚：`Future.wait` 只要有**任何一个**抛异常就整体抛，
    // 原来排在它后面的 `renderNow()` 会被直接跳过 —— 三个信息组件于是
    // 一起停在 XML 默认文字上。这里逐个子任务兜底，让 `renderNow` 无条件跑到。
    // （`syncExamWidget` 等自身已有 try，但 `syncCountdownWidget` 里的
    //  `CountdownStore.ensureLoaded()` 会抛，不能只靠内部 catch。）
    for (final task in <Future<void> Function()>[
      syncExamWidget,
      syncCardWidget,
      syncCountdownWidget,
    ]) {
      try {
        await task();
      } catch (e, st) {
        await WidgetSyncStatus.recordFailure(e, st);
      }
    }
    // 同 syncTodayCourses 的理由：广播不可靠，补一次同进程直调。
    await renderNow();
  }

  static Future<void> syncExamWidget() async {
    try {
      final exam = await ExamStorage.nextExam();
      final meta = exam == null
          ? ''
          : [
              _ymd(exam.date),
              if (exam.startTime.isNotEmpty) exam.startTime,
              if (exam.classroom.isNotEmpty) exam.classroom,
            ].join(' · ');
      final json = jsonEncode({
        'hasExam': exam != null,
        'name': exam?.name ?? '',
        'daysLeft': exam?.daysLeft ?? 0,
        'date': exam == null ? '' : _ymd(exam.date),
        'startTime': exam?.startTime ?? '',
        'classroom': exam?.classroom ?? '',
        'meta': meta,
        // 2026-11-05（用户 m24495 #1）：每种组件各自的外观，
        // 不再共用全局那套（改考试不再连累课表）。
        'prefs': await WidgetPrefs.appearanceFor('exam'),
      });
      await HomeWidget.saveWidgetData<String>(_examKey, json);
      await HomeWidget.updateWidget(qualifiedAndroidName: _examProvider);
    } catch (_) {
      // 静默：信息组件失败不影响主流程
    }
  }

  static Future<void> syncCardWidget() async {
    try {
      final cache = await StorageService.loadCardBalanceCache();
      final updated = cache == null ? '' : _shortDateTime(cache.savedAt);
      final json = jsonEncode({
        'hasBalance': cache != null,
        'balance': cache?.balance ?? 0,
        'updatedText': updated,
        // 2026-11-05（用户 m24495 #1）：每种组件各自的外观，
        // 不再共用全局那套（改考试不再连累课表）。
        'prefs': await WidgetPrefs.appearanceFor('card'),
      });
      await HomeWidget.saveWidgetData<String>(_cardKey, json);
      await HomeWidget.updateWidget(qualifiedAndroidName: _cardProvider);
    } catch (_) {
      // 静默
    }
  }

  /// 倒数日小组件（2026-11-04 新增，需求 #6）。
  ///
  /// 下发的结构与课表组件不同：这里没有「今天的课」这种会过期的概念，
  /// 每条只有绝对日期，原生侧每次渲染时**自己**算「还有几天」。
  /// 所以跨零点不需要任何重算逻辑 —— `date` 不变，`daysLeft` 由原生现算，
  /// 这也是为什么这个组件天生不存在「隔天失效」的问题。
  static Future<void> syncCountdownWidget() async {
    try {
      // 🔴 必须先把仓库读出来：`forWidget` 读的是内存里的 `_items`，
      //    而冷启动时 `main()` 就已经调了 `syncInfoWidgets()` ——
      //    那一刻 CountdownStore 还没 load 过，列表恒为空，
      //    桌面就会显示「还没有倒数日」。这里自己 ensureLoaded 保证
      //    无论谁调、什么时候调，下发出去的都是真实数据。
      await CountdownStore.instance.ensureLoaded();
      final now = DateTime.now();
      final items = CountdownStore.instance.forWidget(now);
      final list = <Map<String, dynamic>>[
        for (final e in items)
          <String, dynamic>{
            'title': e.title,
            'emoji': e.emoji,
            'date':
                '${e.date.year.toString().padLeft(4, '0')}-${e.date.month.toString().padLeft(2, '0')}-${e.date.day.toString().padLeft(2, '0')}',
            'daysLeft': e.daysFrom(now),
            'note': e.note,
          },
      ];
      // 2026-11-05（用户 m24495 #3「两者都要」）：多实例绑定。
      // 除了默认的「最近 3 条」（items），额外下发**全部**条目（itemsAll，
      // 带稳定 id）。原生侧按 `cd_binding_<appWidgetId>` 里存的 id 列表挑选，
      // 这样桌面上可以放好几个倒数日组件，每个显示不同的条目。
      // items 保持不动：没有绑定记录的老组件行为完全不变。
      final allItems = <Map<String, dynamic>>[
        for (final e in CountdownStore.instance.items)
          <String, dynamic>{
            'id': e.id,
            'title': e.title,
            'emoji': e.emoji,
            'date':
                '${e.date.year.toString().padLeft(4, '0')}-${e.date.month.toString().padLeft(2, '0')}-${e.date.day.toString().padLeft(2, '0')}',
            'daysLeft': e.daysFrom(now),
            'note': e.note,
          },
      ];
      // 2026-11-05（用户 m26008 #1）：桌面两个系统组件各自绑定固定条目，
      // 无 pin 绑定时原生按 slot 取 slot0/slot1，不再依赖「先新增再添加」。
      Map<String, dynamic> slotMap(int slot) {
        final id = CountdownStore.slotId(slot);
        for (final m in allItems) {
          if (m['id'] == id) return m;
        }
        return <String, dynamic>{};
      }
      final json = jsonEncode({
        'items': list,
        'itemsAll': allItems,
        'total': CountdownStore.instance.items.length,
        'updatedDate': _ymd(now),
        // 2026-11-05（用户 m24495 #1）：每种组件各自的外观，
        // 不再共用全局那套（改考试不再连累课表）。
        'prefs': await WidgetPrefs.appearanceFor('countdown'),
        'slot0': slotMap(0),
        'slot1': slotMap(1),
      });
      await HomeWidget.saveWidgetData<String>(_countdownKey, json);
      // 两个倒数日组件都要收刷新，不能只广播第一个。
      await HomeWidget.updateWidget(qualifiedAndroidName: _countdownProvider);
      await HomeWidget.updateWidget(qualifiedAndroidName: _countdown2Provider);
    } catch (_) {
      // 静默：倒数日组件失败不影响主流程
    }
  }

  // ---------- 倒数日多实例绑定（2026-11-05，用户 m24495 #3「两者都要」）----------

  /// 绑定记录的存储前缀：`cd_binding_<appWidgetId>` → `["id1","id2"]`。
  /// 放在 home_widget 共享存储里，原生侧不需要再开一份文件。
  static String _bindKey(int appWidgetId) => 'cd_binding_$appWidgetId';

  /// 读某个组件实例绑定的倒数日 id 列表（空 = 跟随默认「最近 3 条」）。
  static Future<List<String>> countdownBinding(int appWidgetId) async {
    final raw = await HomeWidget.getWidgetData<String>(_bindKey(appWidgetId));
    if (raw == null || raw.isEmpty) return const [];
    try {
      final v = jsonDecode(raw);
      if (v is List) return v.map((e) => '$e').toList();
    } catch (_) {}
    return const [];
  }

  /// 设置绑定并立即重渲染（空列表 = 解除绑定，回到默认）。
  static Future<void> setCountdownBinding(
      int appWidgetId, List<String> ids) async {
    await HomeWidget.saveWidgetData<String>(
        _bindKey(appWidgetId), jsonEncode(ids));
    await renderNow();
  }

  /// 从 App 里直接往桌面添加一个倒数日组件，并把选中的条目绑上去。
  ///
  /// 走的是 Android 8.0+ 的 `requestPinAppWidget`（系统弹确认框），
  /// 不需要用户长按桌面找组件。`minSdk 21`，低版本返回 false，
  /// 上层据此提示「请长按桌面手动添加」。
  ///
  /// 返回值：true = 系统已接受请求（不代表用户最终点了「添加」）。
  static Future<bool> pinCountdownWidget(List<String> ids, {int slot = 0}) async {
    try {
      final ok = await _statusChannel.invokeMethod<bool>('pinCountdown',
          <String, dynamic>{'ids': ids, 'slot': slot});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 查询桌面上已添加的组件类型（课表 / 考试 / 校园卡 / 倒数日）。
  ///
  /// 🔴 **绝不能改用 `HomeWidget.getInstalledWidgets()`**（2026-11-03 修复）。
  ///
  /// home_widget 0.7.0 的 `HomeWidgetPlugin.getInstalledWidgets()` 里，
  /// 对 `AppWidgetManager.getAppWidgetInfo(widgetId)` 的返回值**不判空**就传给
  /// 非空形参 `widgetInfoToMap(widgetId, widgetInfo)`，而该 API 文档允许返回
  /// null（组件正被移除、Launcher 重建的瞬间）。一旦为 null 就抛 NPE，
  /// 且抛在平台线程的 MethodChannel handler 里 —— Dart 侧 `try/catch` 拦不住，
  /// 进程直接崩。
  ///
  /// 症状完美对应「添加桌面小组件后 App 打不开」：桌面上没有组件时循环体
  /// 一次都不进，永远不崩；一旦添加过，每次启动的页面预热
  /// （[App._prewarmPages] → `user_page._load()`）都会走到这里。
  ///
  /// 现在改走自建通道 `wxxy/widget_status`（`MainActivity.installedWidgetKinds`），
  /// 直接查 `getAppWidgetIds().isNotEmpty()` —— 天然没有 null 风险。
  static Future<Set<WidgetComponent>> installedComponents() async {
    try {
      final raw = await _statusChannel.invokeMapMethod<String, dynamic>('installed');
      if (raw == null) return {};
      final result = <WidgetComponent>{};
      if (raw['schedule'] == true) result.add(WidgetComponent.schedule);
      if (raw['exam'] == true) result.add(WidgetComponent.exam);
      if (raw['card'] == true) result.add(WidgetComponent.card);
      if (raw['countdown'] == true) result.add(WidgetComponent.countdown);
      return result;
    } catch (_) {
      return {};
    }
  }

  static const MethodChannel _statusChannel = MethodChannel('wxxy/widget_status');

  /// 同进程直调原生渲染器（2026-11-04）。
  ///
  /// 返回每个组件**真实更新到的桌面实例数**。全为 0 表示桌面上根本没有这些
  /// 组件 —— 这时无论数据写得多正确、无论 onUpdate 有没有被调，桌面都不会变。
  /// 这个数字是「App 内自检正常、桌面上却没反应」唯一能定责的证据，所以
  /// 一并记进 [WidgetSyncStatus]。
  static Future<Map<String, int>> renderNow() async {
    try {
      final raw = await _statusChannel.invokeMapMethod<String, Object?>('renderNow');
      if (raw == null) return const {};
      final counts = <String, int>{};
      for (final key in const [
        'scheduleSmall',
        'scheduleMedium',
        'scheduleLarge',
        'exam',
        'card',
        'countdown',
        'countdown2',
      ]) {
        final v = raw[key];
        counts[key] = v is num ? v.toInt() : 0;
      }
      await WidgetSyncStatus.recordInstanceCounts(counts);
      return counts;
    } catch (_) {
      return const {};
    }
  }

  /// 构建节次 → 时间文本映射：优先用户自定义时间块，否则默认表。
  ///
  /// 🔴 **区间块必须铺满它覆盖的每一节**。时间块的数据模型是
  /// `CourseBlock{start, end, time}`：默认块是「单节块」（start==end==节次），
  /// 但模型允许一个块覆盖多节（如「第 1-2 节 08:00\n09:40」）。
  /// 早先这里只按块的 `start` 建键，于是跨节的课查 `map[endSlot]` 会**落空** ——
  /// 显示退化成「第1节-2节」（完全没有时刻），分钟数还会回落到默认表。
  static Map<int, String> slotTimesFrom(List<Map<String, dynamic>>? blocks) {
    if (blocks == null || blocks.isEmpty) return _defaultSlotTimes;
    final map = <int, String>{};
    for (final b in blocks) {
      final start = (b['start'] as int?) ?? 0;
      final rawEnd = (b['end'] as int?) ?? start;
      final end = rawEnd < start ? start : rawEnd;
      final time = (b['time'] as String?) ?? '';
      if (start <= 0 || time.isEmpty) continue;
      final lines = time.split('\n');
      if (lines.length < 2) continue;
      for (var s = start; s <= end; s++) {
        map[s] = '${lines[0]}-${lines[1]}';
      }
    }
    return map;
  }

  static Future<Map<int, String>> _timeText() async =>
      slotTimesFrom(await CourseStorage.loadTimeBlocks());

  /// 一门课在小组件上显示的起止时刻（如 `08:00-09:40`）。
  ///
  /// 🔴 **唯一口径**：直接由 [startMinute] / [endMinute] 格式化，也就是原生
  /// 「下一节课」判定用的那两个数字。
  ///
  /// 早先这里是 `'${start.split('-').first}-${end.split('-').first}'` —— 两边都取
  /// **首段**。`start` 取首段是对的，`end` 取首段就把「结束节次的**开始**时刻」
  /// 当成了结束时刻：1-2 节的课本该 08:00–09:40，小组件印成 08:00–**08:55**
  /// （第 2 节的开始），整整少 45 分钟。而且同一个组件里「显示」与「判定」两套口径，
  /// 会出现「正确高亮着这节课、底下却印着错的结束时间」这种自相矛盾。
  /// 现在两者共用一份数字，结构上不可能再分叉。
  @visibleForTesting
  static String timeTextFor(Course c, Map<int, String> map) {
    final s = _slotMinute(c.startSlot, map, isStart: true);
    final e = _slotMinute(c.endSlot, map, isStart: false);
    return '${_hhmm(s)}-${_hhmm(e)}';
  }

  static String _hhmm(int minuteOfDay) {
    final h = (minuteOfDay ~/ 60).toString().padLeft(2, '0');
    final m = (minuteOfDay % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// 把整学期课程压成原生侧「就地重算」所需的扁平结构（2026-11-04 新增）。
  ///
  /// 只要三样东西就能判断「第 N 周、星期 X 有没有这门课」：
  /// 星期几、周次文本、单双周类型；再加上 Pattern（固定/每天/工作日）。
  /// 因此这里不做任何过滤，全量下发 —— 一学期 40 门课约 6 KB，
  /// 塞进 SharedPreferences 完全无压力，换掉的是「过零点就失效」。
  static List<Map<String, dynamic>> _allCourseDefs(
      List<Course> courses, Map<int, String> slotTimes) {
    return [
      for (final c in courses)
        {
          'name': c.name,
          'teacher': c.teacher,
          'classroom': c.classroom,
          'weekday': c.weekday,
          'startSlot': c.startSlot,
          'endSlot': c.endSlot,
          'color': courseColorFor(c.colorValue, CourseStorage.schemeCache).toARGB32(),
          'timeText': timeTextFor(c, slotTimes),
          'startMinute': _slotMinute(c.startSlot, slotTimes, isStart: true),
          'endMinute': _slotMinute(c.endSlot, slotTimes, isStart: false),
          // ⚠️ 原样下发（不做 parseWeeks 归一化）：原生侧用同一套规则解析，
          //    两边都过一遍 [normalizeWeeksText] 才能保证口径一致。
          'weeks': c.weeks,
          // 0 = 每双周都上 / 1 = 只单周 / 2 = 只双周
          'weekType': switch (c.weekType) {
            CourseWeekType.odd => 1,
            CourseWeekType.even => 2,
            CourseWeekType.every => 0,
          },
          // 0 = 固定星期 / 1 = 每天 / 2 = 工作日
          'pattern': switch (c.pattern) {
            CoursePattern.daily => 1,
            CoursePattern.workday => 2,
            CoursePattern.fixed => 0,
          },
        },
    ];
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

  static String _shortDateTime(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  static String _ymd(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }
}