import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tz_data;

/// 纯通知服务：只负责初始化、权限、调度、取消。
///
/// 边界约束：
/// - **不感知业务数据**（不读数据库、不认识 Todo 列表），业务编排交给 Repository；
/// - **不直接操作 UI**：用户点击通知后，仅把携带的 Todo id 写入 [pendingTodoId]，
///   由页面监听后自行导航定位，服务层与 UI 解耦。
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  /// v2.1.0 曾按用户要求从 Manifest 移除权限并静默禁用；
  /// v2.2.21 恢复权限（POST_NOTIFICATIONS 回归 Manifest），本地提醒重新可用。
  /// 初始化失败时安全降级：所有 schedule/cancel 静默无操作，绝不影响 App 主体。
  static bool _available = true;

  /// 被点击的通知携带的 Todo id（payload）。页面监听此值以定位对应待办。
  /// 消费后应置回 null，避免重复触发。
  static final ValueNotifier<String?> pendingTodoId = ValueNotifier<String?>(null);

  static Future<void> init() async {
    if (_initialized) return;
    try {
      tz_data.initializeTimeZones();

      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      const initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _plugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: _onTap,
        onDidReceiveBackgroundNotificationResponse: _onTapBackground,
      );

      // 建渠道必须在任何通知发出**之前** —— 渠道设置一旦被系统锁定就改不动了。
      await _ensureChannels();

      // 冷启动：若 App 是被点击通知拉起的，取出 payload 供页面定位。
      try {
        final launch = await _plugin.getNotificationAppLaunchDetails();
        if (launch?.didNotificationLaunchApp == true) {
          final payload = launch?.notificationResponse?.payload;
          if (payload != null && payload.isNotEmpty) {
            pendingTodoId.value = payload;
          }
        }
      } catch (_) {
        // 获取启动详情失败不影响初始化
      }
    } catch (e) {
      // 权限移除/初始化失败：标记不可用，后续操作全部静默
      debugPrint('通知初始化失败，本地提醒已禁用: $e');
      _available = false;
    }
    _initialized = true;
  }

  /// 前台/后台运行时点击通知的回调。
  static void _onTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload != null && payload.isNotEmpty) {
      pendingTodoId.value = payload;
    }
  }

  /// 后台（进程被系统回收后）点击通知的顶层回调。
  @pragma('vm:entry-point')
  static void _onTapBackground(NotificationResponse response) {
    // 后台隔离区无法直接导航，此处仅占位；冷启动时由 init() 的
    // getNotificationAppLaunchDetails 再次读取 payload 完成定位。
  }

  /// 是否已经问过用户通知权限（`POST_NOTIFICATIONS` 是否已「问过」）。
  ///
  /// Android 13+ 的 `POST_NOTIFICATIONS` 有「未询问 / 已拒绝 / 已允许」三态。
  /// 首次启动时「未询问」就该问一次；用户明确拒绝后不该反复骚扰。
  static Future<bool> hasAskedPermission() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kAskedNotify) ?? false;
    } catch (_) {
      return false;
    }
  }

  static const String _kAskedNotify = 'notify_permission_asked_v1';

  static Future<void> _markAskedPermission() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAskedNotify, true);
    } catch (_) {
      // 记不住也不影响本次
    }
  }

  /// 申请通知（Android 13+）+ 精确闹钟（Android 12+）权限。
  /// v2.2.21：权限已回归 Manifest，此处正常弹系统授权；异常仍安全降级返回 false。
  ///
  /// 2026-11-02：申请过就记一笔，供 [ensureFirstRunPermission] 判断要不要再问。
  static Future<bool> requestPermission() async {
    if (!_available) return false;
    if (Platform.isAndroid) {
      try {
        final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        final granted =
            await androidPlugin?.requestNotificationsPermission() ?? false;
        try {
          await androidPlugin?.requestExactAlarmsPermission();
        } catch (_) {
          // 部分系统无此权限概念，忽略。
        }
        await _markAskedPermission();
        return granted;
      } catch (e) {
        debugPrint('通知权限申请失败（权限已移除，安全降级）: $e');
        return false;
      }
    }
    return true;
  }

  /// 首启（或首次需要提醒时）问一次通知权限。
  ///
  /// ## 🔴 为什么必须补这个（2026-11-02 修「通知不到位」）
  ///
  /// 全仓 grep 的结果是：`requestPermission()` 只有**三个**调用点 ——
  /// 「提醒设置」页、「通知设置」页、「课程提醒测一次」按钮。
  /// **启动路径、创建待办路径一次都没有。**
  ///
  /// 于是 Android 13+ 用户的真实经历是：
  ///   装 App → 建一条带提醒的待办 → 到点 → **什么也没有发生**。
  ///   因为 `POST_NOTIFICATIONS` 从未被申请，系统直接静默丢弃通知。
  ///   用户不会想到「我要去设置页里找权限」，只会说「这 App 提醒不响」。
  ///
  /// 这里只在**用户真的要用提醒**时（创建带提醒的待办 / 首次进首页）
  /// 问一次，被拒绝过就不再纠缠。
  static Future<bool> ensureFirstRunPermission() async {
    await init();
    if (!_available) return false;
    if (!Platform.isAndroid) return true;
    if (await notificationsEnabled()) {
      // 已经有了就别打扰；顺手确认精确闹钟（不弹窗，只查）。
      return true;
    }
    if (await hasAskedPermission()) return false; // 问过了，尊重用户选择
    return requestPermission();
  }

  /// 一次「为什么可能不响」的自检快照（2026-11-02）。
  ///
  /// ## 为什么需要这个
  ///
  /// 用户反馈「通知不到位」，而通知链路上有**四个**互相独立的失望点：
  ///
  ///   1. `POST_NOTIFICATIONS` 没授予（Android 13+，覆盖安装不会继承）；
  ///   2. 「闹钟和提醒」特殊权限没开（Android 12+，14+ 默认关）；
  ///   3. 精确闹钟排程被拒后**三级降级全失败**（`schedule()` 返回 false，
  ///      原来这个返回值没有任何调用方检查）；
  ///   4. 系统队列里压根没排上（`pendingCount() == 0`）。
  ///
  /// 前两项可以在设置页手动修，后两项只能靠**当场重排**。
  /// 这份快照就是为了让「设置页 / 首页」能一句话说清到底卡在哪一步，
  /// 而不是笼统地弹「请检查通知权限」。
  static Future<String> diagnose() async {
    await init();
    if (!_available) {
      return '通知模块初始化失败，本地提醒不可用（可能是系统限制或权限被移除）';
    }
    final notifyOn = await notificationsEnabled();
    if (!notifyOn) {
      return '系统通知权限被关闭 —— 到「短信/通知」权限里允许掌上锡院显示通知';
    }
    final exact = await exactAlarmsEnabled();
    final queued = await pendingCount();
    if (exact && queued > 0) {
      return '通知权限正常，系统队列里有 $queued 条待触发提醒';
    }
    if (exact && queued == 0) {
      // 没有待触发的不一定是坏事：可能确实没有未来提醒。
      // 但如果用户说「该响没响」，这条就是最可疑的信号。
      return '通知权限正常，但系统队列里没有任何待触发提醒 '
          '—— 可能是重排没跑成功，试着到「提醒设置」点一次重排';
    }
    if (!exact) {
      return '「闹钟和提醒」权限未开启 —— Android 12+ 会因此把精确闹钟降级，'
          '短延时提醒可能延迟十几分钟甚至不响';
    }
    return '通知状态未知';
  }

  /// 系统通知总开关是否已开启（Android 13+ 即 POST_NOTIFICATIONS 运行时权限）。
  /// 覆盖安装不会自动授予该权限——这是「提醒全都不响」的头号原因。
  static Future<bool> notificationsEnabled() async {
    await init();
    if (!_available) return false;
    if (!Platform.isAndroid) return true;
    try {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await androidPlugin?.areNotificationsEnabled() ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 申请「闹钟和提醒」特殊权限（Android 12+ 出现；Android 14+ 默认关闭，
  /// 未授予时精确闹钟降级为非精确——有约 15 分钟最小窗口，短延时闹钟会"看起来没触发"）。
  /// 首次调用会跳转系统设置页，用户需打开「闹钟和提醒」开关。返回当前是否可用。
  static Future<bool> ensureExactAlarmPermission() async {
    await init();
    if (!_available) return false;
    if (!Platform.isAndroid) return true;
    try {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final granted = await androidPlugin?.requestExactAlarmsPermission();
      return granted ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 系统队列中待触发的定时提醒条数（自检用：0=没排上，>0=已排上等系统触发）。
  static Future<int> pendingCount() async {
    await init();
    if (!_available) return 0;
    try {
      final list = await _plugin.pendingNotificationRequests();
      return list.length;
    } catch (_) {
      return -1;
    }
  }

  /// 「闹钟和提醒」精确闹钟权限是否已授予（纯查询，不会跳转系统页）。
  static Future<bool> exactAlarmsEnabled() async {
    if (!Platform.isAndroid) return true;
    try {
      final status = await Permission.scheduleExactAlarm.status;
      return status.isGranted;
    } catch (_) {
      return true;
    }
  }

  /// 震动模式：0ms 起 → 震500 → 停250 → 震500 → 停250 → 震500。
  ///
  /// ⚠️ Android 8.0+ 的震动**由通知渠道决定**，而不是单条通知的
  ///    `builder.setVibrate()`。渠道一旦建立，其 importance / 震动 / 铃声
  ///    就被系统锁定，App 后续改 `AndroidNotificationDetails` **不生效**。
  ///    所以渠道必须在**首次使用前**用正确的参数显式创建。
  static final Int64List _vibrationPattern =
      Int64List.fromList([0, 500, 250, 500, 250, 500]);

  /// 「上课提醒」渠道 id。
  ///
  /// ⚠️ 渠道设置不可改：一旦要调整震动/铃声/重要性，**必须升版本号**
  ///    （v1 → v2 …），否则老用户设备上的旧渠道会继续沿用旧设置。
  static const String channelCourse = 'course_reminder_channel_v2';

  /// 「待办提醒」渠道 id（同样已因震动配置升过版本）。
  static const String channelTodo = 'todo_reminder_channel_v4';

  // ---------------------------------------------------------------------------
  // 优先级 → 通知渠道（2026-10-31）
  //
  // ⚠️ 为什么必须分渠道：
  //    **Android 8.0+ 的振动模式由「通知渠道」决定**，单条通知的
  //    `builder.setVibrate()` 在渠道存在时**不生效**。
  //    所以「紧急程度 → 振动强度」要做对，就得给不同优先级**不同渠道**。
  //
  // ⚠️ 渠道 id 必须带版本后缀：渠道设置一旦创建就被系统锁死，
  //    改了振动强度只能换新 id（见上面 channelTodo 的说明）。
  // ---------------------------------------------------------------------------

  /// 普通优先级渠道（短促单震）。
  static const String channelTodoNormal = 'todo_reminder_normal_v1';

  /// 重要优先级渠道（双震，比普通更明显）。
  static const String channelTodoImportant = 'todo_reminder_important_v1';

  /// 紧急优先级渠道（长震三连，最强）。
  static const String channelTodoUrgent = 'todo_reminder_urgent_v1';

  /// 各优先级的振动模式（毫秒）。
  ///
  /// - 普通：短促一下，不打扰；
  /// - 重要：两下，节奏分明；
  /// - 紧急：长震三连，锁屏也能感知。
  static final Int64List _vibrationNormal =
      Int64List.fromList([0, 200]);
  static final Int64List _vibrationImportant =
      Int64List.fromList([0, 300, 200, 300]);
  static final Int64List _vibrationUrgent =
      Int64List.fromList([0, 600, 300, 600, 300, 600]);

  /// 优先级（0 普通 / 1 重要 / 2 紧急）→ 渠道 id。
  static String channelForPriority(int priority) {
    if (priority >= 2) return channelTodoUrgent;
    if (priority == 1) return channelTodoImportant;
    return channelTodoNormal;
  }

  /// 优先级 → 振动模式。
  static Int64List vibrationForPriority(int priority) {
    if (priority >= 2) return _vibrationUrgent;
    if (priority == 1) return _vibrationImportant;
    return _vibrationNormal;
  }

  /// 是否已建过渠道（避免每次排程都重复调用）。
  static bool _channelsReady = false;

  /// **显式创建通知渠道**（Android 8.0+ 必做）。
  ///
  /// 🔴 为什么必须显式建：插件在 `showNotification` 内部会顺带建渠道，
  ///    但那走的是「渠道不存在才建」的分支（`canCreateNotificationChannel`），
  ///    一旦渠道已存在就**永远不更新** —— 震动、铃声、重要性全部锁死在
  ///    第一次创建时的值。用户反馈「通知没有震动」正是这个原因：
  ///    最早建渠道时没配震动，之后无论怎么改详情都不生效。
  ///
  /// 这里用 [AndroidNotificationChannelAction.update] 显式写一次，
  /// 保证渠道的震动 / 铃声 / 重要性按当前配置落地。
  static Future<void> _ensureChannels() async {
    if (_channelsReady || !Platform.isAndroid) return;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return;

      Future<void> create(
        String id,
        String name,
        String description, {
        Int64List? vibration,
      }) async {
        await android.createNotificationChannel(
          AndroidNotificationChannel(
            id,
            name,
            description: description,
            // 最高重要性：横幅 + 悬浮窗 + 震动。
            importance: Importance.max,
            playSound: true,
            enableVibration: true,
            vibrationPattern: vibration ?? _vibrationPattern,
            enableLights: true,
            ledColor: const Color(0xFF6C5CE7),
            audioAttributesUsage: AudioAttributesUsage.notification,
          ),
        );
      }

      /// 带指定振动模式的渠道（优先级用）。
      Future<void> createVibrating(
        String id,
        String name,
        String description,
        Int64List vibration,
      ) =>
          create(id, name, description, vibration: vibration);

      await create(
        channelCourse,
        '上课提醒',
        '课前提醒：即将开始的课程（响铃 + 震动 + 锁屏显示）',
      );
      await create(
        channelTodo,
        '待办提醒',
        '掌上锡院待办事项提醒（响铃 + 震动 + 锁屏显示）',
      );

      // 优先级渠道：各自独立的振动强度（Android 8+ 渠道的振动不可变）。
      await createVibrating(
        channelTodoNormal,
        '待办提醒 · 普通',
        '普通优先级待办（轻微震动）',
        _vibrationNormal,
      );
      await createVibrating(
        channelTodoImportant,
        '待办提醒 · 重要',
        '重要优先级待办（双次震动）',
        _vibrationImportant,
      );
      await createVibrating(
        channelTodoUrgent,
        '待办提醒 · 紧急',
        '紧急优先级待办（强烈震动）',
        _vibrationUrgent,
      );

      // 清理历史渠道：旧版本用过 v1/v3，改了震动/铃声后渠道设置被系统锁死，
      // 只能换新 id 生效。旧渠道留着会让用户的系统设置里出现一堆同名渠道。
      for (final old in const ['course_reminder_channel_v1', 'todo_reminder_channel_v3']) {
        try {
          await android.deleteNotificationChannel(old);
        } catch (_) {
          // 渠道不存在 / 系统不支持 → 忽略。
        }
      }
      _channelsReady = true;
    } catch (e) {
      // 建渠道失败不致命：插件仍会在发通知时顺带建一个默认渠道。
      debugPrint('创建通知渠道失败: $e');
    }
  }

  /// 通知渠道详情（重要级 max、响铃、震动、锁屏可见、默认铃声）。
  /// 渠道创建后设置不可改，如需调整音频用途/震动须升新渠道 id。
  /// [bigText] 非空时用大文本样式（锁屏/展开显示完整信息）。
  /// [whenMs]+[usesChronometer]：系统原生计时器（v2.3.3 倒计时效果的基础，
  /// 由系统渲染，零耗电）；[chronometerCountDown]=true 时倒着数（API 24+，低版本自动退化）。
  /// [timeoutAfterMs]：通知发布该时长后由系统自动撤下（如上课瞬间自动消失）。
  static AndroidNotificationDetails _androidDetailsFor({
    required String channelId,
    required String channelName,
    required String channelDescription,
    String? bigText,
    int? whenMs,
    bool usesChronometer = false,
    bool chronometerCountDown = false,
    int? timeoutAfterMs,
    bool ongoing = false,
  }) =>
      AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: channelDescription,
        importance: Importance.max,
        priority: Priority.max,
        playSound: true, // 使用系统默认通知铃声
        enableVibration: true,
        vibrationPattern: _vibrationPattern,
        enableLights: true,
        ledColor: const Color(0xFF6C5CE7),
        ledOnMs: 1000,
        ledOffMs: 500,
        visibility: NotificationVisibility.public,
        fullScreenIntent: true,
        category: AndroidNotificationCategory.reminder,
        // v2.3.4 UI 精修：品牌紫 accent（部分 ROM 会给标题/按钮着色）
        color: const Color(0xFF6C5CE7),
        when: whenMs,
        usesChronometer: usesChronometer,
        chronometerCountDown: chronometerCountDown,
        timeoutAfter: timeoutAfterMs,
        ongoing: ongoing,
        // 走「通知/铃声音量」而非「闹钟音量」，避免用户没调闹钟音量时听不到。
        audioAttributesUsage: AudioAttributesUsage.notification,
        styleInformation: bigText == null
            ? null
            : BigTextStyleInformation(
                bigText,
                summaryText: '掌上锡院',
              ),
      );

  /// 统一构造：按 [course] 选渠道，可选 [bigText] 大文本样式（v2.3.0）；
  /// [countdownTarget] 非空时启用系统原生倒计时（v2.3.3）：通知由系统渲染
  /// 实时倒数到该时刻，[scheduledTime]（发布时刻）过后 timeoutAfter 自动撤下。
  static AndroidNotificationDetails _detailsFor({
    required bool course,
    String? bigText,
    DateTime? countdownTarget,
    DateTime? postedAt,
    bool ongoing = false,
    int? autoDismissSeconds,
    int priority = 0,
  }) =>
      _androidDetailsFor(
        // 🔴 待办按优先级走**不同渠道**：Android 8+ 的振动模式由渠道决定，
        //    单条通知的 setVibrate 不生效 → 想让「紧急」震得更强，
        //    必须给它一个振动更强的渠道。
        channelId: course ? channelCourse : channelForPriority(priority),
        channelName: course
            ? '上课提醒'
            : (priority >= 2
                ? '待办提醒 · 紧急'
                : (priority == 1 ? '待办提醒 · 重要' : '待办提醒 · 普通')),
        channelDescription: course
            ? '课前提醒：即将开始的课程（响铃 + 震动 + 锁屏显示）'
            : '掌上锡院待办事项提醒（响铃 + 震动 + 锁屏显示）',
        bigText: bigText,
        whenMs: countdownTarget?.millisecondsSinceEpoch,
        usesChronometer: countdownTarget != null,
        chronometerCountDown: countdownTarget != null,
        timeoutAfterMs: (countdownTarget != null && postedAt != null)
            ? countdownTarget.difference(postedAt).inMilliseconds
            : (autoDismissSeconds == null ? null : autoDismissSeconds * 1000),
        ongoing: ongoing,
      );

  static const DarwinNotificationDetails _iosDetails =
      DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
    interruptionLevel: InterruptionLevel.timeSensitive,
  );

  /// 调度一条定时提醒。所有平台异常均被 try/catch 吞掉并记录，绝不导致崩溃。
  /// - 优先 [AndroidScheduleMode.exactAllowWhileIdle]；
  /// - 精确排程被系统拒绝时降级 [AndroidScheduleMode.alarmClock]（不需
  ///   SCHEDULE_EXACT_ALARM，Doze 下也准时，代价是状态栏出现闹钟图标）；
  /// - 闹钟模式仍失败时再降级 [AndroidScheduleMode.inexactAllowWhileIdle]；
  /// - [course]=true 走「上课提醒」独立渠道（v2.2.21）；
  /// - [bigText] 非空用大文本样式，锁屏/展开显示完整信息（v2.3.0）；
  /// - [countdownTarget] 非空：通知内嵌系统实时倒计时到该时刻，到点自动消失
  ///   （v2.3.3，ongoing 常驻防误划，仅 Android 生效，iOS 忽略）；
  /// - [autoDismissSeconds] 非空且无 countdownTarget 时：通知展示 N 秒后自动撤下
  ///   （v2.3.7「不悬挂」模式，默认 5 秒，避免长期占用状态栏）。
  static Future<bool> schedule({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    String? payload,
    bool course = false,
    String? bigText,
    DateTime? countdownTarget,
    bool ongoing = false,
    int? autoDismissSeconds,
    /// **安卓通知岛（实时更新 / 流体云）**。
    ///
    /// 🔴 Android 16 的实时更新有硬性前提：通知必须 **ongoing（常驻）**
    ///    + **usesChronometer（系统倒计时）** 同时成立，且系统授予
    ///    POST_PROMOTED_NOTIFICATIONS 权限。三者缺一就不提升为胶囊。
    ///
    /// 「不悬挂」模式下通知 5 秒就撤下（autoDismissSeconds），
    /// 既不常驻也无倒计时 → **永远进不了通知岛**。
    /// 所以通知岛必须走独立的常驻+倒计时通道。
    bool liveUpdate = false,
    /// 待办优先级（0 普通 / 1 重要 / 2 紧急）—— 决定通知渠道与振动强度。
    int priority = 0,
  }) async {
    /// 返回是否真的排上（false = 初始化失败或三级降级全部失败）。
    await init();
    if (!_available) return false; // 初始化失败时静默返回

    final details = NotificationDetails(
      android: _detailsFor(
        course: course,
        bigText: bigText,
        countdownTarget: Platform.isAndroid ? countdownTarget : null,
        postedAt: Platform.isAndroid ? scheduledTime : null,
        ongoing: ongoing || liveUpdate,
        autoDismissSeconds: liveUpdate ? null : autoDismissSeconds,
        priority: priority,
      ),
      iOS: _iosDetails,
    );
    final when = tz.TZDateTime.from(scheduledTime.toUtc(), tz.UTC);

    Future<void> doSchedule(AndroidScheduleMode mode) =>
        _plugin.zonedSchedule(
          id,
          title,
          body,
          when,
          details,
          androidScheduleMode: mode,
          payload: payload,
        );

    // 排程降级链（2026-10-31）：
    //
    //   ① exactAllowWhileIdle —— 最准，但需要「闹钟和提醒」权限
    //      （SCHEDULE_EXACT_ALARM）。Android 14+ 默认不授予。
    //   ② alarmClock —— **不需要该权限**，系统 setAlarmClock 在 Doze /
    //      应用 standby 下也能准时唤醒（代价：状态栏出现一个闹钟图标）。
    //      这是「清除后台后收不到提醒」的关键兜底。
    //   ③ inexactAllowWhileIdle —— 最后兜底，能响但可能延迟数小时。
    //
    // ⚠️ 原来只有 ①→③，中间的 ② 被跳过：没权限时直接退到 inexact，
    //    Doze 下延迟极大 → 用户感知「提醒不响」。
    try {
      await doSchedule(AndroidScheduleMode.exactAllowWhileIdle);
      return true;
    } on PlatformException catch (e) {
      debugPrint('精确排程失败(${e.code})，改用闹钟模式: ${e.message}');
      try {
        await doSchedule(AndroidScheduleMode.alarmClock);
        return true;
      } catch (e2) {
        debugPrint('闹钟模式失败($e2)，降级为非精确');
        try {
          await doSchedule(AndroidScheduleMode.inexactAllowWhileIdle);
          return true;
        } catch (e3) {
          debugPrint('通知降级调度失败: $e3');
        }
      }
    } catch (e) {
      debugPrint('通知调度未知异常: $e');
    }
    return false;
  }

  /// 立即发一条测试通知（设置页「自检」用）。
  /// 返回是否发送成功（权限被拒时系统会静默丢弃，这里只代表调用没抛异常）。
  static Future<bool> showTestNotification() async {
    await init();
    if (!_available) return false;
    try {
      await _plugin.show(
        999001,
        '掌上锡院 · 通知测试',
        '如果你看到这条通知，说明通知权限与渠道都工作正常。',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            channelTodo,
            '待办提醒',
            channelDescription: '掌上锡院待办提醒（测试）',
            importance: Importance.max,
            priority: Priority.max,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        payload: 'notification_test',
      );
      return true;
    } catch (e) {
      debugPrint('测试通知发送失败: $e');
      return false;
    }
  }

  static Future<void> cancel(int id) async {
    await init();
    try {
      await _plugin.cancel(id);
    } catch (e) {
      debugPrint('取消通知失败: $e');
    }
  }

  static Future<void> cancelAll() async {
    await init();
    try {
      await _plugin.cancelAll();
    } catch (e) {
      debugPrint('清空通知失败: $e');
    }
  }
}
