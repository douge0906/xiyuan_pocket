import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';
import 'pages/home_page.dart';
import 'pages/notification_page.dart';
import 'pages/toolbox_page.dart';
import 'pages/user_page.dart';
import 'pages/course_table_home_page.dart';
import 'services/nav_prefs.dart';
import 'services/course_storage.dart';
import 'services/course_sync_service.dart';
import 'theme/app_theme.dart';

/// 小组件点击 → 切 Tab 的全局桥（2026-10-12，v1.7.0 改为按页面身份寻址）。
///
/// 为什么需要它：小组件被点击时 App 可能刚冷启动，那时 [MainApp] 还没 build 完，
/// 外部拿不到它的 State 去切 Tab。这里由 [MainApp] 在 initState 注册回调，
/// 监听方（本文件 [_MainAppState._handleWidgetClick]）只管调用，不关心时序。
///
/// 🔴 v1.7.0：底部导航项可隐藏 / 可排序之后，**下标不再稳定**
///    （隐藏一项，后面的全部前移）→ 原来写死的 `courseIndex = 2` 会跳错页。
///    现在一律传 [NavPage] 身份，由 MainApp 自己算当前下标。
class AppTabs {
  AppTabs._();

  static void Function(NavPage page)? switchTo;

  /// 请求切换到某页。目标页被用户隐藏时不生效（它不在导航里，翻不过去）。
  static void go(NavPage page) => switchTo?.call(page);

