import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
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

  /// 申请通知（Android 13+）+ 精确闹钟（Android 12+）权限。
  /// v2.2.21：权限已回归 Manifest，此处正常弹系统授权；异常仍安全降级返回 false。
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
        return granted;
      } catch (e) {
        debugPrint('通知权限申请失败（权限已移除，安全降级）: $e');
        return false;
      }
    }
    return true;
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
  static final Int64List _vibrationPattern =
      Int64List.fromList([0, 500, 250, 500, 250, 500]);

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
  }) =>
      _androidDetailsFor(
        channelId: course ? 'course_reminder_channel_v1' : 'todo_reminder_channel_v3',
        channelName: course ? '上课提醒' : '待办提醒',
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
  /// - 精确闹钟权限缺失时降级 [AndroidScheduleMode.inexactAllowWhileIdle]；
  /// - [course]=true 走「上课提醒」独立渠道（v2.2.21）；
  /// - [bigText] 非空用大文本样式，锁屏/展开显示完整信息（v2.3.0）；
  /// - [countdownTarget] 非空：通知内嵌系统实时倒计时到该时刻，到点自动消失
  ///   （v2.3.3，ongoing 常驻防误划，仅 Android 生效，iOS 忽略）；
  /// - [autoDismissSeconds] 非空且无 countdownTarget 时：通知展示 N 秒后自动撤下
  ///   （v2.3.7「不悬挂」模式，默认 5 秒，避免长期占用状态栏）。
  static Future<void> schedule({
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
  }) async {
    await init();
    if (!_available) return; // 初始化失败时静默返回

    final details = NotificationDetails(
      android: _detailsFor(
        course: course,
        bigText: bigText,
        countdownTarget: Platform.isAndroid ? countdownTarget : null,
        postedAt: Platform.isAndroid ? scheduledTime : null,
        ongoing: ongoing,
        autoDismissSeconds: autoDismissSeconds,
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

    try {
      await doSchedule(AndroidScheduleMode.exactAllowWhileIdle);
    } on PlatformException catch (e) {
      // v2.2.23 修复：插件 v19 的异常码是 exact_alarms_not_permitted（复数），
      // 旧代码匹配 'exact_alarm_not_permitted'（单数）永不命中 → 降级从未生效。
      // 现在精确排程的任何异常都降级为非精确，确保提醒仍能触发（可能晚数分钟）。
      debugPrint('精确排程失败(${e.code})，降级为非精确: ${e.message}');
      try {
        await doSchedule(AndroidScheduleMode.inexactAllowWhileIdle);
      } catch (e2) {
        debugPrint('通知降级调度失败: $e2');
      }
    } catch (e) {
      debugPrint('通知调度未知异常: $e');
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
