import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/campus/cprint_client.dart';
import '../../services/campus/webvpn.dart';
import '../../services/net_mode.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_card.dart';
import 'cprint_jobs_tab.dart';
import 'cprint_records_tab.dart';
import 'cprint_scan_tab.dart';
import 'cprint_shared.dart';
import 'cprint_upload_tab.dart';

/// 图书馆云打印。
///
/// ## 为什么是「四个页签」
///
/// 网页版（`zzwy.cwxu.edu.cn`）有五个功能入口：
/// **云打印（上传）· 打印文档 · 扫描文档 · 打印点 · 使用记录**。
/// 2026-11-26 按同学要求去掉「打印点」—— 它只是「哪台打印机在哪个房间」
/// 的静态表格，手机上点进来还得自己认房间，不如直接去网页版看。
/// 剩下四个按手机重做（网页版是表格 + 批量勾选，手机上一屏放不下）。
///
/// ## 登录只做一次
///
/// 五个功能共用同一个 OSESSIONID，所以授权统一在这一层做：
/// 没登录时显示一张登录卡，登录一次五个页签都能用。
/// 会话过期（`code:4`）时子页签回调 [onNeedAuth]，这里统一退回登录态。
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
  String _trueName = '';
  bool _scanDisabled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
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
          // 2026-11-26（同学要求）：去掉「换个账号」，改成「在网页打开」。
          //
          // 理由：换账号这个动作在手机上很容易误触，而它要的就是「用一个
          // 不是本机主账号的身份去打印」—— 那种场景用学校网页版更自然
          // （那里本来就是为共用电脑设计的）。这是兜底入口：App 里的授权
          // 出任何问题，用户还有一条看得见的路。
          IconButton(
            tooltip: '在网页打开',
            onPressed: _openWeb,
            icon: const Icon(Icons.open_in_new_rounded, size: 20),
          ),
        ],
      ),
      body: _booting
          ? const CprintBootingHint()
          : _authed
              ? _tabs()
              : _loginView(),
    );
  }

  /// 备用通道：用系统浏览器打开图书馆云打印的网页版。
  ///
  /// 校外时站点在内网，必须套学校 WebVPN —— 和 App 内走的是同一个网关，
  /// 只是让用户在浏览器里自己登录一次。
  Future<void> _openWeb() async {
    const base =
        'http://zzwy.cwxu.edu.cn:9130/api/client/new/cprintPc/printDoc.html';
    final url = NetMode.current == CampusNetMode.webvpn
        ? WebVpn.wrapUrl(base)
        : base;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!ok) {
        messenger.showSnackBar(
            const SnackBar(content: Text('没能打开浏览器，请稍后重试')));
      }
    } catch (e) {
      debugPrint('[cprint] open web failed: $e');
      messenger.showSnackBar(
          const SnackBar(content: Text('没能打开浏览器，请稍后重试')));
    }
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
      // 2026-11-26：去掉「打印点」（静态房间表格，手机上不如网页版好用）。
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