  /// 小组件点击 → 直达课表页。
  static void goCourse() => go(NavPage.course);
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> with TickerProviderStateMixin {
  /// 当前页（**页面身份**，不是下标 —— 见 [AppTabs] 的说明）。
  NavPage _current = NavPage.home;

  final _homeKey = GlobalKey<HomePageState>();

  /// 页面实例按身份存（顺序变了也不用重建）。
  late final Map<NavPage, Widget> _pages;

  /// 每个页面一个入场动画控制器，同样按身份存。
  late final Map<NavPage, AnimationController> _controllers;

  /// 已经访问过的页面（懒加载）：未访问的页保持空占位，避免启动瞬间把所有页
  /// 一起初始化（各自的网络请求 / 弹窗会挤在同一时刻）。
  /// 访问过一次后永久保活，切 Tab 不再销毁重建 State。
  final Set<NavPage> _visited = <NavPage>{};

  @override
  void initState() {
    super.initState();
    _pages = <NavPage, Widget>{
      NavPage.home: HomePage(key: _homeKey),
      NavPage.message: const NotificationPage(),
      NavPage.course: const CourseTableHomePage(),
      NavPage.service: const ToolboxPage(),
      NavPage.user: const UserPage(),
    };
    _controllers = <NavPage, AnimationController>{
      for (final p in NavPage.values)
        p: AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 300),
        ),
    };
    // v1.7.1：进入 App 的**实际初始页 = 用户排在最前面的那一页**。
    //  · 导航没动过 → 还是首页（老行为完全不变）；
    //  · 首页被挪到后面 / 被隐藏 → 就以当前排第一的那页作为进入页，
    //    不再硬回首页（那样会「一进来就跳到中间那格」，和用户排的顺序对着干）。
    // NavPrefs 在 main() 里已 await 加载过，这里读到的一定是用户的真实布局。
    _current = NavPrefs.initialPage;
    _visited.add(_current);
    _controllers[_current]!.value = 1.0;
    // 用户在设置页改了导航（隐藏 / 排序）→ 立即重排底部导航
    NavPrefs.notifier.addListener(_onNavLayoutChanged);
    // 2026-10-18 用户要求：**删除免责声明弹窗**（不再在启动时弹）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoUpdateCourseTable());
    _registerTabBridge();
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleWidgetClick());
  }

  /// 导航布局变化（设置页里改的）：重绘即可；若**当前页被隐藏了**，
  /// 还要把落点挪到仍然可见的第一页，否则 IndexedStack 找不到当前页。
  void _onNavLayoutChanged() {
    if (!mounted) return;
    final visible = NavPrefs.visible;
    if (visible.contains(_current)) {
      setState(() {});
      return;
    }
    _controllers[_current]!.reverse();
    setState(() {
      _current = visible.first;
      _visited.add(_current);
    });
    _controllers[_current]!.forward();
  }

  /// 小组件点击直达课表（2026-10-12）。
  ///
  /// 两条入口都要接：
  ///  · [HomeWidget.initiallyLaunchedFromHomeWidget] —— App 是**被小组件冷启动**的；
  ///  · [HomeWidget.widgetClicked] —— App 已在后台/前台，点小组件被唤起。
  /// 原生侧（TodayWidgetRenderer.pendingOpenApp）把点击做成
  /// `homewidget://course`，这里收到就切到课表 Tab。
  Future<void> _handleWidgetClick() async {
    try {
      final initial = await HomeWidget.initiallyLaunchedFromHomeWidget();
      if (initial != null) AppTabs.goCourse();
      HomeWidget.widgetClicked.listen((uri) {
        if (uri != null) AppTabs.goCourse();
      });
    } catch (_) {
      // 拿不到就算了：最多是点了小组件只打开 App 首页，不影响其它功能
    }
  }

  /// 「进入 App 自动更新课表」（开关在课表设置页，**默认开**）。
  ///
  /// 为什么挂在这里而不是课表页：课表页是 IndexedStack 里的**懒加载** Tab，
  /// 要等用户第一次点「课表」才初始化。挂在那里就变成「第一次点开课表才更新」，
  /// 不是「进入 App 就更新」。挂在这里才算数。
  ///
  /// **全程静默**：还没登录、教务系统 00:00-6:00 关闭、网络不通 —— 都会失败，
  /// 这些都不该在启动时弹东西打扰用户；失败也**不会**动已有课表
  /// （CourseSyncService 里挡着「失败≠空」）。
  Future<void> _autoUpdateCourseTable() async {
    try {
      final s = await CourseStorage.loadDisplaySettings();
      // 缺字段按默认开处理（老用户升级上来不会因为没这个 key 而不更新）
      if (s['autoUpdateOnLaunch'] == false) return;
      if (!mounted) return;
      await CourseSyncService.sync(
          ProviderScope.containerOf(context, listen: false));
    } catch (_) {
      // 静默：自动同步失败不影响任何功能，用户随时可用课表页刷新键手动同步
    }
  }


  // 2026-10-18：免责声明弹窗按用户要求**整段删除**（连同「不再提醒」的读写入口）。

  @override
  void dispose() {
    NavPrefs.notifier.removeListener(_onNavLayoutChanged);
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onTap(NavPage page) {
    if (page == _current) return;
    _controllers[_current]!.reverse();
    setState(() {
      _current = page;
      _visited.add(page);
    });
    _controllers[_current]!.forward();
  }

  /// 小组件点击直达课表（2026-10-12）：把切 Tab 的能力暴露出去。
  ///
  /// 桌面小组件被点击时，App 冷启动或从后台唤起，main.dart 收到
  /// home_widget 的 URI 后调 [AppTabs.goCourse] → 这里切到课表 Tab。
  /// 与 [_onTap] 走同一套逻辑（保活 + 动画），不另开一条路径。
  void _registerTabBridge() {
    AppTabs.switchTo = (page) {
      if (!mounted) return;
      // 该页被用户隐藏了 → 没有对应的导航项，翻不过去，静默忽略
      if (!NavPrefs.visible.contains(page)) return;
      if (page == _current) {
        setState(() => _visited.add(page));
        return;
      }
      _onTap(page);
    };
  }

  @override
  Widget build(BuildContext context) {
    // 导航项的顺序 / 显隐完全由 NavPrefs 决定（设置页改完立即生效）。
    final visible = NavPrefs.visible;
    // 兜底：当前页万一不在可见集合里（极端时序），落位到第一页而不是越界崩溃。
    final current = visible.contains(_current) ? _current : visible.first;
    return Scaffold(
      // v2.4.0：改用 IndexedStack 保活各 Tab —— 此前 AnimatedSwitcher 会在切换时
      // 销毁旧页 State，导致切回首页/消息页时全部重建（重复请求、滚动位置丢失、
      // 列表闪一下）。IndexedStack 保留每个页面的 State，仅切换可见性。
      // 注意：切页不加任何位移 / 缩放 / 淡入过渡，直接硬切 —— 整页位移会让人
      // 产生「页面在滑动漂移」的错觉，v2.4.0 已移除该过渡。
      //
      // 🔴 v1.7.0：导航项可排序后 children 的**位置会变**，IndexedStack 是按位置
      // 匹配 child 的 —— 不加 key 的话重排会让 State 挂到错误的页面上（页面错乱 /
      // State 被重建）。所以每个 child 都套一层 KeyedSubtree(ValueKey(页面))，
      // 让 State 跟着**页面**走，而不是跟着位置走。
      body: IndexedStack(
        index: visible.indexOf(current),
        // 未访问过的页面用空占位（懒加载），访问过的一直保活（不重建 State）。
        children: <Widget>[
          for (final p in visible)
            KeyedSubtree(
              key: ValueKey<NavPage>(p),
              child: _visited.contains(p) ? _pages[p]! : const SizedBox.shrink(),
            ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1E1E1E) : Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          child: SizedBox(
            height: 72,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                for (final p in visible)
                  _NavButton(
                    page: p,
                    selected: p == current,
                    controller: _controllers[p]!,
                    onTap: _onTap,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  final NavPage page;
  final bool selected;
  final AnimationController controller;
  final ValueChanged<NavPage> onTap;

  const _NavButton({
    required this.page,
    required this.selected,
    required this.controller,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final scale = 1.0 + (controller.value * 0.12);
        return GestureDetector(
          onTap: () => onTap(page),
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: 70,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Transform.scale(
                  scale: scale,
                  child: Icon(
                    selected ? page.activeIcon : page.icon,
                    color: selected
                        ? AppTheme.primaryColor
                        : (isDark ? Colors.grey.shade600 : const Color(0xFF9CA3AF)),
                    size: 24,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  page.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected
                        ? AppTheme.primaryColor
                        : (isDark ? Colors.grey.shade600 : const Color(0xFF9CA3AF)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
