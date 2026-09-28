import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 设置页：外观（明暗模式 + 主题色）+ 账户。
///
/// 上课提醒设置已迁移至：课表页顶部 → 提醒按钮（v2.3.0）。
///
/// v1.9.1 两个修复：
///  · 改为 StatefulWidget —— 原为 StatelessWidget，`themeMode` 是构造时传入的快照，
///    点击切换后**本页实例的 themeMode 不会更新**，导致「对勾停在上一个选项」。
///    现在本地维护一份状态，点击立即更新勾选，再回调父级持久化。
///  · 勾选位改为**固定宽度**占位 —— 无勾选时不再是 null，避免标题因 trailing
///    宽度变化而左右跳动。
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

  @override
  void initState() {
    super.initState();
    _mode = widget.themeMode;
  }

  Future<void> _pickMode(ThemeMode m) async {
    if (_mode == m) return;
    setState(() => _mode = m);      // 立刻反映勾选，不等父级回调
    await widget.onThemeChanged(m);
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出账户',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: const Text('确定要退出当前账户吗？\n退出后云端账号将不再与本机绑定。',
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
    final titleColor = context.textPrimary;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('设置',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        children: [
          _sectionTitle(isDark, '外观'),
          _card(
            isDark,
            children: [
              _modeOption(titleColor, '浅色', ThemeMode.light),
              const Divider(height: 1),
              _modeOption(titleColor, '深色', ThemeMode.dark),
              const Divider(height: 1),
              _primaryEntry(isDark, titleColor),
            ],
          ),
          const SizedBox(height: 16),
          _sectionTitle(isDark, '账户'),
          _card(
            isDark,
            children: [
              ListTile(
                onTap: _confirmLogout,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.logout_rounded, color: Color(0xFFE24B4A)),
                title: Text('退出账户', style: TextStyle(fontSize: 14, color: titleColor)),
                trailing: const Icon(Icons.chevron_right, color: Color(0xFF9CA3AF)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '上课提醒请到：课表页右上角 · 铃铛按钮',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  /// 明暗模式选项。勾选位固定 24px 宽，避免标题左右跳动。
  Widget _modeOption(Color titleColor, String label, ThemeMode mode) {
    final selected = _mode == mode;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: () => _pickMode(mode),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          color: titleColor,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      trailing: SizedBox(
        width: 24,
        child: selected
            ? Icon(Icons.check_rounded, color: AppTheme.primaryColor, size: 20)
            : null,
      ),
    );
  }

  /// 「主题色 · 实验性」入口：右侧色点预览。
  Widget _primaryEntry(bool isDark, Color titleColor) {
    return ValueListenableBuilder<Color>(
      valueListenable: widget.primaryColor,
      builder: (ctx, current, __) => ListTile(
        contentPadding: EdgeInsets.zero,
        onTap: () => _pickPrimaryColor(current),
        title: Row(
          children: [
            Text('主题色', style: TextStyle(fontSize: 14, color: titleColor)),
            const SizedBox(width: 6),
            // 「实验性」标记：预先告知可能有个别页面未完全适配，
            // 避免用户以为是 bug（诚实标注好过让用户猜）。
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: AppTheme.warning.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('实验性',
                  style: TextStyle(fontSize: 10, color: Color(0xFFB45309))),
            ),
          ],
        ),
        trailing: SizedBox(
          width: 24,
          child: Center(
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: current,
                shape: BoxShape.circle,
                border: Border.all(
                    color: isDark ? Colors.grey.shade700 : Colors.grey.shade300),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickPrimaryColor(Color current) async {
    final picked = await showModalBottomSheet<Color>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final dark = Theme.of(ctx).brightness == Brightness.dark;
        return Container(
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF1E1E1E) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(AppTheme.radiusLg)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text('主题色',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: context.textPrimary)),
              const SizedBox(height: 4),
              Text('影响按钮、选中态与强调色；个别页面适配中，若发现异常请反馈',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              const SizedBox(height: 18),
              // 固定列宽（每行 4 个），避免 Wrap 因数量/宽度不同导致对齐不齐
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: AppTheme.primaryPresets.take(4).map((e) {
                  return _swatch(ctx, e.$1, e.$2, current);
                }).toList(),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: AppTheme.primaryPresets.skip(4).map((e) {
                  return _swatch(ctx, e.$1, e.$2, current);
                }).toList(),
              ),
            ],
          ),
        );
      },
    );
    if (picked != null) await widget.onPrimaryChanged(picked);
  }

  /// 单个色点。选中时**外圈加环 + 内嵌对勾**，不改变色块尺寸
  /// （避免选中/未选中尺寸不同造成的错位感）。
  Widget _swatch(BuildContext ctx, String label, Color color, Color current) {
    final dark = Theme.of(ctx).brightness == Brightness.dark;
    final selected = color.value == current.value;
    return GestureDetector(
      onTap: () => Navigator.of(ctx).pop(color),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 62,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? color : Colors.transparent,
                  width: 0, // 尺寸稳定：选中效果用外环而非改尺寸
                ),
              ),
              child: Center(
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: selected
                        ? Border.all(
                            color: context.textPrimary,
                            width: 2)
                        : null,
                  ),
                  child: selected
                      ? const Icon(Icons.check_rounded, color: Colors.white, size: 20)
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                color: dark ? Colors.grey.shade400 : Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(bool isDark, String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.grey.shade500 : Colors.grey.shade500,
          ),
        ),
      );

  Widget _card(bool isDark, {required List<Widget> children}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          boxShadow: AppTheme.cardShadow,
        ),
        child: Column(children: children),
      );
}