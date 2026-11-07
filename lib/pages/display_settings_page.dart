import 'package:flutter/material.dart';

import '../app.dart';
import '../services/app_locale.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/color_wheel_picker.dart';
import 'home_layout_settings_page.dart';
import 'nav_bar_settings_page.dart';
import 'service_settings_page.dart';
import '../widgets/app_card.dart';
import '../widgets/hand_drawn_backgrounds.dart';

/// 外观与个性化（独立页，原名「界面与显示」）。
///
/// 收纳**所有看得见的视觉设置**：
///   明暗模式 / 主题色 / 背景色 / 圆角
///   底部导航 / 首页板块 / 课表个性化（各自独立入口）
///
/// 🔴 v1.0.9：字体大小 / 语言 / 动效强度 / 振动反馈四行**已删**。
/// 它们是「体感」不是「外观」，而且和设置首屏上的入口是同一件事的两个真源
/// —— 用户在一处改了、另一处还是旧值，看起来就像「设置没生效」。
/// 现在字体 / 字号 / 振动统一在 `GeneralSettingsPage`，语言在设置首屏。
class DisplaySettingsPage extends StatefulWidget {
  const DisplaySettingsPage({super.key});

  @override
  State<DisplaySettingsPage> createState() => _DisplaySettingsPageState();
}

class _DisplaySettingsPageState extends State<DisplaySettingsPage> {
  ThemeMode _mode = ThemeMode.light;
  Color? _bgColor;
  Color? _bgDark;
  double _radiusScale = AppTheme.radiusScale;

  @override
  void initState() {
    super.initState();
    _mode = AppTheme.currentMode;
    _radiusScale = AppTheme.radiusScale;
    StorageService.loadUiBackgroundColor().then((v) {
      if (mounted) setState(() => _bgColor = v);
    });
    StorageService.loadUiBackgroundColorDark().then((v) {
      if (mounted) setState(() => _bgDark = v);
    });
  }

  Future<void> _applyRadius(double v) async {
    AppTheme.setRadiusScale(v);
    await StorageService.saveUiRadiusScale(v);
  }

  Future<void> _applyPrimary(Color c) async {
    AppTheme.setPrimary(c);
    final cfg = await StorageService.loadUserConfig();
    await StorageService.saveUserConfig(cfg.copyWith(primaryColor: c.toARGB32()));
  }

  Future<void> _applyMode(ThemeMode m) async {
    setState(() => _mode = m);
    AppTheme.setMode(m);
    final cfg = await StorageService.loadUserConfig();
    await StorageService.saveUserConfig(cfg.copyWith(themeMode: m));
  }

  Future<void> _applyBackground(Color? c, {bool dark = false}) async {
    // 🔴 2026-11-03：不再 `Color.alphaBlend(c, Colors.white)`。
    //
    // 原来这一行把用户选的半透明色**永久压成不透明白底**，后果有两个：
    //   1. 深色模式下页面底色是 0xFF121212，把「米黄」压成 `alphaBlend(米黄, 白)`
    //      得到的仍是亮色 → 深色模式下一换背景就整页变白，所以背景色这一行
    //      被 `if (!isDark)` 藏起来了，用户以为「深色不能换背景」。
    //   2. 每次改背景都往存储里写一个已经压过的色，反复横跳会越来越白。
    // 现在原样存、原样用；深色模式下由 `scaffoldColor` 决定要不要跟随（见
    // app_theme 的 `scaffoldColor`：暗色固定 0xFF121212，亮色才读背景色）。
    if (dark) {
      setState(() => _bgDark = c);
      AppTheme.setBackgroundDark(c);
      await StorageService.saveUiBackgroundColorDark(c);
      return;
    }
    setState(() => _bgColor = c);
    AppTheme.setBackground(c);
    await StorageService.saveUiBackgroundColor(c);
  }

