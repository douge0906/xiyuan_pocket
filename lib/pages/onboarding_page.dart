import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/legal_consent.dart';
import '../services/nav_prefs.dart';
import '../services/onboarding_prefs.dart';
import '../theme/app_theme.dart';
import 'legal_doc_page.dart';

/// 首次启动的「快速开始」。
///
/// 四步：欢迎 → 五个 Tab 是干什么的 → 默认 / 极简二选一 → 隐私同意并去登录。
///
/// 设计上刻意和 App 内一致：墨黑主色、白卡、1px 淡描边、20 圆角；
/// 每屏只做一件事，正文不超过一行 —— 首屏引导最怕小字堆成说明书。
/// 动效只用三样：出现（位移 + 淡入，错峰）、放大弹出、抖动（点错时）。
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage>
    with TickerProviderStateMixin {
  static const int _stepCount = 4;

  final PageController _pager = PageController();
  int _step = 0;
  OnboardingMode _mode = OnboardingMode.full;
  bool _agreed = false;
  bool _finishing = false;

  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  )..forward();

  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  @override
  void dispose() {
    _pager.dispose();
    _enter.dispose();
    _shake.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() => _step = index);
    _enter.forward(from: 0);
  }

  void _go(int index) {
    if (_finishing || index < 0 || index >= _stepCount) return;
    _pager.animateToPage(
      index,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  void _next() {
    if (_finishing) return;
    if (_step < _stepCount - 1) {
      _go(_step + 1);
      return;
    }
    if (!_agreed) {
      HapticFeedback.mediumImpact();
      _shake.forward(from: 0);
      return;
    }
    unawaited(_finish());
  }

  Future<void> _finish() async {
    setState(() => _finishing = true);
    // 同意就落在这里 —— 原来那个启动弹窗把它合进了这一步。
    await LegalConsentService.accept();
    await OnboardingPrefs.markDone(_mode);
    if (_mode == OnboardingMode.minimal) {
      // 极简模式 = 首页 / 消息 / 服务三页都隐藏，只留课表 + 我的。
      await NavPrefs.setVisiblePages({NavPage.course});
    } else {
      await NavPrefs.setVisiblePages({
        NavPage.home,
        NavPage.message,
        NavPage.course,
        NavPage.service,
      });
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  void _skip() {
    if (_finishing) return;
    _go(_stepCount - 1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(context),
            Expanded(
              child: PageView(
                controller: _pager,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: _onPageChanged,
                children: [
                  _buildWelcome(context),
                  _buildTabs(context),
                  _buildMode(context),
                  _buildConsent(context),
                ],
              ),
            ),
            _buildBottom(context),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 顶栏

  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 16, 0),
      child: Row(
        children: [
          // 进度：走到第几步，比「1/4」更安静。
          for (int i = 0; i < _stepCount; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.only(right: 6),
              width: i == _step ? 20 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i <= _step
                    ? AppTheme.primaryColor
                    : context.borderColor,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          const Spacer(),
          if (_step < _stepCount - 1)
            TextButton(
              onPressed: _skip,
              style: TextButton.styleFrom(
                foregroundColor: context.textTertiary,
                textStyle: const TextStyle(
                  fontSize: AppTheme.fontSmall,
                  fontWeight: FontWeight.w500,
                ),
              ),
              child: const Text('跳过'),
            )
          else
            const SizedBox(height: 34),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 第一步

  Widget _buildWelcome(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: _Reveal(
              animation: _enter,
              from: 0.00,
              to: 0.50,
              offset: const Offset(0, 22),
              scaleFrom: 0.86,
              child: _LogoTile(),
            ),
          ),
          const SizedBox(height: 26),
          Center(
            child: _Typewriter(
              animation: _enter,
              from: 0.18,
              to: 0.62,
              text: '欢迎使用掌上锡院',
              style: TextStyle(
                fontSize: AppTheme.fontHero - 3,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: context.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: _Reveal(
              animation: _enter,
              from: 0.40,
              to: 0.85,
              offset: const Offset(0, 10),
              child: Text(
                '课表、消息、服务，一处搞定',
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  color: context.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
          _featureRow(
            context,
            index: 0,
            icon: Icons.calendar_month_rounded,
            title: '课程表',
            desc: '今天上什么，一眼看到',
          ),
          _featureRow(
            context,
            index: 1,
            icon: Icons.inbox_rounded,
            title: '消息',
            desc: '教务通知、校园要闻，不用一个个翻网站',
          ),
          _featureRow(
            context,
            index: 2,
            icon: Icons.apps_rounded,
            title: '服务',
            desc: '成绩、空教室、云打印、校车',
          ),
        ],
      ),
    );
  }

  Widget _featureRow(
    BuildContext context, {
    required int index,
    required IconData icon,
    required String title,
    required String desc,
  }) {
    return _Reveal(
      animation: _enter,
      from: 0.35 + index * 0.12,
      to: 0.85 + index * 0.05,
      offset: const Offset(0, 16),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              ),
              child: Icon(icon, size: 20, color: AppTheme.primaryColor),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: AppTheme.fontTitle,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTheme.fontSmall,
                      color: context.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 第二步

  Widget _buildTabs(BuildContext context) {
    return _TabsStep(animation: _enter);
  }

  // ---------------------------------------------------------------- 第三步

  Widget _buildMode(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Reveal(
            animation: _enter,
            from: 0.00,
            to: 0.45,
            child: Text(
              '你习惯哪种？',
              style: TextStyle(
                fontSize: AppTheme.fontDisplay,
                fontWeight: FontWeight.w700,
                color: context.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          _Reveal(
            animation: _enter,
            from: 0.10,
            to: 0.55,
            child: Text(
              '以后在「我的 → 极简模式」里随时能改',
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                color: context.textTertiary,
              ),
            ),
          ),
          const SizedBox(height: 26),
          // 两张卡要一样高：stretch 必须套在 IntrinsicHeight 里，
          // 直接放在可滚动区域里会拿到无限高度约束（RenderFlex 断言）。
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _Reveal(
                  animation: _enter,
                  from: 0.12,
                  to: 0.65,
                  offset: const Offset(-34, 0),
                  child: _ModeCard(
                    title: '默认模式',
                    desc: '首页、消息、服务都在',
                    icons: const [
                      Icons.home_rounded,
                      Icons.inbox_rounded,
                      Icons.apps_rounded,
                    ],
                    selected: _mode == OnboardingMode.full,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _mode = OnboardingMode.full);
                    },
                  ),
                ),
              ),
                const SizedBox(width: 14),
                Expanded(
                  child: _Reveal(
                    animation: _enter,
                    from: 0.24,
                    to: 0.77,
                    offset: const Offset(34, 0),
                    child: _ModeCard(
                      title: '极简模式',
                      desc: '只留课表和我的',
                      icons: const [
                        Icons.calendar_month_rounded,
                        Icons.person_rounded,
                      ],
                      selected: _mode == OnboardingMode.minimal,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _mode = OnboardingMode.minimal);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 第四步

  Widget _buildConsent(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Reveal(
            animation: _enter,
            from: 0.00,
            to: 0.45,
            child: Text(
              '最后一步',
              style: TextStyle(
                fontSize: AppTheme.fontDisplay,
                fontWeight: FontWeight.w700,
                color: context.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          _Reveal(
            animation: _enter,
            from: 0.10,
            to: 0.55,
            child: Text(
              '看清这三件事就可以用了',
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                color: context.textTertiary,
              ),
            ),
          ),
          const SizedBox(height: 22),
          _pointRow(context, 0, '账号密码只发给学校，不经过开发者'),
          _pointRow(context, 1, '课表、成绩这些数据都存在你的手机上'),
          _pointRow(context, 2, '图片识别课表会上传一次图片，用完即删'),
          const SizedBox(height: 18),
          AnimatedBuilder(
            animation: _shake,
            builder: (context, child) {
              final p = _shake.value;
              final dx = (p == 0 || p == 1)
                  ? 0.0
                  : (p * 18 - 9) * (1 - p) * 1.6;
              return Transform.translate(offset: Offset(dx, 0), child: child);
            },
            child: _buildAgreeRow(context),
          ),
        ],
      ),
    );
  }

  Widget _pointRow(BuildContext context, int index, String text) {
    return _Reveal(
      animation: _enter,
      from: 0.15 + index * 0.12,
      to: 0.65 + index * 0.08,
      offset: const Offset(0, 12),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.check_circle_rounded,
                  size: 17, color: AppTheme.primaryColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  height: 1.45,
                  color: context.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAgreeRow(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() => _agreed = !_agreed);
          },
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 21,
                  height: 21,
                  decoration: BoxDecoration(
                    color: _agreed ? AppTheme.primaryColor : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(
                      color: _agreed
                          ? AppTheme.primaryColor
                          : context.borderColor,
                      width: 1.5,
                    ),
                  ),
                  child: _agreed
                      ? const Icon(Icons.check_rounded,
                          size: 15, color: Colors.white)
                      : null,
                ),
                const SizedBox(width: 10),
                Text(
                  '我已阅读并同意',
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    color: context.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
        Wrap(
          spacing: 2,
          children: [
            _docLink(context, '《隐私政策》', '隐私政策',
                'assets/legal/privacy_policy.md'),
            _docLink(context, '《用户协议》', '用户协议',
                'assets/legal/user_agreement.md'),
          ],
        ),
      ],
    );
  }

  Widget _docLink(
      BuildContext context, String label, String title, String assetPath) {
    return TextButton(
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LegalDocPage(title: title, assetPath: assetPath),
        ),
      ),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        minimumSize: const Size(0, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: AppTheme.primaryColor,
        textStyle: const TextStyle(fontSize: AppTheme.fontBody),
      ),
      child: Text(label),
    );
  }

  // ---------------------------------------------------------------- 底栏

  Widget _buildBottom(BuildContext context) {
    final label = switch (_step) {
      0 => '开始',
      1 => '继续',
      2 => '就这个',
      _ => '同意并去登录',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 18),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: FilledButton(
          onPressed: _finishing ? null : _next,
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.primaryColor,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            textStyle: const TextStyle(
              fontSize: AppTheme.fontTitle,
              fontWeight: FontWeight.w600,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label),
              const SizedBox(width: 6),
              const Icon(Icons.arrow_forward_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================================================================== 组件

/// 出现动画：位移 + 淡入，可按时间片错峰。
class _Reveal extends StatelessWidget {
  const _Reveal({
    required this.animation,
    required this.child,
    this.from = 0,
    this.to = 1,
    this.offset = const Offset(0, 16),
    this.scaleFrom = 1,
  });

  final Animation<double> animation;
  final Widget child;
  final double from;
  final double to;
  final Offset offset;
  final double scaleFrom;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final span = (to - from).abs() < 0.001 ? 1.0 : (to - from);
        final raw = ((animation.value - from) / span).clamp(0.0, 1.0);
        final t = Curves.easeOutCubic.transform(raw);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: offset * (1 - t),
            child: Transform.scale(
              scale: 1 + (scaleFrom - 1) * (1 - t),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// 一个字一个字出现。只用在欢迎页标题上 —— 多了会像幻灯片。
class _Typewriter extends StatelessWidget {
  const _Typewriter({
    required this.animation,
    required this.text,
    required this.style,
    this.from = 0.15,
    this.to = 0.7,
  });

  final Animation<double> animation;
  final String text;
  final TextStyle style;
  final double from;
  final double to;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final span = (to - from).abs() < 0.001 ? 1.0 : (to - from);
        final t = ((animation.value - from) / span).clamp(0.0, 1.0);
        final n = (text.length * t).ceil().clamp(0, text.length);
        return SizedBox(
          height: style.fontSize! * 1.5,
          child: Center(
            child: Text(
              text.substring(0, n),
              textAlign: TextAlign.center,
              style: style,
            ),
          ),
        );
      },
    );
  }
}

/// 应用标志：墨黑圆角方块 + 日历，右下角一枚水波小徽标（对应「一卡通 / 电费」）。
class _LogoTile extends StatefulWidget {
  @override
  State<_LogoTile> createState() => _LogoTileState();
}

class _LogoTileState extends State<_LogoTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _float = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _float.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _float,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_float.value);
        return Transform.translate(
          offset: Offset(0, -3 * t),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 104,
                height: 104,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF2C3440), Color(0xFF11151A)],
                  ),
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 26,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: const Center(
                  child: Icon(Icons.calendar_month_rounded,
                      size: 54, color: Colors.white),
                ),
              ),
              Positioned(
                right: -6,
                bottom: -6,
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor == const Color(0xFF1F2937)
                        ? const Color(0xFF3F6FA8)
                        : AppTheme.primaryColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: context.scaffoldColor,
                      width: 3,
                    ),
                  ),
                  child: const Icon(Icons.water_drop_rounded,
                      size: 17, color: Colors.white),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 第二步：五个 Tab 各是干什么的。
///
/// 用一条会自己走动的底部导航演示「切页」，上方卡片跟着换 ——
/// 比列五条文字更直观，也更像 App 本身。
class _TabsStep extends StatefulWidget {
  const _TabsStep({required this.animation});

  final Animation<double> animation;

  @override
  State<_TabsStep> createState() => _TabsStepState();
}

class _TabsStepState extends State<_TabsStep> {
  static const List<_TabInfo> _tabs = [
    _TabInfo(Icons.home_rounded, '首页', '今天有什么，先看这里'),
    _TabInfo(Icons.inbox_rounded, '消息', '教务、校园要闻、图书馆'),
    _TabInfo(Icons.calendar_month_rounded, '课表', '按周看，考试和成绩也在'),
    _TabInfo(Icons.apps_rounded, '服务', '十几个校园服务，收藏常用的'),
    _TabInfo(Icons.person_rounded, '我的', '账号、外观、小组件'),
  ];

  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 1800), (_) {
      if (!mounted) return;
      setState(() => _index = (_index + 1) % _tabs.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = _tabs[_index];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Reveal(
            animation: widget.animation,
            from: 0.00,
            to: 0.45,
            child: Text(
              '五个标签，各管一块',
              style: TextStyle(
                fontSize: AppTheme.fontDisplay,
                fontWeight: FontWeight.w700,
                color: context.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 22),
          _Reveal(
            animation: widget.animation,
            from: 0.15,
            to: 0.60,
            offset: const Offset(0, 20),
            child: Container(
              height: 196,
              decoration: BoxDecoration(
                color: context.isDark
                    ? const Color(0xFF1E1E1E)
                    : Colors.white,
                borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                border: Border.all(color: context.borderColor),
              ),
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 320),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.92, end: 1).animate(
                        CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                      ),
                      child: child,
                    ),
                  ),
                  child: Column(
                    key: ValueKey<int>(_index),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: AppTheme.primaryColor.withValues(alpha: 0.08),
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMd),
                        ),
                        child: Icon(info.icon,
                            size: 28, color: AppTheme.primaryColor),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        info.name,
                        style: TextStyle(
                          fontSize: AppTheme.fontHeading,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        info.desc,
                        style: TextStyle(
                          fontSize: AppTheme.fontSmall,
                          color: context.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 26),
          _Reveal(
            animation: widget.animation,
            from: 0.30,
            to: 0.80,
            offset: const Offset(0, 18),
            child: _MockTabBar(tabs: _tabs, index: _index),
          ),
          const SizedBox(height: 14),
          Text(
            '长按标签可以调整顺序和显隐',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTheme.fontSmall,
              color: context.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

class _TabInfo {
  const _TabInfo(this.icon, this.name, this.desc);
  final IconData icon;
  final String name;
  final String desc;
}

/// 演示用的底部导航：选中项有淡底 + 上浮的小圆点。
class _MockTabBar extends StatelessWidget {
  const _MockTabBar({required this.tabs, required this.index});

  final List<_TabInfo> tabs;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      decoration: BoxDecoration(
        color: context.isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        children: [
          for (int i = 0; i < tabs.length; i++)
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(vertical: 8),
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: i == index
                      ? AppTheme.primaryColor.withValues(alpha: 0.07)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedScale(
                      duration: const Duration(milliseconds: 280),
                      scale: i == index ? 1.12 : 1,
                      child: Icon(
                        tabs[i].icon,
                        size: 21,
                        color: i == index
                            ? AppTheme.primaryColor
                            : context.textTertiary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      tabs[i].name,
                      style: TextStyle(
                        fontSize: AppTheme.fontCaption,
                        fontWeight:
                            i == index ? FontWeight.w600 : FontWeight.w400,
                        color: i == index
                            ? AppTheme.primaryColor
                            : context.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 模式选择卡：上半是迷你界面示意，下半是名字和一句话。
class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.title,
    required this.desc,
    required this.icons,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String desc;
  final List<IconData> icons;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        scale: selected ? 1.02 : 1,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
          decoration: BoxDecoration(
            color: context.isDark ? const Color(0xFF1E1E1E) : Colors.white,
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            border: Border.all(
              color: selected ? AppTheme.primaryColor : context.borderColor,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 迷你示意：一排小格子 + 底部导航点。
              Container(
                height: 74,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: context.isDark
                      ? const Color(0xFF141414)
                      : const Color(0xFFF6F7F8),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          for (int i = 0; i < 3; i++)
                            Expanded(
                              child: Container(
                                margin: const EdgeInsets.only(right: 4),
                                decoration: BoxDecoration(
                                  color: context.isDark
                                      ? const Color(0xFF2A2A2A)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final icon in icons)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            child: Icon(icon,
                                size: 12, color: context.textTertiary),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle,
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary,
                      ),
                    ),
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected
                            ? AppTheme.primaryColor
                            : context.borderColor,
                        width: 1.6,
                      ),
                    ),
                    child: selected
                        ? Center(
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppTheme.primaryColor,
                              ),
                            ),
                          )
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                desc,
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  color: context.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
