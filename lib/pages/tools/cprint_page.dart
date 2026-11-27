import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../services/campus/cprint_client.dart';
import '../../services/dorm_service.dart';
import '../../services/dorm_web_client.dart';
import '../../services/web_window_stub.dart'
    if (dart.library.js_util) '../../services/web_window_web.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';
import 'cprint_jobs_tab.dart';
import 'cprint_records_tab.dart';
import 'cprint_scan_tab.dart';
import 'cprint_shared.dart';
import 'cprint_stations_tab.dart';
import 'cprint_upload_tab.dart';

/// 图书馆云打印。
///
/// ## 为什么是「五个页签」
///
/// 网页版（`zzwy.cwxu.edu.cn`）本身就有五个功能入口：
/// **云打印（上传）· 打印文档 · 扫描文档 · 打印点 · 使用记录**。
/// 之前 App 里只做了「扫描文档」一件，用户看到「云打印」这个名字点进来
/// 却只能看扫描件，功能上是缺的。这里按网页版的功能划分补齐，
/// 但交互按手机重做（网页版是表格 + 批量勾选，手机上一屏放不下）。
///
/// ## 登录只做一次
///
/// 五个功能共用同一个 OSESSIONID，所以授权统一在这一层做：
/// 没登录时显示一张登录卡，登录一次五个页签都能用。
/// 会话过期（`code:4`）时子页签回调 [onNeedAuth]，这里统一退回登录态。
const String _kWebUnsupported = '网页版暂不支持云打印，请在校园网内打开云打印网页';

/// 网页版打开云打印用的命名窗口（同一个窗口先登网关、再进云打印网页）。
const String _kWebWindow = 'xiyuan_cprint';

class CprintPage extends StatefulWidget {
  const CprintPage({super.key});

  @override
  State<CprintPage> createState() => _CprintPageState();
}

