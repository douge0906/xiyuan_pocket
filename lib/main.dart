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
import 'widgets/hand_drawn_backgrounds.dart';
import 'widgets/tap_haptics.dart';
import 'services/campus_net_monitor.dart';
import 'services/net_mode.dart';
// 🔴 2026-11-04 审查 P0：这个 import 是**唯一**让 background_reschedule.dart
//    进 AOT kernel 的入口，别删。
//    Dart AOT 按 main.dart 的 import 图裁剪 kernel，`@pragma('vm:entry-point')`
//    只在**库已被编入**时才保住符号。此前全仓没有任何文件 import 它 ——
//    于是 BootReceiver 的 executeDartEntrypoint("main.dart",
//    "notificationRescheduleEntrypoint") 抛 argumentError 被空 catch 吞掉，
//    开机补排 100% 静默失败。叠加插件 ScheduledNotificationBootReceiver 在
//    Android 14+ 因 ExactAlarmPermissionException 调
//    removeNotificationFromCache()，重启后提醒被**永久删除**，直到用户主动
//    打开 App。
//    `show` 显式掩盖「只用到这一个符号」，配合 ignore 让 analyzer 不报
//    unused_import。
// ignore: unused_import
import 'services/background_reschedule.dart' show notificationRescheduleEntrypoint;

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
  // 🔴 2026-11-04 审查 P1：**外观也必须在首帧之前读完**。
  //
  //    原来这些（明暗 / 主题色 / 背景色 / 圆角 / 字号 / 字体 / 语言）
  //    全在 `_XiYuanToolboxAppState.initState` 里异步加载，而
  //    `runApp` 前一次都没读过。于是深色 / 自定义背景 / 自定义主题色用户
  //    每次冷启动都会先看到一帧**纯白 + 墨黑主题色 + 默认字号 + 中文**，
  //    然后整树跳变到真实主题 —— 夜间启动非常刺眼。
  await loadAppearance();
  // v2.2.13 桌面小组件：启动时同步一次「今日课程」到桌面
  WidgetSyncService.syncTodayCourses();
  // 信息型组件：考试倒计时 / 校园卡余额（本地缓存）
  WidgetSyncService.syncInfoWidgets();
  // v2.2.14 外部打开 App（冷启动）使用次数 +1（静默，失败不影响）
  // v2.2.21 上课提醒：启动时重排未来 7 天课程提醒（后台执行，不阻塞启动）
  CourseReminderService.rescheduleAll();
  // 🔴 2026-11-04 审查 P0：冷装用户的上课提醒一条都不会响。
  //    `CourseReminderService.isEnabled()` 默认 `true`，UI 一路绿灯，
  //    但启动路径**从未申请过** POST_NOTIFICATIONS（targetSdk 35 →
  //    Android 13+ 新装默认拒绝）。全仓申请点只有 5 处，全在用户手动
  //    触发路径（新建带提醒待办、进设置页点按钮）。
  //    修法：首帧后一次性申请（`ensureFirstRunPermission` 内部有
  //    `hasAskedPermission()` 去重，不会每次启动都弹）；申请到就立刻
  //    重排，让第一批提醒真正落地。
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      final granted = await NotificationService.ensureFirstRunPermission();
      if (granted) await CourseReminderService.rescheduleAll();
    } catch (_) {
      // 权限申请失败不能影响启动
    }
  });
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  // 🔴 2026-11-04 审查 P2：这里原来是 `_setSystemUI` + 匿名闭包 listener，
  //    与 `app_theme.dart` 的 `_setSystemOverlay` 是**两套重复实现**（后者已经
  //    被 `AppTheme.setMode` 内部调用）。两套并存的问题是：背景色变了只有
  //    后者知道，前者永远按 121212/白 画。现在统一收口到 AppTheme，
  //    这一行只是先按当前模式铺一次初始值。
  AppTheme.refreshSystemOverlay();
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

/// 首帧之前把**外观相关**的全部设置读进来。
///
/// 🔴 2026-11-04 审查 P1：这些值原来只在 `_XiYuanToolboxAppState.initState`
/// 里异步加载，`runApp` 前一次都没读过 —— 于是深色 / 自定义背景 / 自定义
/// 主题色用户每次冷启动先看到一帧白底墨黑，再整树跳变，夜间非常刺眼。
///
/// 放在 `main()` 里 `await` 是为了让 `MaterialApp` 的**第一帧**就是最终外观。
/// 代价是启动时多几十毫秒的读盘（全是 SharedPreferences，无网络）。
Future<void> loadAppearance() async {
  try {
    final config = await StorageService.loadUserConfig();
    AppTheme.setMode(config.themeMode);
    // v1.8.0：恢复自定义主题色（0 = 未设置，保持默认墨黑）
    if (config.primaryColor != 0) {
      AppTheme.setPrimary(Color(config.primaryColor));
    }
    // v1.5.0：恢复页面背景色（2026-11-03 起浅色/深色各存一份）
    final bg = await StorageService.loadUiBackgroundColor();
    if (bg != null) AppTheme.setBackground(bg);
    final bgDark = await StorageService.loadUiBackgroundColorDark();
    if (bgDark != null) AppTheme.setBackgroundDark(bgDark);
    // 2026-11-04（实验性）：手绘纸纹背景。只存一个稳定 id（默认 none），
    // 读失败 / 遇到未知 id 都回落 none —— 绝不能让一个坏字符串挡住启动。
    await restoreHandDrawnBackground();
    // 全局圆角：启动时必须 apply 一次，否则设置页滑杆的值存了、重启却回到默认。
    AppTheme.setRadiusScale(await StorageService.loadUiRadiusScale());
    // 字体缩放 / 动画时长：启动时读出并 apply（否则设置里改了、重启就丢）。
    UiPrefs.setTextScale(await StorageService.loadUiTextScale());
    UiPrefs.setMotion(await StorageService.loadUiMotion());
    // 振动强度：2026-11-03（1.0.9）由开关升级为四档，老开关值自动迁移。
    UiPrefs.setHapticLevel(await StorageService.loadUiHapticLevel());
    // 字体族：2026-11-03 新增「通用设置 · 字体设置」，同样要启动恢复。
    UiPrefs.setFontFamily(await StorageService.loadUiFontFamily());
    await AppLocale.ensureLoaded();
  } catch (e) {
    // 外观恢复失败绝不能挡住启动，退回默认值即可。
    debugPrint('[main] 外观恢复失败，使用默认外观: $e');
  }
}

