import 'package:flutter/material.dart';

import '../services/app_locale.dart';
import '../services/haptics.dart';
import '../services/storage_service.dart';
import '../services/ui_prefs.dart';
import '../theme/app_theme.dart';
import '../widgets/settings_rows.dart';

/// 通用设置（子页，v1.0.9 新增）。
///
/// 用户口径：「通用设置是一个总入口，内部有字体字号等设置项，不是平铺开关」。
/// 第二次口径：「语言没有放到通用设置里」→ 语言从设置首屏搬进来，
/// 与字体、字号、振动强度放在同一张卡里，都是「全局生效的偏好」。
///
/// 四项：
///
///  · 字体（就地下拉）
///  · 字号（`-_18_+` 步进器）
///  · 语言（就地下拉）
///  · 振动强度（单按钮循环档，每切一档立刻试震）
class GeneralSettingsPage extends StatefulWidget {
  const GeneralSettingsPage({super.key});

  @override
  State<GeneralSettingsPage> createState() => _GeneralSettingsPageState();
}

class _GeneralSettingsPageState extends State<GeneralSettingsPage> {
  /// 当前展开的选择器（null = 全收起）。
  ///
  /// 🔴 用单值而不是多个 bool：用户明确要求「同时只允许一个下拉展开」，
  /// 多个 bool 需要每次手动互斥，漏一处就会出现两个同时展开。
  _Selector? _open;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: Text(S.t('set_general'),
            style: const TextStyle(
                fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            MediaQuery.of(context).padding.bottom + 24,
          ),
          children: [
            const SettingsSectionLabel('显示与触感'),
            SettingsCard(
              children: settingsWithDividers(context, [
                InlineSelect(
                  icon: Icons.font_download_outlined,
                  title: S.t('set_font'),
                  currentLabel: _fontLabel,
                  open: _open == _Selector.font,
                  onToggle: () => setState(() {
                    _open = _open == _Selector.font ? null : _Selector.font;
                  }),
                  options: [
                    for (final f in UiPrefs.fontChoices)
                      InlineSelectOption(
                        label: f.$2,
                        selected: UiPrefs.fontFamily == f.$1,
                        onTap: () => _setFontFamily(f.$1),
                      ),
                  ],
                ),
                SettingsInlineRow(
                  icon: Icons.format_size_rounded,
                  title: S.t('set_font_size'),
                  trailing: SettingsStepper(
                    value: UiPrefs.fontSizeNumber,
                    onChanged: _setFontSize,
                  ),
                ),
                InlineSelect(
                  icon: Icons.language_rounded,
                  title: S.t('set_language'),
                  currentLabel: AppLocale.current.label,
                  open: _open == _Selector.language,
                  onToggle: () => setState(() {
                    _open =
                        _open == _Selector.language ? null : _Selector.language;
                  }),
                  options: [
                    for (final l in AppLanguage.values)
                      InlineSelectOption(
                        label: l.label,
                        selected: AppLocale.current == l,
                        onTap: () => _setLanguage(l),
                      ),
                  ],
                ),
                SettingsInlineRow(
                  icon: Icons.vibration_rounded,
                  title: S.t('set_haptic'),
                  trailing: SettingsCycleChip(
                    label: UiPrefs.hapticLabel,
                    active: UiPrefs.hapticLevel > 0,
                    onTap: _cycleHaptic,
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  String get _fontLabel {
    for (final f in UiPrefs.fontChoices) {
      if (f.$1 == UiPrefs.fontFamily) return f.$2;
    }
    return '系统默认';
  }

  Future<void> _setFontFamily(String family) async {
    setState(() {
      UiPrefs.setFontFamily(family);
      _open = null; // 选中即收
    });
    await StorageService.saveUiFontFamily(family);
  }

  Future<void> _setFontSize(int size) async {
    setState(() => UiPrefs.setFontSizeNumber(size));
    await StorageService.saveUiTextScale(UiPrefs.textScale);
  }

  Future<void> _setLanguage(AppLanguage lang) async {
    setState(() => _open = null); // 选中即收
    await AppLocale.setLanguage(lang);
    if (!mounted) return;
    setState(() {});
  }

  /// 点一下切下一档，并立刻用新档位震一次（试震）。
  ///
  /// 为什么切到「关闭」时不震：那一档的语义就是「不要震」，
  /// 再震一下等于自己打自己脸。
  Future<void> _cycleHaptic() async {
    final level = UiPrefs.cycleHapticLevel();
    setState(() {});
    if (level > 0) Haptics.fire(level);
    await StorageService.saveUiHapticLevel(level);
  }
}

enum _Selector { font, language }
