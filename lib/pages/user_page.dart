import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/storage_service.dart';
import '../services/nav_prefs.dart';
import '../services/dorm_service.dart';
import '../services/campus/cas_diagnostics.dart';
import '../services/api_service.dart';
import '../services/course_sync_service.dart';
import '../theme/app_theme.dart';
import 'dorm_dialog.dart';
import 'user/user_cards.dart';
import 'settings_page.dart';
import '../services/data_wipe.dart';
import '../services/login_prefetch_service.dart';
import '../services/widget_sync_service.dart';
import 'widget_settings_page.dart';
import '../providers/course_provider.dart';
import '../providers/grade_provider.dart';
import '../providers/user_config_provider.dart';
import '../services/campus/campus_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 「我的」页。
///
/// 两种形态（**纯本地、无云端账号**）：
///   · 未登录 → 直接就是**登录页**（统一身份认证：学号 + 密码）
///   · 已登录 → 个人信息页（顶部「掌上锡院」+ 一卡通余额 + 姓名/学号）
///
/// 「登录」= 拿学号密码走一次 CAS，校验通过后**存到本机**；没有注册、没有令牌、
/// 不连任何服务器。换账号请先在设置里退出登录。
class UserPage extends StatefulWidget {
  const UserPage({super.key});

  @override
  State<UserPage> createState() => _UserPageState();
}

class _UserPageState extends State<UserPage> {
  UserConfig _config = const UserConfig();
  final _usernameCtl = TextEditingController();
  final _passwordCtl = TextEditingController();

  /// 首次从本机读配置（读完才知道该显示登录页还是信息页）
  bool _loading = true;

  bool _loggingIn = false;
  String? _loginError;
  bool _obscurePassword = true;

  /// 学生姓名（来自教务成绩查询的学生信息；拿不到时为空）
  String _studentName = '';

  /// 宿舍（未填写 = null）。用户页与电费卡片共用这份存储。
  DormInfo? _dorm;

  /// 桌面小组件是否已添加到主屏（null = 尚未查询出来）。仅用于入口右侧的一行状态字。
  bool? _widgetInstalled;

  /// 应用版本号 —— **运行时从编译产物读取**（见 `_load()`），不手写副本。
  /// 真相源只有 `pubspec.yaml` 的 `version:`，Android 侧由 flutter.versionName 自动取。
  String _appVersion = '';

  /// 开源仓库地址（登录页展示、点击在浏览器打开）。
  static const String _repoUrl = 'https://github.com/douge0906/xiyuan_pocket';

  // ---------------- 教程锚点 ----------------
  final GlobalKey _kHeader = GlobalKey();
  final GlobalKey _kBind = GlobalKey();

  /// 是否已登录 = 本机是否存了统一认证账号
  bool get _loggedIn => _config.username.trim().isNotEmpty;

  // ---------------- 极简模式 / 登录失败 ----------------

  /// 极简模式 = 首页 / 消息 / 服务三页都隐藏，只留课表 + 我的。
  bool get _minimalMode {
    final hidden = NavPrefs.layout.hidden;
    return hidden.contains(NavPage.home) &&
        hidden.contains(NavPage.message) &&
        hidden.contains(NavPage.service);
  }

  Future<void> _setMinimalMode(bool value) async {
    if (value) {
      await NavPrefs.setVisiblePages({NavPage.course});
    } else {
      await NavPrefs.setVisiblePages({
        NavPage.home,
        NavPage.message,
        NavPage.course,
        NavPage.service,
      });
    }
    if (mounted) setState(() {});
  }

  void _onNavPrefsChanged() {
    if (mounted) setState(() {});
  }

  /// 连续登录失败次数（跨启动保留）。
  int _loginFails = 0;
  static const String _kLoginFails = 'login_fail_count_v1';

