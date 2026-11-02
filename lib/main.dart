import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'services/control_service.dart';
import 'services/course_reminder_service.dart';
import 'repositories/todo_repository.dart';
import 'services/home_prefs.dart';
import 'services/app_locale.dart';
import 'services/ui_prefs.dart';
import 'services/nav_prefs.dart';
import 'services/notification_service.dart';
import 'services/storage_service.dart';
import 'services/seed_data.dart';
import 'services/message_migration.dart';
import 'services/widget_sync_service.dart';
import 'theme/app_theme.dart';
import 'services/campus_net_monitor.dart';
import 'services/net_mode.dart';

/// 全局路由观察者，用于页面恢复时刷新数据
final RouteObserver<ModalRoute> routeObserver = RouteObserver<ModalRoute>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 本地通知初始化（时区数据库 / 通知渠道）。
  // ⚠️ 2026-10-20 审查：原注释声称"v1.4.0 全局错误上报"，但全库没有任何
  // 错误处理器（FlutterError.onError / runZonedGuarded 均无）——已改为实话。
  await NotificationService.init();
  // 首次启动把**内置的爬取快照**写进本地缓存 → 消息页首次打开秒出内容。
  // 只在首次运行写一次，之后照常走「缓存 + 刷新」流程。
  // 🔴 顺序不能反：先把老键的缓存迁到新档案键，再让种子补缺位。
  // 反了的话，种子会给老用户写回一份**更旧**的快照。
  await MessageMigration.ensureMigrated();
  await SeedData.ensureApplied();
  // v1.7.0 底部导航布局（顺序 / 隐藏）：**首帧之前**读完，
  // 否则启动会先按出厂顺序画一遍导航条、再跳成用户的顺序，肉眼可见地闪。
  await NavPrefs.ensureLoaded();
  // v1.7.2 首页板块显隐（首页个性化设置）：同样在**首帧之前**读完 ——
  // 否则被隐藏掉的板块会先按默认画一帧再消失，肉眼可见地闪。
  await HomePrefs.ensureLoaded();
  // v2.2.13 桌面小组件：启动时同步一次「今日课程」到桌面
  WidgetSyncService.syncTodayCourses();
  // 信息型组件：考试倒计时 / 校园卡余额（本地缓存）
  WidgetSyncService.syncInfoWidgets();
  // v2.2.14 外部打开 App（冷启动）使用次数 +1（静默，失败不影响）
  // v2.2.21 上课提醒：启动时重排未来 7 天课程提醒（后台执行，不阻塞启动）
  CourseReminderService.rescheduleAll();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  _setSystemUI(AppTheme.modeNotifier.value);
  AppTheme.modeNotifier.addListener(() => _setSystemUI(AppTheme.modeNotifier.value));
  // 校园网状态改为全局监控：重连后 60s 内自动更新
  CampusNetMonitor.instance.start();
  // 内网路径探测：**进 App 探一次**（直连 / 校外网关 / 都不通），
  // 不 await —— 探测最多几秒，不能挡住首屏。结果由 NetMode.notifier 广播。
  NetMode.bind(); // 全局监听校园网变化（不依赖首页卡片是否挂载）
  NetMode.probe();
  // 控制台预热：未登录统一认证时整段空转，一次请求都不发。
  unawaited(ControlService.warmUp());
  runApp(const ProviderScope(child: XiYuanToolboxApp()));
}

void _setSystemUI(ThemeMode mode) {
  // 「跟随系统」时按系统实际亮度算状态栏图标颜色。
  final isDark = switch (mode) {
    ThemeMode.dark => true,
    ThemeMode.light => false,
    ThemeMode.system =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark,
  };
  SystemChrome.setSystemUIOverlayStyle(
    SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      // 状态栏图标亮度跟随主题：深色模式用浅色图标，浅色模式用深色图标。
      // 原实现恒为 Brightness.light，导致浅色页面（如服务页 F5F6F8）图标看不清
      // （代码审查报告前端第 8 项）。
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: isDark ? const Color(0xFF121212) : Colors.white,
      systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    ),
  );
}

class XiYuanToolboxApp extends StatefulWidget {
  const XiYuanToolboxApp({super.key});

  @override
  State<XiYuanToolboxApp> createState() => _XiYuanToolboxAppState();
}

