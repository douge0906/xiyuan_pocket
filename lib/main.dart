import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'pages/splash_page.dart';
import 'services/course_reminder_service.dart';
import 'services/home_prefs.dart';
import 'services/nav_prefs.dart';
import 'services/notification_service.dart';
import 'services/storage_service.dart';
import 'services/seed_data.dart';
import 'services/message_migration.dart';
import 'services/widget_sync_service.dart';
import 'theme/app_theme.dart';

/// 全局路由观察者，用于页面恢复时刷新数据
final RouteObserver<ModalRoute> routeObserver = RouteObserver<ModalRoute>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // v1.4.0 全局错误上报：必须在 runApp 之前安装，才能捕获启动期异常。
  await NotificationService.init();
  // 开源版：首次启动把**内置的爬取快照**写进本地缓存 → 消息页首次打开秒出内容。
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
  // v2.2.14 外部打开 App（冷启动）使用次数 +1（静默，失败不影响）
  // v2.2.21 上课提醒：启动时重排未来 7 天课程提醒（后台执行，不阻塞启动）
  CourseReminderService.rescheduleAll();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  _setSystemUI(AppTheme.modeNotifier.value);
  AppTheme.modeNotifier.addListener(() => _setSystemUI(AppTheme.modeNotifier.value));
  runApp(const ProviderScope(child: XiYuanToolboxApp()));
}

void _setSystemUI(ThemeMode mode) {
  // 主题只有「浅色 / 深色」两种（「跟随系统」已取消）
  final isDark = mode == ThemeMode.dark;
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
    AppTheme.radiusNotifier.addListener(() {
      if (mounted) setState(() {});
    });
    AppTheme.modeNotifier.addListener(() {
      if (mounted) setState(() => _mode = AppTheme.modeNotifier.value);
    });
    // v1.5.0：页面背景色变化 → 整树重建（主题缓存按 主色+背景色 做 key）
    AppTheme.backgroundNotifier.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // v2.2.13：从后台回到前台时刷新桌面小组件（跨天/课程变更场景）
    if (state == AppLifecycleState.resumed) {
      WidgetSyncService.syncTodayCourses();
      // v1.4.0：回到前台时补报离线期间积压的错误
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
    if (mounted) setState(() => _mode = config.themeMode);
  }

  @override
  Widget build(BuildContext context) {
    // 主题色可在设置页改动，用 ValueListenableBuilder 驱动 MaterialApp 重建，
    // 使全局（按钮 / 选中态 / 强调色）立即跟随。
    return ValueListenableBuilder<Color>(
      valueListenable: AppTheme.primaryNotifier,
      builder: (context, _, __) => MaterialApp(
        title: '掌上锡院',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: _mode,
        navigatorObservers: [routeObserver],
        home: const SplashPage(),
      ),
    );
  }
}
