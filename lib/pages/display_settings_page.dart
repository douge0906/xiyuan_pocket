import 'package:flutter/material.dart';

import '../services/app_locale.dart';
import '../services/storage_service.dart';
import '../services/ui_prefs.dart';
import '../theme/app_theme.dart';
import '../widgets/color_wheel_picker.dart';
import 'home_layout_settings_page.dart';
import 'nav_bar_settings_page.dart';
import '../widgets/app_card.dart';

/// 界面与显示（独立页）。
///
/// 收纳「看得见的一切」：
///   明暗模式 / 主题色 / 背景色 / 圆角
///   底部导航 / 首页个性化（各自独立入口）
///   字体大小（**带实时预览**）/ 语言 / 动效强度 / 振动
class DisplaySettingsPage extends StatefulWidget {
  const DisplaySettingsPage({super.key});

  @override
  State<DisplaySettingsPage> createState() => _DisplaySettingsPageState();
}

class _DisplaySettingsPageState extends State<DisplaySettingsPage> {
  ThemeMode _mode = ThemeMode.light;
  Color? _bgColor;
  double _radiusScale = AppTheme.radiusScale;
  double _textScale = 1.0;
  double _motion = 1.0;
  bool _haptics = true;

  @override
  void initState() {
    super.initState();
    _mode = AppTheme.currentMode;
    _radiusScale = AppTheme.radiusScale;
    _textScale = UiPrefs.textScale;
    _motion = UiPrefs.motion;
    StorageService.loadUiBackgroundColor().then((v) {
      if (mounted) setState(() => _bgColor = v);
    });
    StorageService.loadUiTextScale().then((v) {
      if (mounted) setState(() => _textScale = v);
    });
    StorageService.loadUiMotion().then((v) {
      if (mounted) setState(() => _motion = v);
    });
    StorageService.loadUiHaptics().then((v) {
      if (mounted) setState(() => _haptics = v);
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

  Future<void> _applyBackground(Color? c) async {
    final applied = c == null ? null : Color.alphaBlend(c, Colors.white);
    setState(() => _bgColor = applied);
    AppTheme.setBackground(applied);
    await StorageService.saveUiBackgroundColor(applied);
  }

  Future<void> _applyTextScale(double v) async {
    setState(() => _textScale = v);
    UiPrefs.setTextScale(v);
    await StorageService.saveUiTextScale(v);
  }

  Future<void> _applyMotion(double v) async {
    setState(() => _motion = v);
    UiPrefs.setMotion(v);
    await StorageService.saveUiMotion(v);
  }

  Future<void> _applyHaptics(bool v) async {
    setState(() => _haptics = v);
    UiPrefs.setHaptics(v);
    await StorageService.saveUiHaptics(v);
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

    Widget entry(IconData icon, String title, VoidCallback onTap) => InkWell(
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
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
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
            const Divider(height: 1, color: Color(0x22000000)),
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
            if (!isDark) ...[
              const Divider(height: 1, color: Color(0x22000000)),
              row(S.t('display_bg'), Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final e in AppTheme.backgroundPresets)
                    colorDot(
                      e.$2,
                      e.$1 == '默认' ? _bgColor == null : _bgColor?.toARGB32() == e.$2.toARGB32(),
                      () => _applyBackground(e.$1 == '默认' ? null : e.$2),
                    ),
                  _customBgDot(),
                ],
              )),
            ],
            const Divider(height: 1, color: Color(0x22000000)),
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
            const Divider(height: 1, color: Color(0x22000000)),
            entry(Icons.tune_rounded, S.t('display_home'), () {
              Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const HomeLayoutSettingsPage()));
            }),
          ]),
          const SizedBox(height: 12),

          // ---------------- 阅读与体感 ----------------
          _card([
            row(S.t('display_font'), Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _slider(
                  value: _textScale,
                  min: UiPrefs.minTextScale,
                  max: UiPrefs.maxTextScale,
                  divisions: 9,
                  labels: const ['小', '标准', '大'],
                  onChanged: (v) => setState(() => _textScale = v),
                  onChangeEnd: _applyTextScale,
                ),
                const SizedBox(height: 12),
                // 实时预览：滑杆一动，下面的样例文字立刻跟着变大变小。
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: context.surfaceColor,
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    border: Border.all(color: context.borderColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(S.t('display_font_preview'),
                          style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              fontWeight: FontWeight.w600,
                              color: context.textPrimary)),
                      const SizedBox(height: 4),
                      Text(S.t('display_font_preview2'),
                          style: TextStyle(
                              fontSize: AppTheme.fontSmall, color: context.textSecondary)),
                    ],
                  ),
                ),
              ],
            )),
            const Divider(height: 1, color: Color(0x22000000)),
            row(S.t('display_lang'), Row(
              children: [
                for (final l in AppLanguage.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    // expand: false —— 胶囊按内容宽度自适应，不占满整行。
                    child: _modePill(l.label, Icons.language_rounded, null,
                        language: l, expand: false),
                  ),
              ],
            )),
            const Divider(height: 1, color: Color(0x22000000)),
            row(S.t('display_motion'), _slider(
              value: _motion,
              min: UiPrefs.minMotion,
              max: UiPrefs.maxMotion,
              divisions: 4,
              labels: const ['关闭', '完整'],
              onChanged: (v) => setState(() => _motion = v),
              onChangeEnd: _applyMotion,
            )),
            const Divider(height: 1, color: Color(0x22000000)),
            row(S.t('display_haptic'), Switch.adaptive(
              value: _haptics,
              activeColor: AppTheme.primaryColor,
              onChanged: _applyHaptics,
            )),
          ]),
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

  /// 模式/语言胶囊。
  ///
  /// ⚠️ 这里返回的是**内容**而不是 [Expanded]：调用方若再套一层
  /// [Padding]，Expanded 就会跨过 ParentDataWidget 直接挂到 Row 上，
  /// 违反 Flutter 的 ParentDataWidget 契约 → 运行时抛异常 → 整页灰屏。
  /// 需要等分时由调用方自己包 Expanded。
  Widget _modePill(String label, IconData icon, ThemeMode? mode,
      {AppLanguage? language, bool expand = true}) {
    final selected = language != null
        ? AppLocale.current == language
        : (mode != null && _mode == mode);
    final content = GestureDetector(
        onTap: () {
          if (language != null) {
            setState(() {});
            AppLocale.setLanguage(language);
            return;
          }
          if (mode == null) return;
          _applyMode(mode);
        },
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

  Widget _customBgDot() {
    final isCustom = _bgColor != null &&
        !AppTheme.backgroundPresets.any((e) => e.$2.toARGB32() == _bgColor!.toARGB32());
    return GestureDetector(
      onTap: () async {
        final picked = await showColorWheelPicker(
          context,
          initial: _bgColor ?? AppTheme.backgroundColor,
          title: '自定义背景色',
        );
        if (picked != null) await _applyBackground(picked);
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