class _XiYuanToolboxAppState extends State<XiYuanToolboxApp>
    with WidgetsBindingObserver {
  ThemeMode _mode = ThemeMode.light;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadMode();
    // 2026-10-13：圆角缩放变化 → 整树重建（圆角是 getter，必须重建才生效）
    //
    // 🔴 用**具名方法**而不是匿名闭包：匿名的无法 removeListener，
    //    App 重建时会再挂一组 → 回调无限累积（一次主题变更触发 N 次 setState）。
    AppTheme.radiusNotifier.addListener(_onRadiusChanged);
    AppTheme.modeNotifier.addListener(_onModeChanged);
    // v1.5.0：页面背景色变化 → 整树重建（主题缓存按 主色+背景色 做 key）
    AppTheme.backgroundNotifier.addListener(_onBackgroundChanged);
  }

  void _onRadiusChanged() {
    if (mounted) setState(() {});
  }

  void _onModeChanged() {
    if (mounted) setState(() => _mode = AppTheme.modeNotifier.value);
  }

  void _onBackgroundChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppTheme.radiusNotifier.removeListener(_onRadiusChanged);
    AppTheme.modeNotifier.removeListener(_onModeChanged);
    AppTheme.backgroundNotifier.removeListener(_onBackgroundChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // v2.2.13：从后台回到前台时刷新桌面小组件（跨天/课程变更场景）
    if (state == AppLifecycleState.resumed) {
      WidgetSyncService.syncTodayCourses();
      unawaited(ControlService.warmUp());
      // 🔴 2026-10-31：回前台时**重排全部本地提醒**。
      //
      //    很多国产 ROM 的「后台清理 / 一键清理」会连 AlarmManager 里的
      //    定时闹钟一起清掉（不只是杀进程）→ 用户回前台后闹钟已经没了，
      //    表现就是「清除后台后收不到提醒」。
      //    这里在回前台时重排一次，把被清掉的闹钟补回来
      //    （重排幂等：会先取消再按当前数据重建，不会重复通知）。
      unawaited(_rescheduleAllReminders());
    }
  }

  /// 重排所有本地提醒（待办 + 上课）。
  ///
  /// 失败静默：重排只是兜底，不该因为它影响 App 启动或切前台。
  Future<void> _rescheduleAllReminders() async {
    try {
      await TodoRepository.instance.rescheduleAll();
      await CourseReminderService.rescheduleAll();
    } catch (e) {
      debugPrint('回前台重排提醒失败: $e');
    }
  }

  Future<void> _loadMode() async {
    final config = await StorageService.loadUserConfig();
    AppTheme.setMode(config.themeMode);
    // v1.8.0：恢复自定义主题色（0 = 未设置，保持默认墨黑）
    if (config.primaryColor != 0) {
      AppTheme.setPrimary(Color(config.primaryColor));
    }
    // v1.5.0：恢复页面背景色（浅色模式生效；null = 默认）
    final bg = await StorageService.loadUiBackgroundColor();
    if (bg != null) AppTheme.setBackground(bg);
    // 全局圆角：启动时必须 apply 一次，否则设置页滑杆的值存了、重启却回到默认。
    AppTheme.setRadiusScale(await StorageService.loadUiRadiusScale());
    // 字体缩放 / 动效强度：启动时读出并 apply（否则设置里改了、重启就丢）。
    UiPrefs.setTextScale(await StorageService.loadUiTextScale());
    UiPrefs.setMotion(await StorageService.loadUiMotion());
    UiPrefs.setHaptics(await StorageService.loadUiHaptics());
    await AppLocale.ensureLoaded();
    if (mounted) setState(() => _mode = config.themeMode);
  }

  @override
  Widget build(BuildContext context) {
    // 主题色可在设置页改动，用 ValueListenableBuilder 驱动 MaterialApp 重建，
    // 使全局（按钮 / 选中态 / 强调色）立即跟随。
    // 圆角同理：设置页一改就整树重建，否则回到别的页面还是旧圆角。
    return ValueListenableBuilder<double>(
      valueListenable: AppTheme.radiusNotifier,
      builder: (context, _, __) => ValueListenableBuilder<int>(
        valueListenable: UiPrefs.notifier,
        builder: (context, _, ___) => ValueListenableBuilder<int>(
        valueListenable: AppLocale.notifier,
        builder: (context, _, ____) => ValueListenableBuilder<Color>(
        valueListenable: AppTheme.primaryNotifier,
        builder: (context, _, __) => MaterialApp(
          title: '掌上锡院',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: _mode,
          navigatorObservers: [routeObserver],
          // 全局字体缩放：所有文字一起放大/缩小（系统级观感）。
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: UiPrefs.textScaler),
            child: child!,
          ),
          home: const MainApp(),
        ),
        ),
        ),
      ),
    );
  }
}
