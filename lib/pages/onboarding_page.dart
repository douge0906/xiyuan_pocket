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
    // 收尾：让「同意并去登录」有一个落地的瞬间，而不是一点就黑屏切走。
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(builder: (_) => const _DoneFlash());
    overlay.insert(entry);
    await Future<void>.delayed(const Duration(milliseconds: 640));
    entry.remove();
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
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 一层很淡的柔光，让墨黑方块浮起来 —— 只用渐变，不加动画，
                  // 免得和标志本身的浮动撞在一起变成「两个东西在动」。
                  Container(
                    width: 178,
                    height: 178,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          AppTheme.primaryColor.withValues(alpha: 0.10),
                          AppTheme.primaryColor.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                  _AppIconMark(),
                ],
              ),
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
                    desc: '首页、消息、服务都在 · 推荐',
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
        child: _PressScale(
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
      ),
    );
  }
}

// ==================================================================== 组件

/// 按下时轻微回弹。用 `Listener` 而不是 `GestureDetector`：
/// 后者会吃掉点击，按钮就点不动了。
class _PressScale extends StatefulWidget {
  const _PressScale({required this.child});

  final Widget child;

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _down = false;

  void _set(bool v) {
    if (_down == v) return;
    setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? 0.975 : 1,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

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
/// 走完最后一步时的一下：一个放大的勾，然后才切到登录页。
class _DoneFlash extends StatelessWidget {
  const _DoneFlash();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: context.scaffoldColor,
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: const Duration(milliseconds: 560),
            curve: Curves.easeOutBack,
            builder: (context, t, child) => Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: Transform.scale(scale: 0.82 + 0.18 * t, child: child),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.primaryColor.withValues(alpha: 0.28),
                        blurRadius: 28,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.check_rounded,
                      color: Colors.white, size: 42),
                ),
                const SizedBox(height: 18),
                Text(
                  '准备好了',
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 欢迎页的大标志：直接用 App 自己的图标，外面加一层会呼吸的投影。
/// 2026-11-28 用户明确要求「首页图片用 app 图标」——之前这里是一个自绘的
/// 黑方块叠日历图标，看着像另一个应用。
class _AppIconMark extends StatefulWidget {
  const _AppIconMark();

  @override
  State<_AppIconMark> createState() => _AppIconMarkState();
}

class _AppIconMarkState extends State<_AppIconMark>
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
          offset: Offset(0, -5 * t),
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primaryColor
                      .withValues(alpha: 0.14 + 0.08 * t),
                  blurRadius: 20 + 10 * t,
                  offset: Offset(0, 8 + 4 * t),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Image.asset(
                'assets/images/app_icon.png',
                width: 96,
                height: 96,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: AppTheme.primaryColor,
                  alignment: Alignment.center,
                  child: const Icon(Icons.calendar_month_rounded,
                      color: Colors.white, size: 46),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TabsStep extends StatefulWidget {
  const _TabsStep({required this.animation});

  final Animation<double> animation;

  @override
  State<_TabsStep> createState() => _TabsStepState();
}

class _TabsStepState extends State<_TabsStep> {
  /// 只放可自定义的四个；「我的」是固定页，永远排在最后、不参与拖动。
  late List<NavPage> _order;
  late Set<NavPage> _hidden;
  NavPage _active = NavPage.home;

  static const Map<NavPage, _TabInfo> _info = <NavPage, _TabInfo>{
    NavPage.home: _TabInfo(Icons.home_rounded, '首页', '今天有什么，先看这里'),
    NavPage.message: _TabInfo(Icons.inbox_rounded, '消息', '教务、校园要闻、图书馆'),
    NavPage.course: _TabInfo(Icons.calendar_month_rounded, '课表', '按周看，考试和成绩也在'),
    NavPage.service: _TabInfo(Icons.apps_rounded, '服务', '十几个校园服务，收藏常用的'),
    NavPage.user: _TabInfo(Icons.person_rounded, '我的', '账号、外观、小组件'),
  };

  @override
  void initState() {
    super.initState();
    final layout = NavPrefs.layout;
    _order = <NavPage>[
      for (final p in layout.order)
        if (p != kPinnedNavPage) p,
    ];
    if (_order.isEmpty) {
      _order = <NavPage>[
        NavPage.home,
        NavPage.message,
        NavPage.course,
        NavPage.service,
      ];
    }
    _hidden = Set<NavPage>.from(layout.hidden);
    for (final p in _order) {
      if (!_hidden.contains(p)) {
        _active = p;
        break;
      }
    }
  }

  void _onReorder(List<NavPage> next) {
    setState(() => _order = next);
    NavPrefs.setOrder(<NavPage>[...next, kPinnedNavPage]);
  }

  void _onToggle(NavPage page) {
    if (page == kPinnedNavPage) {
      HapticFeedback.heavyImpact();
      return;
    }
    final shown = _order.where((p) => !_hidden.contains(p)).length;
    if (!_hidden.contains(page) && shown <= 1) {
      // 再收就一页都不剩了 —— 重震一下表示「不行」，比弹一句提示轻。
      HapticFeedback.heavyImpact();
      return;
    }
    final willHide = !_hidden.contains(page);
    setState(() {
      if (willHide) {
        _hidden.add(page);
      } else {
        _hidden.remove(page);
      }
      _active = page;
    });
    HapticFeedback.selectionClick();
    NavPrefs.setHidden(page, willHide);
  }

  @override
  Widget build(BuildContext context) {
    final info = _info[_active]!;
    final isDark = context.isDark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Reveal(
            animation: widget.animation,
            from: 0.05,
            to: 0.45,
            offset: const Offset(0, 14),
            child: Text(
              '五个标签，顺手排一下',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTheme.fontHero - 6,
                fontWeight: FontWeight.w700,
                color: context.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 10),
          _Reveal(
            animation: widget.animation,
            from: 0.18,
            to: 0.6,
            offset: const Offset(0, 10),
            child: Text(
              '长按可以拖动换位置。不常用的，点一下收起来，再点放回来。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                height: 1.5,
                color: context.textSecondary,
              ),
            ),
          ),
          const Spacer(),
          // 说明跟着你点的那一页走，不用另起一页去读。
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.25),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: Container(
              key: ValueKey<String>('tab-desc-${_active.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                border: Border.all(color: context.borderColor),
              ),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    ),
                    child: _tabIcon(context, _active, info.icon, 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          info.name,
                          style: TextStyle(
                            fontSize: AppTheme.fontBody,
                            fontWeight: FontWeight.w600,
                            color: context.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _hidden.contains(_active)
                              ? '${info.desc}（已收起）'
                              : info.desc,
                          style: TextStyle(
                            fontSize: AppTheme.fontSmall,
                            height: 1.4,
                            color: context.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          _EditableTabBar(
            order: _order,
            hidden: _hidden,
            active: _active,
            onReorder: _onReorder,
            onToggle: _onToggle,
          ),
          const SizedBox(height: 10),
          Text(
            '以后在「我的 → 页面设置」里还能改',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTheme.fontCaption,
              color: context.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部那条导航本身可编辑：长按拖动换顺序，点一下收起/放回。
/// 这里刻意不做成「上面一列列表 + 下面一个预览」——调整就该在它真正的位置上做。
class _EditableTabBar extends StatefulWidget {
  const _EditableTabBar({
    required this.order,
    required this.hidden,
    required this.active,
    required this.onReorder,
    required this.onToggle,
  });

  final List<NavPage> order;
  final Set<NavPage> hidden;
  final NavPage active;
  final ValueChanged<List<NavPage>> onReorder;
  final ValueChanged<NavPage> onToggle;

  @override
  State<_EditableTabBar> createState() => _EditableTabBarState();
}

class _EditableTabBarState extends State<_EditableTabBar> {
  static const Map<NavPage, _TabInfo> _info = _TabsStepState._info;

  void _handleReorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final next = List<NavPage>.from(widget.order);
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    HapticFeedback.mediumImpact();
    widget.onReorder(next);
  }

  @override
  Widget build(BuildContext context) {
    // 五个等分：整宽减去左右 padding 与两端的空隙。
    final itemW = (MediaQuery.sizeOf(context).width - 48 - 12) / 5;
    return Container(
      height: 86,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
      decoration: BoxDecoration(
        color: context.isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: context.borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: context.isDark ? 0.32 : 0.05),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              itemCount: widget.order.length,
              onReorder: _handleReorder,
              proxyDecorator: (child, index, anim) => Material(
                color: Colors.transparent,
                child: Transform.scale(scale: 1.06, child: child),
              ),
              itemBuilder: (context, i) {
                final page = widget.order[i];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey<String>('bar-${page.id}'),
                  index: i,
                  child: SizedBox(
                    width: itemW,
                    child: _item(context, page, i),
                  ),
                );
              },
            ),
          ),
          SizedBox(
            width: itemW,
            child: _item(context, kPinnedNavPage, widget.order.length),
          ),
        ],
      ),
    );
  }

  Widget _item(BuildContext context, NavPage page, int slot) {
    final info = _info[page]!;
    final hidden = widget.hidden.contains(page);
    final active = widget.active == page;
    final isPinned = page == kPinnedNavPage;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onToggle(page),
      onLongPress: () {
        if (isPinned) HapticFeedback.heavyImpact();
      },
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 220),
        opacity: hidden ? 0.34 : 1,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: active
                ? AppTheme.primaryColor.withValues(alpha: 0.07)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.max,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedScale(
                    duration: const Duration(milliseconds: 240),
                    scale: active ? 1.12 : 1,
                    child: _tabIcon(context, page, info.icon, 19),
                  ),
                  if (hidden)
                    const Positioned(
                      right: -7,
                      top: -5,
                      child: Icon(
                        Icons.visibility_off_rounded,
                        size: 11,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                  if (isPinned)
                    const Positioned(
                      right: -6,
                      top: -5,
                      child: Icon(
                        Icons.lock_rounded,
                        size: 10,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                info.name,
                maxLines: 1,
                style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? AppTheme.primaryColor : context.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 首页那一格直接用 App 图标：引导页里出现的是「你要装的那个东西」本身。
Widget _tabIcon(
  BuildContext context,
  NavPage page,
  IconData icon,
  double size,
) {
  if (page == NavPage.home) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.28),
      child: Image.asset(
        'assets/images/app_icon.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Icon(icon, size: size),
      ),
    );
  }
  return Icon(
    icon,
    size: size,
    color: AppTheme.primaryColor.withValues(alpha: 0.9),
  );
}

class _TabInfo {
  const _TabInfo(this.icon, this.name, this.desc);
  final IconData icon;
  final String name;
  final String desc;
}

/// 演示用的底部导航：跟着上面的拖动 / 隐藏实时变化，选中项有淡底 + 上浮。
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