  /// 手绘纸纹背景选择（2026-11-04，实验性）。
  ///
  /// 🔴 用 `showDialog` + `AlertDialog`，**不是** `showModalBottomSheet`：
  ///    本项目 UI 死律禁止底部弹层（见 display_settings_page 各处的同类实现，
  ///    以及 nav_bar / home_layout 等子页同样只用居中卡片）。
  Future<void> _openHandDrawnPicker() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final picked = await showDialog<HandDrawnBackground>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.cardColor,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          side: BorderSide(color: AppTheme.cardStrokeColor(ctx.isDark)),
        ),
        // `EdgeInsets.symmetric` 的 vertical 默认是 0（不是继承 AlertDialog
        // 原本的 24），所以要显式写出来：7 个预览格比普通弹窗高，留白不够的
        // 话矮屏上会直接顶到状态栏 / 贴住底部手势条。
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        title: const Text('手绘背景'),
        contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '给整个 App 铺一层淡淡的纸纹。选定后一直生效，直到你换别的背景色。',
                style: TextStyle(
                    fontSize: AppTheme.fontCaption, color: ctx.textTertiary),
              ),
              const SizedBox(height: 14),
              // 2 列网格：7 个选项（含「不启用」）刚好 4 行，末行只有一个。
              // 不用 GridView（弹窗里会因无界高度报错），直接按行切。
              for (var i = 0;
                  i < HandDrawnBackground.values.length;
                  i += 2)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var j = i;
                          j < i + 2 &&
                              j < HandDrawnBackground.values.length;
                          j++) ...[
                        if (j > i) const SizedBox(width: 10),
                        Expanded(
                          child: _handDrawnTile(
                            ctx,
                            HandDrawnBackground.values[j],
                            isDark: isDark,
                          ),
                        ),
                      ],
                      // 奇数个时补一个等宽空位：不能让最后一格撑满整行，
                      // 否则它会比上面每格都宽，网格看着就歪了。
                      if (i + 1 >= HandDrawnBackground.values.length) ...[
                        const SizedBox(width: 10),
                        const Expanded(child: SizedBox.shrink()),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(S.t('cancel')),
          ),
        ],
      ),
    );
    if (picked == null) return;
    await changeHandDrawnBackground(picked);
    if (!mounted) return;
    setState(() {});
  }

  /// 弹窗里的一格：72 高的实时预览 + 名字。
  Widget _handDrawnTile(
    BuildContext ctx,
    HandDrawnBackground kind, {
    required bool isDark,
  }) {
    final selected = handDrawnBackgroundNotifier.value == kind;
    final radius = BorderRadius.circular(AppTheme.radiusSm);
    // 圆角是用户可调的（`radiusSm` 在 0.2 倍时只有 2~3），内层预览的圆角
    // 必须跟着收，不能硬写 `radiusSm - 4` —— 那会变成负数，
    // `BorderRadius.circular` 拿到负值直接断言失败 → 弹窗一开就红屏。
    final tileRadius = AppTheme.radiusSm;
    final innerRadius =
        BorderRadius.circular(tileRadius > 4 ? tileRadius - 4 : 0);
    return GestureDetector(
      onTap: () => Navigator.of(ctx).pop(kind),
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: radius,
          // 不用纯色卡片底：预览自己带「纸」底，这里只负责描边 / 选中框，
          // 否则「不启用」一格会显得比别的格暗。
          border: Border.all(
            color: selected ? AppTheme.primaryColor : ctx.borderColor,
            width: selected ? 2 : 1,
          ),
        ),
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 72,
              child: ClipRRect(
                borderRadius: innerRadius,
                child: kind.isHandDrawn
                    ? HandDrawnBackgroundPreview(kind: kind, isDark: isDark)
                    : ColoredBox(
                        color: isDark
                            ? AppTheme.surfaceDark
                            : AppTheme.backgroundColor,
                        child: Center(
                          child: Text('无',
                              style: TextStyle(
                                  fontSize: AppTheme.fontCaption,
                                  color: ctx.textTertiary)),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    kind.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? ctx.textPrimary : ctx.textSecondary,
                    ),
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle_rounded,
                      size: 14, color: AppTheme.primaryColor),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 恢复默认外观（2026-11-03 新增，v1.0.9 收窄作用域）。
  ///
  /// 为什么值得单独做一个按钮：这一页有 6 个可调项，用户调到「四不像」
  /// 之后没有任何办法回到原点 —— 只能一项一项猜着调回去。课表个性化
  /// 页早就有「恢复默认设置」，这里缺一个，属于同一类功能的缺口。
  ///
  /// 🔴 v1.0.9：作用域**只到本页 4 项**（明暗模式 / 主题色 / 背景色 / 圆角）。
  /// 字号、语言、动效、振动已经不归本页管，如果还在这里一并复位，
  /// 用户在「通用设置」里调好的字号会被这里的按钮悄悄清掉。
  Future<void> _resetAppearance() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复默认外观'),
        content: const Text(
            '明暗模式、主题色、背景色、手绘背景与圆角都会回到默认值。课表、待办等数据不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(S.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _mode = ThemeMode.light;
      _bgColor = null;
      _bgDark = null;
      _radiusScale = AppTheme.defaultRadiusScale;
    });
    AppTheme.setMode(ThemeMode.light);
    AppTheme.setPrimary(AppTheme.defaultPrimary);
    AppTheme.setBackground(null);
    AppTheme.setBackgroundDark(null);
    AppTheme.setRadiusScale(AppTheme.defaultRadiusScale);
    // 2026-11-04：手绘背景同居本页，一并复位（否则「恢复默认外观」后纸纹还在）。
    // 复位后要再 setState 一次：上面那个 setState 早于本行执行，
    // 不补的话「手绘背景」这一行右侧的文字还停在旧的风格名上。
    await changeHandDrawnBackground(HandDrawnBackground.none);
    if (!mounted) return;
    setState(() {});

    final cfg = await StorageService.loadUserConfig();
    await StorageService.saveUserConfig(cfg.copyWith(
      themeMode: ThemeMode.light,
      primaryColor: AppTheme.defaultPrimary.toARGB32(),
    ));
    await StorageService.saveUiBackgroundColor(null);
    await StorageService.saveUiBackgroundColorDark(null);
    await StorageService.saveUiRadiusScale(AppTheme.defaultRadiusScale);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已恢复默认外观')));
  }

  /// 打开服务管理（v1.0.9 从设置首屏搬进来）。
  Future<void> _openServiceManager() async {
    // 先抓 navigator：await 之后再用 context 会踩
    // `use_build_context_synchronously`（用户可能已经离开本页）。
    final navigator = Navigator.of(context);
    final hidden = await StorageService.loadHiddenServices();
    if (!mounted) return;
    await navigator.push(MaterialPageRoute<void>(
        builder: (_) => ServiceSettingsPage(hidden: hidden)));
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // ⚠️ Column 的 crossAxisAlignment.start 会让子 Row 拿到**无界宽度**，
    //    而 Row 里若含 Expanded（模式胶囊）就会抛
    //    「RenderFlex children have non-zero flex but incoming width
    //    constraints are unbounded」→ 整页渲染失败 → 灰屏。
    //    用 SizedBox(width: double.infinity) 把宽度约束固定住。
    Widget row(String title, Widget child) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w500,
                      color: context.textPrimary)),
              const SizedBox(height: 10),
              SizedBox(width: double.infinity, child: child),
            ],
          ),
        );

    Widget entry(IconData icon, String title, VoidCallback onTap,
            {String? trailing}) =>
        InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: AppTheme.primaryColor),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(title,
                        style: TextStyle(
                            fontSize: AppTheme.fontBody,
                            fontWeight: FontWeight.w500,
                            color: context.textPrimary)),
                  ),
                  if (trailing != null) ...[
                    Text(trailing,
                        style: TextStyle(
                            fontSize: AppTheme.fontBody,
                            color: context.textTertiary)),
                    const SizedBox(width: 6),
                  ],
                  Icon(Icons.chevron_right, size: 20, color: context.textTertiary),
                ],
              ),
            ),
          ),
        );

    Widget colorDot(Color color, bool selected, VoidCallback onTap) =>
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? context.textPrimary : context.borderColor,
                width: selected ? 2 : 1,
              ),
            ),
            child: selected
                ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                : null,
          ),
        );

    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: Text(S.t('display_title'),
            style: const TextStyle(fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        // 2026-11-03：底部 padding 叠上系统手势条高度。
        // 原来是死值 32，targetSdk 35 强制 edge-to-edge 之后，
        // 末行（例如设置页的备案号）会被导航条压住。
        padding: EdgeInsets.fromLTRB(
          20,
          8,
          20,
          MediaQuery.of(context).padding.bottom + 32,
        ),
        children: [
          // ---------------- 外观 ----------------
          _card([
            // ⚠️ 三个胶囊用 Expanded 等分 → 在无界宽度容器里会抛
            //    「RenderFlex children have non-zero flex but incoming width
            //    constraints are unbounded」。这里改为 Expanded 外层 + 内容自适应，
            //    保证任何容器宽度下都能正常布局。
            row(S.t('display_mode'), Row(
              children: [
                Expanded(
                  child: _modePill(S.t('light'), Icons.light_mode_rounded,
                      ThemeMode.light, expand: false),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _modePill(S.t('dark'), Icons.dark_mode_rounded,
                      ThemeMode.dark, expand: false),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _modePill(S.t('system'),
                      Icons.brightness_auto_rounded, ThemeMode.system,
                      expand: false),
                ),
              ],
            )),
            Divider(height: 1, color: context.borderColor),
            ValueListenableBuilder<Color>(
              valueListenable: AppTheme.primaryNotifier,
              builder: (ctx, current, __) => row(
                '主题色',
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (final e in AppTheme.primaryPresets)
                      colorDot(e.$2, e.$2.toARGB32() == current.toARGB32(),
                          () => _applyPrimary(e.$2)),
                    _customDot(current),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: context.borderColor),
            // 2026-11-03：深色模式也给背景色。此前整行被 `if (!isDark)` 藏掉，
            // 用户以为「深色不能换背景」；现在浅色选 backgroundPresets、
            // 深色选 backgroundPresetsDark，两组预设一一对应。
            row(S.t('display_bg'), Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final e
                    in (isDark
                        ? AppTheme.backgroundPresetsDark
                        : AppTheme.backgroundPresets))
                  colorDot(
                    e.$2,
                    e.$1 == '默认'
                        ? (isDark ? _bgDark == null : _bgColor == null)
                        : (isDark
                              ? _bgDark?.toARGB32() == e.$2.toARGB32()
                              : _bgColor?.toARGB32() == e.$2.toARGB32()),
                    () => _applyBackground(
                      e.$1 == '默认' ? null : e.$2,
                      dark: isDark,
                    ),
                  ),
                _customBgDot(dark: isDark),
              ],
            )),
            Divider(height: 1, color: context.borderColor),
            // 2026-11-04（实验性）：手绘纸纹背景。
            // ⚠️ 它是**纹理**不是底色：与上面的「背景色」互斥（设了自定义
            //    背景色 / 课表背景图时纸纹自动不生效，见 HandDrawnBackgroundLayer），
            //    这一行只负责挑风格。
            //
            // 🔴 用 ValueListenableBuilder 读当前值，不要直接读
            //    `handDrawnBackgroundNotifier.value`：本页不监听这个 notifier，
            //    直接读的话，任何不经本页 setState 的改动（如导入外观方案）
            //    都会让右侧名字停在旧值上。
            ValueListenableBuilder<HandDrawnBackground>(
              valueListenable: handDrawnBackgroundNotifier,
              builder: (ctx, kind, __) => entry(
                Icons.auto_awesome_outlined,
                '手绘背景',
                _openHandDrawnPicker,
                trailing: kind.label,
              ),
            ),
            Divider(height: 1, color: context.borderColor),
            row(S.t('display_radius'), _slider(
              value: _radiusScale,
              min: AppTheme.minRadiusScale,
              max: AppTheme.maxRadiusScale,
              divisions: 28,
              labels: const ['直角', '圆润'],
              onChanged: (v) => setState(() => _radiusScale = v),
              onChangeEnd: _applyRadius,
            )),
          ]),
          const SizedBox(height: 12),

          // ---------------- 布局入口 ----------------
          _card([
            entry(Icons.view_agenda_outlined, S.t('display_nav'), () {
              Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const NavBarSettingsPage()));
            }),
            Divider(height: 1, color: context.borderColor),
            entry(Icons.tune_rounded, S.t('display_home'), () {
              Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const HomeLayoutSettingsPage()));
            }),
            Divider(height: 1, color: context.borderColor),
            // v1.0.9：课表个性化从设置首屏搬进来 —— 它和「首页板块」「底部导航」
            // 是同一类（都是「某个页面的样子」），分两处放没有道理。
            entry(Icons.grid_view_rounded, S.t('item_course_style'), () {
              // 课表设置页要的回调全在课表页手里，这里只能发信号让课表页去开。
              // 先把本页弹掉，否则用户点完课表设置回来会看到一个残留的二级页。
              Navigator.of(context).pop();
              AppTabs.openCourseSettings();
            }),
            Divider(height: 1, color: context.borderColor),
            // 用户口径（2026-11-03）：「服务管理应该也并入外观与个性化」。
            // 服务管理本来就是「首页上显示哪些服务卡」—— 属于外观编排，
            // 留在设置首屏当独立区块是把同一件事放到两个门里。
            entry(
              Icons.apps_rounded,
              S.t('item_service_manager'),
              _openServiceManager,
            ),
          ]),
          const SizedBox(height: 12),

          // ---------------- 恢复默认外观 ----------------
          // 一页 8 个可调项，调花了之后没有回原点的路 —— 课表个性化页
          // 早就有「恢复默认设置」，这里补齐同一类功能。
          AppCard(
            radius: AppTheme.radiusLg,
            padding: EdgeInsets.zero,
            child: InkWell(
              onTap: _resetAppearance,
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
              child: SizedBox(
                height: 50,
                width: double.infinity,
                child: Center(
                  child: Text(
                    '恢复默认外观',
                    style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.danger,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(List<Widget> children) => AppCard(
        radius: AppTheme.radiusLg,
        // ⚠️ 必须 stretch：否则子 Row 拿到无界宽度，
        //    Row 里的 Expanded 会抛「non-zero flex but unbounded constraints」
        //    → 整页渲染失败 → 灰屏。
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );

  Widget _slider({
    required double value,
    required double min,
    required double max,
    required int divisions,
    required List<String> labels,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) =>
      Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.5,
              activeTrackColor: AppTheme.primaryColor,
              inactiveTrackColor: context.borderColor,
              thumbColor: AppTheme.primaryColor,
              overlayColor: AppTheme.primaryColor.withValues(alpha: 0.12),
              thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 7, elevation: 0),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 13),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final l in labels)
                Text(l,
                    style: TextStyle(fontSize: AppTheme.fontCaption, color: context.textTertiary)),
            ],
          ),
        ],
      );

  /// 明暗模式胶囊（v1.0.9：语言参数已删，语言改走设置首屏的就地下拉）。
  ///
  /// ⚠️ 这里返回的是**内容**而不是 [Expanded]：调用方若再套一层
  /// [Padding]，Expanded 就会跨过 ParentDataWidget 直接挂到 Row 上，
  /// 违反 Flutter 的 ParentDataWidget 契约 → 运行时抛异常 → 整页灰屏。
  /// 需要等分时由调用方自己包 Expanded。
  Widget _modePill(String label, IconData icon, ThemeMode mode,
      {bool expand = true}) {
    final selected = _mode == mode;
    final content = GestureDetector(
        onTap: () => _applyMode(mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 40,
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.primaryColor.withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            border: Border.all(
              color: selected ? AppTheme.primaryColor : context.borderColor,
              width: selected ? 1.2 : 1,
            ),
          ),
          // ⚠️ 这里**不能用 Flexible**：胶囊可能被放进无界宽度的容器，
          //    Row 里的 flex 子元素遇到无界宽度会抛
          //    「non-zero flex but unbounded constraints」→ 整页灰屏。
          //    文字都很短（浅色/深色/中文/English），直接放即可。
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16,
                  color: selected
                      ? AppTheme.primaryColor
                      : context.textTertiary),
              const SizedBox(width: 5),
              Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected
                      ? AppTheme.primaryColor
                      : context.textSecondary,
                ),
              ),
            ],
          ),
        ),
    );
    // 需要等分时才包 Expanded（调用方决定）。
    return expand ? Expanded(child: content) : content;
  }

  Widget _customDot(Color current) => GestureDetector(
        onTap: () async {
          final picked = await showColorWheelPicker(
            context,
            initial: current,
            title: '自定义主题色',
          );
          if (picked != null) await _applyPrimary(picked);
        },
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const SweepGradient(colors: _rainbow),
            border: Border.all(
              color: AppTheme.primaryPresets.any((e) => e.$2.toARGB32() == current.toARGB32())
                  ? context.borderColor
                  : AppTheme.primaryColor,
              width: 2,
            ),
          ),
        ),
      );

  Widget _customBgDot({bool dark = false}) {
    final current = dark ? _bgDark : _bgColor;
    final presets = dark ? AppTheme.backgroundPresetsDark : AppTheme.backgroundPresets;
    final isCustom =
        current != null && !presets.any((e) => e.$2.toARGB32() == current.toARGB32());
    return GestureDetector(
      onTap: () async {
        final picked = await showColorWheelPicker(
          context,
          initial: current ?? (dark ? AppTheme.scaffoldDark : AppTheme.backgroundColor),
          title: '自定义背景色',
        );
        if (picked != null) await _applyBackground(picked, dark: dark);
      },
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const SweepGradient(colors: _rainbow),
          border: Border.all(
            color: isCustom ? AppTheme.primaryColor : context.borderColor,
            width: isCustom ? 2 : 1,
          ),
        ),
        child: isCustom
            ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
            : null,
      ),
    );
  }

  static const _rainbow = <Color>[
    Color(0xFFEF4444), Color(0xFFF59E0B), Color(0xFFEAB308),
    Color(0xFF22C55E), Color(0xFF06B6D4), Color(0xFF3B82F6),
    Color(0xFF8B5CF6), Color(0xFFEF4444),
  ];
}