class XiYuanToolboxApp extends StatefulWidget {
  const XiYuanToolboxApp({super.key});

  @override
  State<XiYuanToolboxApp> createState() => _XiYuanToolboxAppState();
}

class _XiYuanToolboxAppState extends State<XiYuanToolboxApp>
    with WidgetsBindingObserver {
  ThemeMode _mode = AppTheme.currentMode;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 外观已在 main() 的 loadAppearance() 里读完（首帧前），这里只补一次
    // 兜底 —— 万一有异常路径没跑到，也不会卡在默认值上。
    if (AppTheme.currentMode != _mode) {
      _mode = AppTheme.currentMode;
    }
    unawaited(_loadMode());
    // 2026-10-13：圆角缩放变化 → 整树重建（圆角是 getter，必须重建才生效）
    //
    // 🔴 用**具名方法**而不是匿名闭包：匿名的无法 removeListener，
    //    App 重建时会再挂一组 → 回调无限累积（一次主题变更触发 N 次 setState）。
    AppTheme.radiusNotifier.addListener(_onRadiusChanged);
    AppTheme.modeNotifier.addListener(_onModeChanged);
    // v1.5.0：页面背景色变化 → 整树重建（主题缓存按 主色+背景色 做 key）
    AppTheme.backgroundNotifier.addListener(_onBackgroundChanged);
    // 🔴 v1.0.9：深色背景也必须挂。此前只挂了浅色那一份 → 在设置里选了深色背景，
    //    首页底色不变（`home_page` 读的是 `Theme.of(context).scaffoldBackgroundColor`，
    //    而 MaterialApp 不重建 → darkTheme 不被求值 → 缓存里还是旧底色）。
    //    浅色正常、深色失效，是个非对称 bug。
    AppTheme.backgroundDarkNotifier.addListener(_onBackgroundChanged);
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
    AppTheme.backgroundDarkNotifier.removeListener(_onBackgroundChanged);
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

  /// 兜底：外观已在 `main()` 的 [loadAppearance] 里读完。这里只在
  /// 万一那条路径失败时补一次（例如测试里直接 pumpWidget 不走 main）。
  Future<void> _loadMode() async {
    if (AppTheme.currentMode != _mode) {
      if (mounted) setState(() => _mode = AppTheme.currentMode);
    }
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
          // 同时挂上「点一下就震」的指针层监听（见 TapHapticsScope）。
          //
          // 🔴 2026-11-04（实验性）：手绘纸纹背景也挂在这里。
          //    为什么必须是这里而不是任何页面内部：五个 Tab 各自带**不透明**
          //    `Scaffold(backgroundColor: …)`，画在它们下面的纹理一行都看不见；
          //    画在 Navigator 之上才是唯一能真正「全局」的位置。
          //    纹理层内部是 `IgnorePointer`，不吃任何点击 / 滚动 / 手势；
          //    `none` 时 `buildHandDrawnBackground` 直接原样返回 child，零开销。
          //
          //    用 ValueListenableBuilder 包一层（而不是直接读
          //    `handDrawnBackgroundNotifier.value`）：MaterialApp 本身不会因
          //    这个 notifier 重建，直接读的话在设置页选完要等下次别的原因重建
          //    才生效。这里只重建这一层，Navigator（child）原样复用。
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: UiPrefs.textScaler),
            child: TapHapticsScope(
              child: ValueListenableBuilder<HandDrawnBackground>(
                valueListenable: handDrawnBackgroundNotifier,
                builder: (ctx, kind, __) => buildHandDrawnBackground(
                  kind,
                  // builder 的 context 在 `AnimatedTheme` 之内（framework
                  // `_materialBuilder` 用 Builder 隔了一层），能读到当前主题。
                  isDark: Theme.of(ctx).brightness == Brightness.dark,
                  child: child!,
                ),
              ),
            ),
          ),
          // 🔴 2026-11-03（1.0.9）：语言切换后除少数几个页面外全 App 不跟着变。
          //    根因是 `home: const MainApp()` —— const 实例，`AppLocale.notifier`
          //    变化只能让 MaterialApp 自己重建，MainApp 子树纹丝不动。
          //    给 MainApp 换 key 会强制丢弃整棵子树重建，语言才真正全局生效；
          //    key 只在语言变化时才换，不影响别的重建路径。
          //    注意 key 加在 `home` 而不是 `builder` 的 child 上：后者会把
          //    Navigator 一起重建，用户正在子页面切语言会被弹回首页。
          home: MainApp(key: ValueKey<String>('locale-${AppLocale.current.code}')),
        ),
        ),
        ),
      ),
    );
  }
}