class _CprintPageState extends State<CprintPage>
    with TickerProviderStateMixin {
  TabController? _tabCtl;
  /// 上传成功一次就 +1，用来踢「打印文档」页签重拉列表。
  int _jobsTick = 0;
  bool _authed = false;
  bool _booting = true;
  String _authError = '';

  /// 网页版「打开云打印网页」正在准备中（防连点）。
  bool _openingWeb = false;
  String _trueName = '';
  bool _scanDisabled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    // 网页版没有本机文件系统：上传要选文件、扫描件要落盘，整条链路都跑不通。
    // 与其让用户对着转圈，不如直接说清楚去哪用。
    if (kIsWeb) {
      setState(() {
        _booting = false;
        _authed = false;
        _authError = _kWebUnsupported;
      });
      return;
    }
    setState(() {
      _booting = true;
      _authError = '';
    });
    final auth = await CprintClient.authorize();
    if (!mounted) return;
    setState(() {
      _booting = false;
      _authed = auth.ok;
      _authError = auth.ok ? '' : auth.message;
      _trueName = auth.trueName ?? CprintClient.trueName ?? '';
    });
    _readScanDisabled();
  }

  /// 学校可以配置隐藏「扫描文档」页签（cookie `set_isDisabledscanbtn`）。
  /// 网页版就是按这个 cookie 决定显不显示的，App 跟着来，不然会点进一个
  /// 学校已经关掉的功能。
  void _readScanDisabled() {
    final s = CprintClient.session;
    if (s == null) return;
    final v = (s.cookies['set_isDisabledscanbtn'] ?? '') == 'true';
    if (v != _scanDisabled && mounted) {
      setState(() => _scanDisabled = v);
    }
  }

  Future<void> _askPasswordAndLogin({bool force = false}) async {
    final ctl = TextEditingController();
    final pwd = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          side: BorderSide(color: ctx.borderColor),
        ),
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 8, 0),
        title: Row(
          children: [
            Expanded(
              child: Text(
                force ? '换一个账号' : '再输一次统一认证密码',
                style: TextStyle(
                  fontSize: AppTheme.fontHeading,
                  fontWeight: FontWeight.w600,
                  color: ctx.textPrimary,
                ),
              ),
            ),
            IconButton(
              tooltip: '关闭',
              icon: Icon(Icons.close_rounded, size: 20, color: ctx.textTertiary),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'App 里没有保存密码（「我的 → 登录」里的「记住密码」没开）。'
              '这一次需要手动输入，之后 40 分钟内不用再输。',
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                height: 1.5,
                color: ctx.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: '统一认证密码',
                isDense: true,
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: ctx.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctl.text),
            child: const Text('登录'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (pwd == null || pwd.isEmpty) return;
    setState(() {
      _booting = true;
      _authError = '';
    });
    final auth = await CprintClient.authorize(password: pwd, force: force);
    if (!mounted) return;
    setState(() {
      _booting = false;
      _authed = auth.ok;
      _authError = auth.ok ? '' : auth.message;
      _trueName = auth.trueName ?? _trueName;
    });
    if (auth.ok) _readScanDisabled();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text(
          '图书馆云打印',
          style: TextStyle(
            fontSize: AppTheme.fontHeading,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          if (_authed)
            IconButton(
              tooltip: '换个账号',
              onPressed: () => _askPasswordAndLogin(force: true),
              icon: const Icon(Icons.swap_horiz_rounded, size: 20),
            ),
        ],
      ),
      body: kIsWeb
          ? _webNotice()
          : _booting
              ? cprintLoading()
              : _authed
                  ? _tabs()
                  : _loginView(),
    );
  }

  Widget _webNotice() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 24),
      children: [
        AppCard(
          radius: AppTheme.radiusLg,
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 18, color: AppTheme.primaryColor),
                  const SizedBox(width: 8),
                  Text(
                    '网页版暂不支持云打印',
                    style: TextStyle(
                      fontSize: AppTheme.fontTitle,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '上传文件打印、下载扫描件都要读写本机文件，网页版做不到。'
                '点下面的按钮会自动通过 WebVPN 网关打开图书馆的云打印网页，'
                '校外也能用；云打印自己的统一身份认证第一次仍需在页面里登录一次。',
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  height: 1.55,
                  color: context.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _openingWeb ? null : () => _openCprintWeb(context),
                  child: Text(_openingWeb ? '正在打开…' : '打开云打印网页'),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '自动过网关失败时会退回直连地址（那时需要连校园网）。'
                '也可以回安卓 App 里直接打印与取件。',
                style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  height: 1.5,
                  color: context.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 跳到图书馆自己的云打印网页（`zzwy` 内网站点，必须连校园网）。
  /// 网页版云打印：**先自动过 WebVPN 网关**，再打开云打印网页。
  ///
  /// 云打印正文（上传/取件/下载扫描件）必须由图书馆自己的网页做，而那个网页在
  /// 内网 `zzwy.cwxu.edu.cn:9130`。外网访问要先有网关票据 cookie，而换票必须由
  /// 浏览器自己完成（服务端出口 IP 被网关 403）。所以：
  ///
  /// 1. 控制端现铸一张网关票，回两组地址（网关登录地址 + 包装后的云打印地址）；
  /// 2. 浏览器在**同一个命名窗口**里先导航到网关登录地址换 cookie；
  /// 3. 2.5s 后再导航到云打印地址 —— 网关已经认人，直接把页面转过去。
  ///
  /// 云打印自己还有一层统一身份认证：第一次仍需用户在页面里登录一次（之后浏览
  /// 器记着）。拿不到票（没登录 / 网关异常）时退回直连地址，不让用户卡在按钮上。
  Future<void> _openCprintWeb(BuildContext context) async {
    if (_openingWeb) return;
    // 占位窗必须在手势里**同步**开，晚一步就被弹窗拦截。
    if (!openNamedWindow('about:blank', _kWebWindow)) {
      _snack(context, '浏览器拦截了新标签页，请允许本页弹出窗口后重试');
      return;
    }
    setState(() => _openingWeb = true);
    try {
      final sid = await DormService.webSessionId();
      final link = await DormWebClient.cprintLink(sid);
      openNamedWindow(link.loginUrl, _kWebWindow);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      // 第二步打开包装后的云打印页：云打印会自己发起统一身份认证，网关会把
      // 那一跳也包装进网关域，所以校外登录完照样能回跳到云打印首页。
      openNamedWindow(link.targetUrl, _kWebWindow);
    } catch (_) {
      // 退回直连：校园网内照样能用。
      openNamedWindow(CprintClient.backUrl, _kWebWindow);
    } finally {
      if (mounted) setState(() => _openingWeb = false);
    }
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _loginView() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 24),
      children: [
        AppCard(
          radius: AppTheme.radiusLg,
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lock_outline_rounded,
                      size: 18, color: AppTheme.primaryColor),
                  const SizedBox(width: 8),
                  Text(
                    '登录一次图书馆云打印',
                    style: TextStyle(
                      fontSize: AppTheme.fontTitle,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _authError.isEmpty
                    ? '登录后可以上传文件打印、查看打印任务、看扫描件和消费记录。'
                    : _authError,
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  height: 1.55,
                  color: context.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => _askPasswordAndLogin(),
                  child: const Text('用统一认证登录'),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '用你登录掌上锡院的统一认证账号，不用另外注册。'
                '不在校园网时会自动走学校的 WebVPN。',
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  height: 1.5,
                  color: context.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<(String, Widget)> _entries() {
    // 学校关掉扫描时，网页版的顺序是 云打印 / 打印文档 / 打印点 / 使用记录。
    return <(String, Widget)>[
      ('云打印', CprintUploadTab(onUploaded: _switchToJobs)),
      (
        '打印文档',
        CprintJobsTab(
          authed: _authed,
          onNeedAuth: _onNeedAuth,
          refreshTick: _jobsTick,
        )
      ),
      if (!_scanDisabled)
        ('扫描文档', CprintScanTab(authed: _authed, onNeedAuth: _onNeedAuth)),
      ('打印点', CprintStationsTab(authed: _authed, onNeedAuth: _onNeedAuth)),
      ('使用记录', CprintRecordsTab(authed: _authed, onNeedAuth: _onNeedAuth)),
    ];
  }

  /// 页签数量会因为「学校关掉扫描文档」而变，控制器要跟着重建。
  void _syncTabController(int count) {
    if (_tabCtl?.length == count) return;
    final old = _tabCtl;
    _tabCtl = TabController(length: count, vsync: this);
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  Widget _tabs() {
    final entries = _entries();
    _syncTabController(entries.length);
    final ctl = _tabCtl!;
    return Column(
      children: [
        if (_trueName.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
              child: Text(
                _trueName,
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  color: context.textTertiary,
                ),
              ),
            ),
          ),
        TabBar(
          controller: ctl,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          labelPadding: const EdgeInsets.symmetric(horizontal: 12),
          indicatorSize: TabBarIndicatorSize.label,
          labelStyle: const TextStyle(
            fontSize: AppTheme.fontBody,
            fontWeight: FontWeight.w600,
          ),
          unselectedLabelStyle: const TextStyle(fontSize: AppTheme.fontBody),
          tabs: [for (final e in entries) Tab(text: e.$1)],
        ),
        Expanded(
          child: TabBarView(
            controller: ctl,
            children: [for (final e in entries) e.$2],
          ),
        ),
      ],
    );
  }

  /// 上传成功后跳到「打印文档」，用户能立刻看到刚传上去的那份。
  /// 上传成功后：先让「打印文档」重拉列表，再切过去 —— 顺序反了会闪一下旧列表。
  void _switchToJobs() {
    if (!mounted) return;
    setState(() => _jobsTick++);
    final ctl = _tabCtl;
    if (ctl == null) return;
    final jobs = _entries().indexWhere((e) => e.$1 == '打印文档');
    if (jobs >= 0 && jobs < ctl.length) ctl.animateTo(jobs);
  }

  void _onNeedAuth() {
    if (!mounted) return;
    setState(() {
      _authed = false;
      _authError = '登录状态已失效，请重新登录。';
    });
  }

  @override
  void dispose() {
    _tabCtl?.dispose();
    super.dispose();
  }
}
