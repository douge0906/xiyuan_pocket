import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';
import 'pages/home_page.dart';
import 'pages/notification_page.dart';
import 'pages/toolbox_page.dart';
import 'pages/user_page.dart';
import 'pages/course_table_home_page.dart';
import 'services/app_locale.dart';
import 'services/current_tab.dart';
import 'services/nav_prefs.dart';
import 'services/app_update_service.dart';
import 'services/course_storage.dart';
import 'services/course_sync_service.dart';
import 'services/legal_consent.dart';
import 'theme/app_theme.dart';
import 'widgets/pressable.dart';

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


  /// 用户**当前正在看**的页（预热阶段不算）。
  ///
  /// 页面用它判断「一次性引导弹窗现在该不该弹」——
  /// App 启动会预热所有 Tab（消除切页闪烁），
  /// 引导若在 initState 触发就会在启动时误弹。
  static NavPage currentPage = NavPage.home;

  /// 请求切换到某页。目标页被用户隐藏时不生效（它不在导航里，翻不过去）。
  static void go(NavPage page) => switchTo?.call(page);

  /// 小组件点击 → 直达课表页。
  static void goCourse() => go(NavPage.course);

  /// 小组件点击 → 服务页 / 我的页。
  static void goService() => go(NavPage.service);
  static void goUser() => go(NavPage.user);
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> with TickerProviderStateMixin {
  /// 小组件点击订阅（dispose 时取消）。
  StreamSubscription<Uri?>? _widgetSub;

  /// **切页淡入**控制器。
  ///
  /// ⚠️ 只能用于 **opacity**：Flutter 的 `RenderOpacity` 只改
  ///    `OpacityLayer.alpha`，子树一个像素都不重画 → **不会重新栅格化文字**。
  ///
  /// 🚫 绝对不能改用 scale / translate / 位移：
  ///    `RenderTransform` 会把**分数偏移**直接加到 paint offset 上
  ///    （Flutter 框架层没有像素对齐），文字按新的亚像素位置重画 →
  ///    肉眼看到「抖一下」。这正是 2026-10-30 移除整页过渡的原因。
  late final AnimationController _pageFadeCtrl;

  /// 淡入动画时长。短一点更有「利落」感，长一点更「柔和」。
  static const Duration _pageFadeDuration = Duration(milliseconds: 180);

  /// 当前页（**页面身份**，不是下标 —— 见 [AppTabs] 的说明）。
  NavPage _current = NavPage.home;
  int _navDragIndex = 0;
  double _navDragStartX = 0;
  bool _navDragMoved = false;


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
    // 语言切换：MaterialApp 重建不一定会重建本页（home 是 const 实例），
    // 这里自己监听一次，保证底栏标签立即换语言。
    AppLocale.notifier.addListener(_onLocaleChanged);
    // 背景设置异步加载完成 / 用户改背景时，重算导航栏透明态
    CourseStorage.bgRevision.addListener(_onBgChanged);
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
    AppTabs.currentPage = _current;
    CurrentTab.set(_navRef(_current));
    _visited.add(_current);
    _controllers[_current]!.value = 1.0;

    // 切页淡入控制器：只驱动 opacity。
    _pageFadeCtrl = AnimationController(
      vsync: this,
      duration: _pageFadeDuration,
      value: 1.0,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      CurrentTab.notifyEntered(_navRef(_current));
    });
    // 用户在设置页改了导航（隐藏 / 排序）→ 立即重排底部导航
    NavPrefs.notifier.addListener(_onNavLayoutChanged);
    // 2026-10-18 用户要求：**删除免责声明弹窗**（不再在启动时弹）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoUpdateCourseTable());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppUpdateService.checkAndPrompt(context);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensurePrivacyConsent());
    _registerTabBridge();
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleWidgetClick());
    // 🔴 预热全部 Tab（2026-10-30 六次自检）。
    //
    // 之前未访问过的页面用 SizedBox.shrink() 占位，**切过去时才第一次构建** →
    // initState → 空列表 → 数据到达 → 内容「从无到有」地跳一下，
    // 表现为消息列表、课表课程块、余额卡片在切页瞬间闪烁。
    //
    // 现在首帧后一次性把所有页面建好并保活：
    //   · 切页时页面已有内容 → 无「空 → 满」的跳变；
    //   · IndexedStack 本来就只绘制当前页，其余页不产生绘制开销。
    WidgetsBinding.instance.addPostFrameCallback((_) => _prewarmPages());
  }

  /// 首次启动隐私政策确认：拒绝则退出 App，同意后进入。
  Future<void> _ensurePrivacyConsent() async {
    if (!mounted) return;
    final ok = await LegalConsentService.ensureConsent(context);
    if (!ok) {
      await SystemNavigator.pop();
    }
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
      void route(Uri? uri) {
        if (uri == null) return;
        switch (uri.host) {
          case 'exam':
            AppTabs.goService();
            return;
          case 'card':
            AppTabs.goUser();
            return;
          default:
            AppTabs.goCourse();
        }
      }

      final initial = await HomeWidget.initiallyLaunchedFromHomeWidget();
      route(initial);
      // 🔴 订阅必须保存并在 dispose 里取消：MainApp 被重建时
      //    旧订阅仍在 → 点一次小组件会触发多次 route（重复切 Tab）。
      _widgetSub?.cancel();
      _widgetSub = HomeWidget.widgetClicked.listen(route);
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
    AppLocale.notifier.removeListener(_onLocaleChanged);
    _widgetSub?.cancel();
    _widgetSub = null;
    _pageFadeCtrl.dispose();
    CourseStorage.bgRevision.removeListener(_onBgChanged);
    NavPrefs.notifier.removeListener(_onNavLayoutChanged);
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 首帧后预热所有 Tab：一次性把未访问过的页面也加入 [_visited]。
  ///
  /// 用 [Future.delayed] 再错开一拍：不要和首帧的渲染抢同一帧，
  /// 否则首屏会掉帧。
  Future<void> _prewarmPages() async {
    // 🔴 分批预热：每 400ms 建一个 Tab。
    //
    // 一次性全建 → 各页 initState 同时发起请求（网络风暴 + 首屏卡）；
    // 分批建 → 请求错开，且**页面内容在用户切过去之前就已经渲染好**，
    // 切页时是「硬切到已就绪的内容」，不会有「空 → 满」的闪动。
    for (final p in NavPage.values) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      if (_visited.contains(p)) continue;
      setState(() {
        _visited.add(p);
      });
    }
  }

  /// NavPage → 不依赖 app.dart 的轻量枚举（供 CurrentTab 使用）。
  static NavPageRef _navRef(NavPage p) {
    switch (p) {
      case NavPage.home:
        return NavPageRef.home;
      case NavPage.message:
        return NavPageRef.message;
      case NavPage.course:
        return NavPageRef.course;
      case NavPage.service:
        return NavPageRef.service;
      case NavPage.user:
        return NavPageRef.user;
    }
  }

  void _onLocaleChanged() {
    if (mounted) setState(() {});
  }

  void _onTap(NavPage page) {
    if (page == _current) return;
    _controllers[_current]!.reverse();
    setState(() {
      _current = page;
      _visited.add(page);
    });
    AppTabs.currentPage = page;
    _controllers[_current]!.forward();
    // 页面淡入：只改 opacity（不重栅格化文字），给切页一点「质感」。
    _pageFadeCtrl.forward(from: 0);
    // 通知目标页「用户真正进来了」→ 一次性引导在这里弹（而非 initState）。
    CurrentTab.notifyEntered(_navRef(page));
    // 切回首页时重新加载待办并播放一次入场。
    if (page == NavPage.home) {
      _homeKey.currentState?.onHomeTabResumed();
    }
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

  /// 导航栏底色：课表页有自定义背景色时跟着染，其余页面用默认底色。
  void _onBgChanged() {
    if (mounted) setState(() {});
  }

  Color _navBackground(BuildContext context, NavPage current) {
    final base = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF1E1E1E)
        : Colors.white;
    if (current != NavPage.course) return base;
    final c = CourseStorage.backgroundColorCache;
    // 半透明背景色叠在底色上，避免导航栏比页面更透、露出内容
    return c == null ? base : Color.alphaBlend(Color(c), base);
  }

  @override
  Widget build(BuildContext context) {
    // 导航项的顺序 / 显隐完全由 NavPrefs 决定（设置页改完立即生效）。
    final visible = NavPrefs.visible;
    // 兜底：当前页万一不在可见集合里（极端时序），落位到第一页而不是越界崩溃。
    final current = visible.contains(_current) ? _current : visible.first;
    // 课表页 + 背景图：导航栏透明，并让 body 延伸到导航栏下方，
    // 这样背景图才能真正透上来（否则透明只会露出 Scaffold 底色）
    // 课表页有任何自定义背景（图或纯色）都让 body 延伸到导航栏下方 ——
    // 纯色时导航栏要「带点透」，不延伸的话透明只会露出同色底、看不出效果
    final hasColorBg = CourseStorage.backgroundColorCache != null;
    final navClear = current == NavPage.course &&
        (CourseStorage.backgroundImageCache.isNotEmpty || hasColorBg);
    return Scaffold(
      extendBody: navClear,
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
      // 🔴 整页不做**位移动画 / 缩放动画**（2026-10-30 七次自检）。
      //
      // 整页 scale / 位移会让文字在动画期间被重新栅格化
      // （文字按新比例/新亚像素位置重画）→ 消息列表、课表课程块、
      // 余额卡片这类重页面会肉眼看到「抖一下 / 闪一下」。
      // 页面内容本身**硬切**，只在切页瞬间对当前页补一次极短 opacity 落定
      // （见下面 AnimatedBuilder：0.55→1.0，下限 0.55 的缘由写在注释里）。
      //
      // 正式 App 的做法也是**硬切**：iOS / Material 的 Tab 切换都不动页面内容，
      // 只让底部指示条和图标做动画 —— 观感干净，且完全不触发重绘。
      body: IndexedStack(
        index: visible.indexOf(current),
        // 未访问过的页面用空占位（懒加载），访问过的一直保活（不重建 State）。
        //
        // 🔴 **所有页的结构必须完全一致**（都套 AnimatedBuilder + Opacity）。
        //    如果写成「当前页套动画、其它页不套」，切页时该页在元素树里的
        //    位置会变（从直接子节点变成 AnimatedBuilder 的 child）→
        //    Flutter 会**销毁并重建**它的 State → 页面重新请求数据、
        //    滚动位置丢失、列表闪一下 —— 正是 IndexedStack 要避免的。
        //    现在结构恒定，只有 opacity 数值在变。
        children: <Widget>[
          for (final p in visible)
            KeyedSubtree(
              key: ValueKey<NavPage>(p),
              child: _visited.contains(p)
                  ? AnimatedBuilder(
                      animation: _pageFadeCtrl,
                      builder: (context, child) {
                        // 非当前页保持完全不透明（视觉上无变化）。
                        if (p != current) return child!;
                        // 当前页做一次「落定」淡入。
                        // 下限取 0.55 而不是 0：opacity 为 0 时 RenderOpacity
                        // 会判定 paintsChild==false 而**跳过整棵子树绘制**，
                        // 那一帧是空白 → 反而更闪。
                        final v = Curves.easeOutCubic.transform(_pageFadeCtrl.value);
                        return Opacity(
                          opacity: 0.55 + 0.45 * v,
                          child: child,
                        );
                      },
                      child: _pages[p],
                    )
                  : const SizedBox.shrink(),
            ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          // 课表页的自定义背景色要连导航栏一起染（像 WakeUp 课程表那样整屏一致）；
          // 半透明色叠在底色上，避免导航栏比页面更透。
          // 透明态一律用 transparent：0.92 这种「差一点点」的透明度会
          // 在导航栏上沿形成一条明显色带（2026-10-26 用户反馈）
          color: navClear
              ? Colors.transparent
              : _navBackground(context, current),
          // 透明态不能留阴影：阴影画在导航栏上方，会变成一条渐变暗带
          boxShadow: navClear
              ? const []
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 20,
                    offset: const Offset(0, -4),
                  ),
                ],
        ),
        child: SafeArea(
          child: SizedBox(
            height: 56,
            child: LayoutBuilder(
              builder: (context, box) {
                final itemW = box.maxWidth / visible.length;
                final index = visible.indexOf(current);
                final isDark =
                    Theme.of(context).brightness == Brightness.dark;
                // 「按住 → 横向滑动 → 切到那一页」的跟手切换。
                //
                // ⚠️ 之前是**按下即切**：onPointerDown 里直接 switchToX，
                //    结果轻点和拖动没区别 —— 用户按住想拖，系统在按下瞬间
                //    就跳页了，后面再拖又是另一页，看起来就是「滑动无效」。
                // 现在：按下只记录起点，横向位移**超过阈值**才跟手切页；
                //      没超过阈值就当普通点击（交给 _NavButton 的 Pressable）。
                void switchToX(double x) {
                  final target = (x / itemW)
                      .floor()
                      .clamp(0, visible.length - 1);
                  if (target == _navDragIndex) return;
                  _navDragIndex = target;
                  _onTap(visible[target]);
                }

                return Listener(
                  onPointerDown: (event) {
                    _navDragIndex = index;
                    _navDragStartX = event.localPosition.dx;
                    _navDragMoved = false;
                  },
                  onPointerMove: (event) {
                    final dx = event.localPosition.dx - _navDragStartX;
                    if (!_navDragMoved && dx.abs() < 18) return;
                    _navDragMoved = true;
                    switchToX(event.localPosition.dx);
                  },
                  onPointerUp: (_) {
                    _navDragMoved = false;
                  },
                  onPointerCancel: (_) {
                    _navDragMoved = false;
                  },
                  child: Stack(
                    children: [
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 320),
                      // 轻微回弹：指示条到位时有一点「冲过头再回落」，
                      // 这是「有质感」的关键。回弹幅度很小（easeOutBack 默认
                      // 约 10%），不会显得廉价。
                      curve: Curves.easeOutBack,
                      left: itemW * index + 6,
                      top: 5,
                      bottom: 5,
                      width: itemW - 12,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppTheme.primaryColor
                              .withValues(alpha: isDark ? .14 : .08),
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: Row(
                        children: <Widget>[
                          for (final p in visible)
                            Expanded(
                              child: _NavButton(
                                page: p,
                                selected: p == current,
                                controller: _controllers[p]!,
                                onTap: _onTap,
                              ),
                            ),
                        ],
                      ),
                    ),
                    ],
                  ),
                );
              },
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
        // 弹性缩放：overshoot 一下再回落，比线性放大更有弹性。
        final t = controller.value;
        final scale = 1.0 + (Curves.easeOutBack.transform(t.clamp(0, 1)) * 0.14);
        return Pressable(
          onTap: () => onTap(page),
          haptic: true,
          scale: 0.92,
          child: SizedBox(
            width: double.infinity,
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
                  S.t('nav_${page.id}'),
                  style: TextStyle(
                    fontSize: AppTheme.fontCaption,
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
