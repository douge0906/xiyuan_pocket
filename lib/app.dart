import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'pages/home_page.dart';
import 'pages/notification_page.dart';
import 'pages/toolbox_page.dart';
import 'pages/user_page.dart';
import 'pages/course_table_home_page.dart';
import 'services/course_storage.dart';
import 'services/course_sync_service.dart';
import 'services/storage_service.dart';
import 'theme/app_theme.dart';

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> with TickerProviderStateMixin {
  int _currentIndex = 0;
  final _homeKey = GlobalKey<HomePageState>();
  late final List<Widget> _pages;
  late final List<AnimationController> _controllers;

  /// 已经访问过的 Tab（懒加载）：未访问的页保持空占位，避免启动瞬间把所有页
  /// 一起初始化（各自的网络请求 / 弹窗会挤在同一时刻）。
  /// 访问过一次后永久保活，切 Tab 不再销毁重建 State。
  final Set<int> _visited = {0};

  @override
  void initState() {
    super.initState();
    _pages = [
      HomePage(key: _homeKey),
      const NotificationPage(),
      const CourseTableHomePage(), // 底部中间：课表（主页样式）
      const ToolboxPage(),
      const UserPage(),
    ];
    _controllers = List.generate(
      _pages.length,
      (index) => AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 300),
      ),
    );
    _controllers[_currentIndex].value = 1.0;
    WidgetsBinding.instance.addPostFrameCallback((_) => _showDisclaimerIfNeeded());
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoUpdateCourseTable());
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


  Future<void> _showDisclaimerIfNeeded() async {
    final dismissed = await StorageService.loadDisclaimerDismissed();
    if (!mounted || dismissed) return;
    _showDisclaimer();
  }

  void _showDisclaimer() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            SizedBox(width: 8),
            Text('免责声明', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: const SingleChildScrollView(
          child: Text(
            '1. 本工具由个人开发者与 AI 辅助设计，并非无锡学院官方产品，与学校无隶属或合作关系。\n\n'
            '2. 通过非官方客户端访问教务系统可能违反学校相关规定；若学校禁止第三方工具，请立即停止使用。\n\n'
            '3. 本app数据已进行加密，因使用本工具导致的任何账号、数据风险及后果，由使用者自行承担，开发者不承担责任。',
            style: TextStyle(fontSize: 12.5, height: 1.6),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await StorageService.saveDisclaimerDismissed(true);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('不再提醒', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('我已知晓并继续使用', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _onTap(int index) {
    if (index == _currentIndex) return;
    _controllers[_currentIndex].reverse();
    setState(() {
      _currentIndex = index;
      _visited.add(index);
    });
    _controllers[_currentIndex].forward();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // v2.4.0：改用 IndexedStack 保活各 Tab —— 此前 AnimatedSwitcher 会在切换时
      // 销毁旧页 State，导致切回首页/消息页时全部重建（重复请求、滚动位置丢失、
      // 列表闪一下）。IndexedStack 保留每个页面的 State，仅切换可见性。
      // 注意：切页不加任何位移 / 缩放 / 淡入过渡，直接硬切 —— 整页位移会让人
      // 产生「页面在滑动漂移」的错觉，v2.4.0 已移除该过渡。
      body: IndexedStack(
        index: _currentIndex,
        // 未访问过的 Tab 用空占位（懒加载），访问过的一直保活（不重建 State）。
        children: List<Widget>.generate(
          _pages.length,
          (i) => _visited.contains(i) ? _pages[i] : const SizedBox.shrink(),
        ),
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
              children: [
                _NavButton(
                  index: 0,
                  currentIndex: _currentIndex,
                  icon: Icons.home_rounded,
                  activeIcon: Icons.home_rounded,
                  label: '首页',
                  controller: _controllers[0],
                  onTap: _onTap,
                ),
                _NavButton(
                  index: 1,
                  currentIndex: _currentIndex,
                  icon: Icons.inbox_outlined,
                  activeIcon: Icons.inbox_outlined,
                  label: '消息',
                  controller: _controllers[1],
                  onTap: _onTap,
                ),
                _CenterCourseButton(
                  isSelected: _currentIndex == 2,
                  onTap: () => _onTap(2),
                ),
                _NavButton(
                  index: 3,
                  currentIndex: _currentIndex,
                  icon: Icons.apps_rounded,
                  activeIcon: Icons.apps_rounded,
                  label: '服务',
                  controller: _controllers[3],
                  onTap: _onTap,
                ),
                _NavButton(
                  index: 4,
                  currentIndex: _currentIndex,
                  icon: Icons.person_outline_rounded,
                  activeIcon: Icons.person_rounded,
                  label: '用户',
                  controller: _controllers[4],
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
  final int index;
  final int currentIndex;
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final AnimationController controller;
  final ValueChanged<int> onTap;

  const _NavButton({
    required this.index,
    required this.currentIndex,
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.controller,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = index == currentIndex;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final scale = 1.0 + (controller.value * 0.12);
        return GestureDetector(
          onTap: () => onTap(index),
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: 70,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Transform.scale(
                  scale: scale,
                  child: Icon(
                    isSelected ? activeIcon : icon,
                    color: isSelected
                        ? AppTheme.primaryColor
                        : (isDark ? Colors.grey.shade600 : const Color(0xFF9CA3AF)),
                    size: 24,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    color: isSelected
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

class _CenterCourseButton extends StatelessWidget {
  final bool isSelected;
  final VoidCallback onTap;
  const _CenterCourseButton({required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 52,
            height: 52,
            margin: const EdgeInsets.only(bottom: 2),
            decoration: BoxDecoration(
              border: Border.all(color: context.borderColor),
              color: isSelected ? AppTheme.primaryColor : const Color(0xFF374151),
              borderRadius: BorderRadius.circular(52),
              // v2.4.2：去掉原来 16px 模糊 + 40% 主题色的投影（用户反馈
              // 「课表图标周围一圈光晕」）。52×52 的圆钮配这么大的 blur，
              // 在浅色底上会糊出一圈明显光斑，与其余导航项（纯图标）风格不一。
              // 保留一层极淡、极小的阴影维持轻微浮起感即可。
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              isSelected ? Icons.calendar_month_rounded : Icons.calendar_today_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          Text(
            '课表',
            style: TextStyle(
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              color: isSelected
                  ? AppTheme.primaryColor
                  : (Theme.of(context).brightness == Brightness.dark ? Colors.grey.shade600 : const Color(0xFF9CA3AF)),
            ),
          ),
        ],
      ),
    );
  }
}
