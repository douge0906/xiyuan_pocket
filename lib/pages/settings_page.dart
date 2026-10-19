import 'package:flutter/material.dart';

import 'home_layout_settings_page.dart';

import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/color_wheel_picker.dart';
import 'nav_bar_settings_page.dart';
import 'user/user_cards.dart';

/// 设置页：个性化（明暗 / 主题色 / 背景色 / 圆角 / 底部导航）+ 账户。
///
/// v1.5.0（2026-10-14）外观区重做 —— 仿「课表设置页」板块样式：
///  · 一个「个性化主题」折叠板块（**默认展开**），内部五行横排紧凑排列：
///    ① 明暗模式：浅色 / 深色 / 跟随系统（三选一横排）
///    ② 主题色：一排色点 + 末尾彩色圆盘（自定义 RGB）
///    ③ 背景色：一排色点（仅浅色模式显示）
///    ④ 圆角：连续滑杆（v1.4.0 已就绪）
///    ⑤ 底部导航（v1.7.0）：隐藏 / 排序，独立子页面
///  · 删掉原来的底部引导小字（用户：不堆小字、紧凑排列）
///
/// 上课提醒设置已迁移至：课表页顶部 → 提醒按钮（v2.3.0）。
class SettingsPage extends StatefulWidget {
  final Future<void> Function() onLogout;
  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode) onThemeChanged;

  /// 当前主题色（外部 ValueNotifier，便于本页与全局同步）。
  final ValueNotifier<Color> primaryColor;
  final Future<void> Function(Color) onPrimaryChanged;

  const SettingsPage({
    super.key,
    required this.onLogout,
    required this.themeMode,
    required this.onThemeChanged,
    required this.primaryColor,
    required this.onPrimaryChanged,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late ThemeMode _mode;

  /// 「个性化主题」板块默认展开（用户要求）。
  bool _themeOpen = true;

  /// 全局圆角缩放系数（0.5~1.6），见 AppTheme.setRadiusScale。
  double _radiusScale = 1.0;

  /// 页面背景色（null = 默认；仅浅色模式生效）。
  Color? _bgColor;

  @override
  void initState() {
    super.initState();
    _mode = widget.themeMode;
    // 2026-10-13：全局圆角（紧凑 / 标准 / 圆润）
    StorageService.loadUiRadiusScale().then((v) {
      if (mounted) setState(() => _radiusScale = v);
    });
    // v1.5.0：页面背景色
    StorageService.loadUiBackgroundColor().then((v) {
      if (mounted) setState(() => _bgColor = v);
    });
  }

  /// 应用全局圆角：立刻生效（main.dart 监听 radiusNotifier 整树重建）+ 存盘。
  Future<void> _applyRadius(double v) async {
    AppTheme.setRadiusScale(v);
    await StorageService.saveUiRadiusScale(v);
  }

  /// 切换主题色：通知器立即全局生效 + 回调父级持久化。
  Future<void> _applyPrimary(Color c) async {
    AppTheme.setPrimary(c);
    await widget.onPrimaryChanged(c);
  }

  /// 切换背景色（null = 默认）：立即全局生效 + 存盘。
  Future<void> _applyBackground(Color? c) async {
    setState(() => _bgColor = c);
    AppTheme.setBackground(c);
    await StorageService.saveUiBackgroundColor(c);
  }

  Future<void> _pickMode(ThemeMode m) async {
    if (_mode == m) return;
    setState(() => _mode = m); // 立刻反映勾选，不等父级回调
    await widget.onThemeChanged(m);
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出账户',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: const Text('确定要退出登录吗？\n退出后本机的课表、待办、成绩等数据会被清空。',
            style: TextStyle(fontSize: 14, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE24B4A),
              foregroundColor: Colors.white,
            ),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.onLogout();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: const Text('设置',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        children: [
          _themeSection(isDark),
          const SizedBox(height: 12),
          _accountSection(),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 个性化主题

  Widget _themeSection(bool isDark) {
    return userCard(
      context,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _themeOpen = !_themeOpen),
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            child: SizedBox(
              height: 52,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(Icons.palette_rounded,
                        size: 20, color: AppTheme.primaryColor),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('个性化主题',
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: context.textPrimary,
                          )),
                    ),
                    AnimatedRotation(
                      turns: _themeOpen ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Icon(Icons.keyboard_arrow_down_rounded,
                          size: 20, color: context.textTertiary),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_themeOpen) ...[
            Divider(height: 1, color: context.borderColor),
            _modeRow(),
            Divider(height: 1, color: context.borderColor),
            _primaryRow(),
            // 背景色仅浅色模式有意义（深色固定深色背景）
            if (!isDark) ...[
              Divider(height: 1, color: context.borderColor),
              _backgroundRow(),
            ],
            Divider(height: 1, color: context.borderColor),
            _radiusTile(),
            Divider(height: 1, color: context.borderColor),
            // v1.7.0：底部导航自定义（隐藏 / 排序）——独立子页面
            _navLayoutTile(),
            Divider(height: 1, color: context.borderColor),
            // 2026-10-17：首页板块显隐（原首页右上角按钮，移到这里）
            _homeLayoutTile(),
          ],
        ],
      ),
    );
  }

  /// ⑥ 首页个性化：入口行（2026-10-17 从首页右上角移到这里）。
  Widget _homeLayoutTile() {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
            builder: (_) => const HomeLayoutSettingsPage()),
      ),
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(Icons.tune_rounded, size: 20, color: AppTheme.primaryColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text('首页个性化',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      color: context.textPrimary,
                    )),
              ),
              Icon(Icons.chevron_right, size: 20, color: context.textTertiary),
            ],
          ),
        ),
      ),
    );
  }

  /// ⑤ 底部导航：入口行（图标 + 标题 + 右箭头），点进去做隐藏 / 排序。
  Widget _navLayoutTile() {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
            builder: (_) => const NavBarSettingsPage()),
      ),
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(Icons.view_agenda_outlined,
                  size: 20, color: AppTheme.primaryColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text('底部导航',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      color: context.textPrimary,
                    )),
              ),
              Icon(Icons.chevron_right, size: 20, color: context.textTertiary),
            ],
          ),
        ),
      ),
    );
  }

  /// ① 明暗模式：浅色 / 深色 / 跟随系统，横排三选一。
  Widget _modeRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          _modePill('浅色', Icons.light_mode_rounded, ThemeMode.light),
          const SizedBox(width: 8),
          _modePill('深色', Icons.dark_mode_rounded, ThemeMode.dark),
          const SizedBox(width: 8),
          _modePill('跟随系统', Icons.brightness_auto_rounded, ThemeMode.system),
        ],
      ),
    );
  }

  Widget _modePill(String label, IconData icon, ThemeMode mode) {
    final selected = _mode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () => _pickMode(mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 40,
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.primaryColor.withOpacity(0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            border: Border.all(
              color: selected ? AppTheme.primaryColor : context.borderColor,
              width: selected ? 1.2 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16,
                  color:
                      selected ? AppTheme.primaryColor : context.textTertiary),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected
                      ? AppTheme.primaryColor
                      : context.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// ② 主题色：一排预设色点 + 末尾彩色圆盘（自定义）。
  Widget _primaryRow() {
    return ValueListenableBuilder<Color>(
      valueListenable: AppTheme.primaryNotifier,
      builder: (ctx, current, __) => _rowShell(
        title: '主题色',
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final e in AppTheme.primaryPresets)
              _colorDot(e.$2, e.$2.value == current.value,
                  () => _applyPrimary(e.$2)),
            _customDot(current),
          ],
        ),
      ),
    );
  }

  /// ③ 背景色：一排预设色点 + 末尾彩色圆盘（自定义，仅浅色模式渲染）。
  Widget _backgroundRow() {
    return _rowShell(
      title: '背景色',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          ...AppTheme.backgroundPresets.map((e) {
            final isDefault = e.$1 == '默认';
            final selected =
                isDefault ? _bgColor == null : _bgColor?.value == e.$2.value;
            return GestureDetector(
              onTap: () => _applyBackground(isDefault ? null : e.$2),
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: e.$2,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? AppTheme.primaryColor : context.borderColor,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: selected
                    ? Icon(Icons.check_rounded,
                        size: 16,
                        color: e.$2.computeLuminance() > 0.7
                            ? Colors.black54
                            : Colors.white)
                    : null,
              ),
            );
          }),
          _customBgDot(),
        ],
      ),
    );
  }

  /// 自定义背景色圆盘：彩虹扫掠渐变；当前为自定义色时显示勾。
  Widget _customBgDot() {
    final isCustom = _bgColor != null &&
        !AppTheme.backgroundPresets.any((e) => e.$2.value == _bgColor!.value);
    return GestureDetector(
      onTap: _pickCustomBgColor,
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

  /// 自定义背景色（v1.6.3）：改用色盘选择器（仿掌上徐工），可拖出任意颜色。
  Future<void> _pickCustomBgColor() async {
    final picked = await showColorWheelPicker(
      context,
      initial: _bgColor ?? AppTheme.backgroundColor,
      title: '自定义背景色',
    );
    if (picked != null) await _applyBackground(picked);
  }

  /// ④ 圆角：连续滑杆（两端方向词，无百分比）。
  Widget _radiusTile() {
    final v = _radiusScale.clamp(0.5, 1.6).toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.rounded_corner_rounded,
                  size: 20, color: Color(0xFF9CA3AF)),
              const SizedBox(width: 12),
              Expanded(
                child: Text('圆角',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: context.textPrimary)),
              ),
            ],
          ),
          SizedBox(
            height: 32,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                activeTrackColor: AppTheme.primaryColor,
                inactiveTrackColor: context.borderColor,
                thumbColor: AppTheme.primaryColor,
                overlayColor: AppTheme.primaryColor.withOpacity(0.12),
                thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7, elevation: 0),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
              ),
              child: Slider(
                value: v,
                min: 0.5,
                max: 1.6,
                divisions: 22,
                onChanged: (nv) => setState(() => _radiusScale = nv),
                onChangeEnd: _applyRadius,
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('紧凑',
                  style:
                      TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              Text('圆润',
                  style:
                      TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ],
          ),
        ],
      ),
    );
  }

  /// 行容器：小标题 + 控件（与课表设置页滑杆行一致的紧凑结构）。
  Widget _rowShell({required String title, required Widget child}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: context.textPrimary,
              )),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _colorDot(Color color, bool selected, VoidCallback onTap) {
    return GestureDetector(
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
  }

  /// 自定义颜色圆盘：彩虹扫掠渐变暗示"任意色"；当前为自定义色时显示勾。
  static const _rainbow = <Color>[
    Color(0xFFEF4444), Color(0xFFF59E0B), Color(0xFFEAB308),
    Color(0xFF22C55E), Color(0xFF06B6D4), Color(0xFF3B82F6),
    Color(0xFF8B5CF6), Color(0xFFEF4444),
  ];

  Widget _customDot(Color current) {
    final isCustom =
        !AppTheme.primaryPresets.any((e) => e.$2.value == current.value);
    return GestureDetector(
      onTap: _pickCustomColor,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const SweepGradient(colors: _rainbow),
          border: Border.all(
            color: isCustom ? context.textPrimary : context.borderColor,
            width: isCustom ? 2 : 1,
          ),
        ),
        child: isCustom
            ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
            : null,
      ),
    );
  }

  /// 自定义主题色（v1.6.3）：改用色盘选择器（仿掌上徐工），可拖出任意颜色。
  Future<void> _pickCustomColor() async {
    final picked = await showColorWheelPicker(
      context,
      initial: AppTheme.primaryColor,
      title: '自定义主题色',
    );
    if (picked != null) await _applyPrimary(picked);
  }


  // ------------------------------------------------------------ 账户

  Widget _accountSection() {
    return userCard(
      context,
      padding: EdgeInsets.zero,
      child: ListTile(
        onTap: _confirmLogout,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: const Icon(Icons.logout_rounded,
            color: Color(0xFFE24B4A), size: 20),
        title: Text('退出账户',
            style: TextStyle(fontSize: 14, color: context.textPrimary)),
      ),
    );
  }
}