  Future<void> _saveLoginFails(int value) async {
    _loginFails = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLoginFails, value);
    } catch (_) {
      // 记不住就算了，不影响登录
    }
  }

  @override
  void initState() {
    super.initState();
    // 设置页改了导航（隐藏/排序）→ 本页开关状态跟着变
    NavPrefs.notifier.addListener(_onNavPrefsChanged);
    _load();
  }

  @override
  void dispose() {
    NavPrefs.notifier.removeListener(_onNavPrefsChanged);
    _usernameCtl.dispose();
    _passwordCtl.dispose();
    super.dispose();
  }

  /// 编辑宿舍：居中弹窗（楼栋可搜索 + 房号），保存后刷新本页。
  Future<void> _editDorm() async {
    final d = await showDormDialog(context, current: _dorm);
    if (d == null || !mounted) return;
    await DormStore.save(d);
    if (!mounted) return;
    setState(() => _dorm = d);
  }

  Future<void> _load() async {
    final config = await StorageService.loadUserConfig();
    final name = await StorageService.loadStudentName();
    final widgetInstalled = await WidgetSyncService.isWidgetInstalled();
    final dorm = await DormStore.load();
    // 版本号从 APK 里读（值由 pubspec.yaml 的 version 编译进来），不手写
    final info = await PackageInfo.fromPlatform();
    int fails = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      fails = prefs.getInt(_kLoginFails) ?? 0;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _loginFails = fails;
      _appVersion = info.version;
      _config = config;
      _usernameCtl.text = config.username;
      _passwordCtl.text = config.password;
      _studentName = name;
      _widgetInstalled = widgetInstalled;
      _dorm = dorm;
      _loading = false;
    });
    if (config.username.trim().isNotEmpty) {
      _ensureStudentName();
    }
  }

  /// 连续 3 次失败：给出可执行的出路（浏览器登录 / 连接诊断 / 等待解锁）。
  Future<void> _showLoginHelp() async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('连续 3 次登录失败', style: TextStyle(fontSize: 16)),
        content: const Text(
          '可能是密码错误、验证码识别失败，或账号已被临时锁定。\n'
          '建议先用浏览器打开统一认证页面确认能否登录；'
          '如果那边也提示错误，请等 10-15 分钟再试。',
          style: TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('later'),
            child: const Text('稍后再试'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('diag'),
            child: const Text('连接诊断'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('browser'),
            child: const Text('打开统一认证页面'),
          ),
        ],
      ),
    );
    if (action == 'browser') {
      await launchUrl(
        Uri.parse('https://wxcas.cwxu.edu.cn/lyuapServer/login'),
        mode: LaunchMode.externalApplication,
      );
    } else if (action == 'diag') {
      await _showDiagnostics();
    }
  }

  /// 诊断「App 连不上、浏览器却正常」到底卡在哪一步。
  Future<void> _showDiagnostics() async {
    final probes = await CasDiagnostics.run();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('连接诊断', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final p in probes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      p.ok ? Icons.check_circle_outline : Icons.error_outline,
                      size: 16,
                      color: p.ok ? const Color(0xFF0F6E56) : Colors.redAccent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${p.label}：${p.detail}',
                          style: const TextStyle(fontSize: 12.5, height: 1.5)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            const Text(
              '登录页通、验证码接口不通 → 多半是学校对接口做了限制；\n两者都不通 → 网络或校园网限制。',
              style: TextStyle(fontSize: 11.5, height: 1.6, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 登录

  /// 登录：CAS 校验账密 → 校验通过才落盘到本机。
  Future<void> _login() async {
    if (_loggingIn) return;
    final u = _usernameCtl.text.trim();
    final p = _passwordCtl.text;
    if (u.isEmpty || p.isEmpty) {
      setState(() => _loginError = '请填写学号与密码');
      return;
    }

    setState(() {
      _loggingIn = true;
      _loginError = null;
    });

    try {
      // ① 走一次真实 CAS 登录 —— 账密不对这里就抛错，不会把错误账密存下来
      await ApiService.verifyLogin(u, p);
      if (!mounted) return;

      // ② 落盘（唯一真相源 = StorageService；同时通知其它页刷新）
      // container 不依赖下面的 await 结果，先取出来，避免 await 之后再碰 context
      final container = ProviderScope.containerOf(context, listen: false);
      final base = await StorageService.loadUserConfig();
      final cfg = base.copyWith(username: u, password: p);
      await container.read(userConfigProvider.notifier).update(cfg);
      if (!mounted) return;

      setState(() {
        _config = cfg;
        _loggingIn = false;
      });

      // ③ 后台静默补数据（能获取就获取，拿不到就算），不阻塞登录动画
      _ensureStudentName();
      // ④ 登录成功 = 顺手把课表同步一次（开源版已取消课表页的「教务导入」按钮，
      //     这一步接管了它）。静默：登录动画不该因为教务慢而卡住；
      //     同步失败也不会动已有课表，用户随时能用课表页的刷新键手动重来。
      // 登录成功 → 失败计数清零
      if (_loginFails != 0) await _saveLoginFails(0);
      // 课表同步与预取共用同一个教务会话（含 csrftoken），必须串行：
      // 先课表，完成后再拉成绩 / 考试 / 教材，避免并发互相顶掉会话。
      unawaited(CourseSyncService.sync(container)
          .whenComplete(() => LoginPrefetchService.run(container)));
    } catch (e) {
      if (!mounted) return;
      final message = e.toString().replaceFirst('Exception: ', '').trim();
      setState(() {
        _loggingIn = false;
        _loginError = message;
      });
      await _saveLoginFails(_loginFails + 1);
      if (_loginFails >= 3 && mounted) await _showLoginHelp();
    }
  }

  /// 补学生姓名（**登录后静默进行，拿不到就算**）：来自教务成绩查询的学生信息。
  ///
  /// 拿不到就保持为空（界面显示「—」）—— 例如新生尚无成绩记录时，
  /// 正方教务的成绩行里没有学生信息。**不弹错、不阻塞**。
  Future<void> _ensureStudentName() async {
    if (!_loggedIn || _studentName.isNotEmpty) return;
    try {
      final info = await ApiService.tryFetchStudentInfo();
      final name = (info?['xm'] ?? '').toString().trim();
      if (name.isEmpty) return;
      await StorageService.saveStudentName(name);
      if (mounted) setState(() => _studentName = name);
    } catch (_) {
      // 静默：姓名只是展示信息，拿不到不影响任何功能
    }
  }

  // ------------------------------------------------------------ 页面动作

  /// 打开设置页（右上角齿轮 / 关于栏「设置」入口共用）。
  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          onLogout: _logout,
          themeMode: _config.themeMode,
          onThemeChanged: _toggleTheme,
          primaryColor: AppTheme.primaryNotifier,
          onPrimaryChanged: _setPrimaryColor,
        ),
      ),
    );
    // 设置页可能改过主题，回来刷新本页展示
    if (mounted) setState(() {});
  }

  /// 退出登录：清空全部本地数据（含账号），回到登录页。
  Future<void> _logout() async {
    // 2026-10-13：退出时把内存里的教务会话也清掉 ——
    // 否则同进程内继续查询仍会复用上一个账号的会话（配合 DataWipe 清落盘部分）。
    LocalCampusService.clear();

    // 全量清空本地数据（含待办、课表、成绩、已读、订阅、教程标记）
    await DataWipe.wipeAll();

    // 内存态 provider 一并重置 —— 否则界面仍显示旧数据（文件清了但内存没清）
    // UserPage 是普通 StatefulWidget，没有 ref，用 ProviderContainer 取容器。
    if (mounted) {
      final container = ProviderScope.containerOf(context, listen: false);
      container.invalidate(courseProvider);
      container.invalidate(gradeProvider);
      container.invalidate(userConfigProvider);
    }

    // 外观回默认（浅色 + 墨黑）
    AppTheme.setMode(ThemeMode.light);
    AppTheme.setPrimary(AppTheme.defaultPrimary);

    if (!mounted) return;
    _usernameCtl.clear();
    _passwordCtl.clear();
    setState(() {
      _config = const UserConfig();
      _studentName = '';
      _loginError = null;
      _obscurePassword = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已退出登录，本地数据已清空')),
    );
  }

  Future<void> _toggleTheme(ThemeMode mode) async {
    AppTheme.setMode(mode);
    final config = _config.copyWith(themeMode: mode);
    await StorageService.saveUserConfig(config);
    if (mounted) setState(() => _config = config);
  }

  Future<void> _setPrimaryColor(Color c) async {
    AppTheme.setPrimary(c);
    final config = _config.copyWith(primaryColor: c.value);
    await StorageService.saveUserConfig(config);
    if (mounted) setState(() => _config = config);
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_loading) {
      return Scaffold(
        backgroundColor: context.scaffoldColor,
        body: const SizedBox.shrink(),
      );
    }
    return _loggedIn ? _buildProfilePage(isDark) : _buildLoginPage(isDark);
  }

  // ------------------------------------------------------------ 登录页

  Widget _buildLoginPage(bool isDark) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),

              // 顶部：名称 + 版本
              Center(
                child: Column(
                  children: [
                    Icon(Icons.code_rounded,
                        size: 34,
                        color: isDark
                            ? Colors.grey.shade500
                            : const Color(0xFF9CA3AF)),
                    const SizedBox(height: 10),
                    Text(
                      '掌上锡院',
                      style: TextStyle(
                        fontSize: 13.5,
                        color: isDark
                            ? Colors.grey.shade400
                            : const Color(0xFF4B5563),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Ver: $_appVersion',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: isDark
                            ? Colors.grey.shade600
                            : const Color(0xFF9CA3AF),
                      ),
                    ),
                    const SizedBox(height: 5),
                    // 开源仓库地址（点击在浏览器打开）
                    GestureDetector(
                      onTap: () => launchUrl(
                        Uri.parse(_repoUrl),
                        mode: LaunchMode.externalApplication,
                      ),
                      child: Text(
                        _repoUrl.replaceFirst('https://', ''),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isDark
                              ? Colors.grey.shade500
                              : const Color(0xFF6B7280),
                          decoration: TextDecoration.underline,
                          decorationColor: isDark
                              ? Colors.grey.shade700
                              : const Color(0xFFD1D5DB),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // 标题
              Center(
                child: Text(
                  '统一身份认证',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimary,
                  ),
                ),
              ),

              const SizedBox(height: 28),

              _fieldLabel('学号'),
              const SizedBox(height: 6),
              TextField(
                controller: _usernameCtl,
                enabled: !_loggingIn,
                textInputAction: TextInputAction.next,
                decoration: _inputDecoration(
                  isDark: isDark,
                  hint: '请输入学号',
                  icon: Icons.person_outline_rounded,
                ),
              ),

              const SizedBox(height: 16),

              _fieldLabel('密码'),
              const SizedBox(height: 6),
              TextField(
                controller: _passwordCtl,
                enabled: !_loggingIn,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _login(),
                decoration: _inputDecoration(
                  isDark: isDark,
                  hint: '请输入密码',
                  icon: Icons.lock_outline_rounded,
                  suffix: IconButton(
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                    tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 20,
                      color: Colors.grey.shade400,
                    ),
                  ),
                ),
              ),

              if (_loginError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _loginError!,
                  style: const TextStyle(
                      fontSize: 12.5, color: Color(0xFFEF4444), height: 1.5),
                ),
              ],

              const SizedBox(height: 28),

              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _loggingIn ? null : _login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor:
                        AppTheme.primaryColor.withOpacity(0.5),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    ),
                  ),
                  child: _loggingIn
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text(
                          '登录',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                ),
              ),

              const SizedBox(height: 16),

              // v1.7.2：**替换**掉原来那句合规小字（“登录即表示已阅读并同意相关说明…
              // 密码仅保存在本机，不发送给任何服务器。”）—— 用户当时的原话是
              // 「统一认证登录页面下方小字修改 修改为 新生需要进行统一认证登录账户激活
              // 点击跳转（…）直接这样就行」，即只留这一行可点击指引，不再有两行小字。
              // v1.6.5：新生账户激活指引（与在线版同一文案 + 同一跳转地址）
              GestureDetector(
                onTap: () => launchUrl(
                  Uri.parse(
                      'https://wxcas.cwxu.edu.cn/lyuapServer/login'
                      '?service=https://my.cwxu.edu.cn/shiro-cas'),
                  mode: LaunchMode.externalApplication,
                ),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '新生需要进行统一认证登录账户激活 点击跳转',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.6,
                      color: AppTheme.primaryColor,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fieldLabel(String text) => Text(
        text,
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w500,
          color: context.textPrimary,
        ),
      );

  InputDecoration _inputDecoration({
    required bool isDark,
    required String hint,
    required IconData icon,
    Widget? suffix,
  }) =>
      InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(fontSize: 14, color: Colors.grey.shade400),
        prefixIcon: Icon(icon, size: 20, color: Colors.grey.shade400),
        suffixIcon: suffix,
        filled: true,
        fillColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          borderSide: BorderSide(color: context.borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          borderSide: BorderSide(color: AppTheme.primaryColor, width: 1.5),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          borderSide: BorderSide(color: context.borderColor),
        ),
      );

  // ------------------------------------------------------------ 已登录页

  Widget _buildProfilePage(bool isDark) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      body: CustomScrollView(
        slivers: [
          // 顶部：居中加粗「掌上锡院」+ 右上角设置齿轮
          SliverToBoxAdapter(
            child: UserTitleHeader(
              key: _kHeader,
              onOpenSettings: _openSettings,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  _sectionTitle('我的信息'),
                  UserInfoCard(
                    key: _kBind,
                    name: _studentName,
                    studentId: _config.username,
                    dormText: _dorm?.display ?? '',
                    onDormTap: _editDorm,
                  ),
                  const SizedBox(height: 8),
                  _sectionTitle('主题色'),
                  _card(
                    child: Column(
                      children: [
                        InkWell(
                          onTap: _openSettings,
                          child: _listTile(
                            icon: Icons.dark_mode_rounded,
                            title: '主题',
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_themeLabel,
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: Colors.grey.shade500)),
                                const SizedBox(width: 4),
                                const Icon(Icons.chevron_right,
                                    color: Color(0xFF9CA3AF)),
                              ],
                            ),
                          ),
                        ),
                        _divider(),
                        InkWell(
                          onTap: () => _setMinimalMode(!_minimalMode),
                          child: _listTile(
                            icon: Icons.visibility_off_outlined,
                            title: '极简模式',
                            trailing: Switch(
                              value: _minimalMode,
                              onChanged: _setMinimalMode,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _sectionTitle('桌面小组件'),
                  _card(
                    child: InkWell(
                      // 2026-10-12：改成**独立页面**（不再用上滑弹窗）
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const WidgetSettingsPage(),
                        ),
                      ),
                      child: _listTile(
                        icon: Icons.widgets_outlined,
                        title: '今日课表',
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _widgetInstalled == null
                                  ? ''
                                  : (_widgetInstalled! ? '已添加' : '未添加'),
                              style: TextStyle(
                                  fontSize: 13, color: Colors.grey.shade500),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.chevron_right,
                                color: Color(0xFF9CA3AF)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _sectionTitle('关于'),
                  _card(
                    child: Column(
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          child: _listTile(
                            icon: Icons.info_outline_rounded,
                            title: '版本号',
                            trailing: Text('v$_appVersion',
                                style:
                                    TextStyle(color: Colors.grey.shade500)),
                          ),
                        ),

                        _divider(),
                        InkWell(
                          onTap: _openSettings,
                          child: _listTile(
                            icon: Icons.settings_rounded,
                            title: '设置',
                            trailing: const Icon(Icons.chevron_right,
                                color: Color(0xFF9CA3AF)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 页面小工具

  String get _themeLabel {
    switch (_config.themeMode) {
      case ThemeMode.dark:
        return '深色';
      default:
        return '浅色';
    }
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6, top: 10),
        child: Text(
          text,
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              // 加深色彩：原来 grey.shade500 太浅，看不出分组层级
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF9CA3AF)
                  : const Color(0xFF4B5563)),
        ),
      );

  /// 用户页卡片：描边定形，阴影给层次。
  ///
  /// **不加内边距** —— 行内的分割线要左右贯通到卡片边缘；左右留白由每行自己控制。
  /// 否则「一行文字的卡片」会凭空多出 32px 高，整页显得很空。
  Widget _card({required Widget child}) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF1E1E1E)
              : Colors.white,
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          border: Border.all(color: context.borderColor),
          boxShadow: AppTheme.cardShadow,
        ),
        child: child,
      );

  Widget _divider() => Divider(height: 1, color: context.borderColor);

  /// 列表行：**固定 52 高**（原来用 ListTile，高度随内容浮动 →
  /// 几个「框框」高度不一致）。与身份卡共用同一行高。
  Widget _listTile({
    required IconData icon,
    required String title,
    required Widget trailing,
  }) =>
      SizedBox(
        height: UserInfoCard.rowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: UserInfoCard.rowPadding),
          child: Row(
            children: [
              Icon(icon, size: 20, color: AppTheme.primaryColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(context).textTheme.bodyLarge?.color)),
              ),
              trailing,
            ],
          ),
        ),
      );
}