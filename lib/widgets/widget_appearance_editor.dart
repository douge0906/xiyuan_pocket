import 'package:flutter/material.dart';

import '../services/widget_prefs.dart';
import '../theme/app_theme.dart';
import 'settings_rows.dart';

/// 「组件外观」编辑块（2026-11-05，用户 m24495 #1）。
///
/// 需求原文：「卡片都应该有调节字号 主题色 浅色深色的能力」。
///
/// 设计约束：
///  · **每种组件一套**（schedule / exam / card / countdown），不再共用全局。
///  · 用户明确选了「设置入口分散到各自页面」，所以这里只提供一块可复用的
///    UI，由课表设置页 / 考试查询页 / 卡片详情页 / 倒数日页各自内嵌。
///  · 改完立即写盘并触发一次该组件的重渲染（不 await，用户看到的是即时反馈）。
///  · 提供「跟随全局」复位：清掉 per-kind 键即可，老行为一键回来。
class WidgetAppearanceEditor extends StatefulWidget {
  const WidgetAppearanceEditor({
    super.key,
    required this.kind,
    required this.title,
    required this.onSync,
  });

  /// `schedule` / `exam` / `card` / `countdown`（见 [WidgetPrefs.appearanceKinds]）。
  final String kind;

  /// 分组标题，例如「课表组件外观」。
  final String title;

  /// 改完后的同步动作（通常是对应的 `WidgetSyncService.syncXxxWidget`）。
  final Future<void> Function() onSync;

  @override
  State<WidgetAppearanceEditor> createState() => _WidgetAppearanceEditorState();
}

class _WidgetAppearanceEditorState extends State<WidgetAppearanceEditor> {
  String _theme = WidgetPrefs.defTheme;
  String _accent = WidgetPrefs.defAccent;
  double _fontScale = WidgetPrefs.defFontScale;
  bool _custom = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final kind = widget.kind;
    final theme = await WidgetPrefs.themeFor(kind);
    final accent = await WidgetPrefs.accentFor(kind);
    final scale = await WidgetPrefs.fontScaleFor(kind);
    final custom = await WidgetPrefs.hasCustomAppearance(kind);
    if (!mounted) return;
    setState(() {
      _theme = theme;
      _accent = accent;
      _fontScale = scale;
      _custom = custom;
      _loaded = true;
    });
  }

  Future<void> _apply(Future<void> Function() write) async {
    await write();
    if (!mounted) return;
    setState(() => _custom = true);
    // 不 await：设置页要的是即时反馈，组件晚一点重绘无所谓。
    // ignore: discarded_futures
    widget.onSync();
  }

  String get _themeLabel => switch (_theme) {
        'light' => '浅色',
        'dark' => '深色',
        _ => '跟随系统',
      };

  String get _scaleLabel => '${(_fontScale * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionLabel(widget.title),
        SettingsCard(children: [
          // 浅色 / 深色
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Text('配色',
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        color: context.textPrimary)),
                const Spacer(),
                _seg('跟随系统', 'system'),
                _seg('浅色', 'light'),
                _seg('深色', 'dark'),
              ],
            ),
          ),
          // 2026-11-05（用户 m24837）：字号改成通用设置页那种 +/− 步进器，
          // 不再用连续滑杆 —— 用户在设置里能一眼看懂「100%」是什么档位。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Text('字号',
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        color: context.textPrimary)),
                const Spacer(),
                _stepper(),
              ],
            ),
          ),
          // 主题色
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Row(
              children: [
                Text('主题色',
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        color: context.textPrimary)),
                const Spacer(),
                for (final hex in WidgetPrefs.accentChoices) _swatch(hex),
              ],
            ),
          ),
          // 跟随全局复位（只在自定义过才显示，避免第一屏多一行没用的东西）
          if (_custom)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () async {
                  await WidgetPrefs.clearAppearanceFor(widget.kind);
                  await _load();
                  // ignore: discarded_futures
                  widget.onSync();
                },
                child: Text('恢复跟随全局',
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall,
                        color: context.textTertiary)),
              ),
            )
          else
            const SizedBox(height: 6),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
          child: Text(
            _custom
                ? '当前：$_themeLabel · $_scaleLabel · 仅作用于这个组件'
                : '跟随全局外观（改任意一项即单独生效）',
            style: TextStyle(
                fontSize: AppTheme.fontCaption, color: context.textTertiary),
          ),
        ),
      ],
    );
  }

  /// 通用设置页同款 +/− 步进器。每档 = 10%，范围 80%..120%。
  /// 点一次就落盘并触发重渲染 —— 与通用设置页「点完立即生效」的体验一致。
  Widget _stepper() {
    final pct = (_fontScale * 100).round();
    return Row(
      children: [
        Text('$pct%',
            style: TextStyle(
                fontSize: AppTheme.fontSmall, color: context.textTertiary)),
        const SizedBox(width: 8),
        InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          onTap: pct <= 80
              ? null
              : () {
                  final v = (pct - 10) / 100.0;
                  setState(() => _fontScale = v);
                  _apply(() => WidgetPrefs.setFontScaleFor(widget.kind, v));
                },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: context.borderColor),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            ),
            child: Icon(Icons.remove_rounded,
                size: 16, color: pct <= 80 ? context.textTertiary : context.textPrimary),
          ),
        ),
        const SizedBox(width: 6),
        InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          onTap: pct >= 120
              ? null
              : () {
                  final v = (pct + 10) / 100.0;
                  setState(() => _fontScale = v);
                  _apply(() => WidgetPrefs.setFontScaleFor(widget.kind, v));
                },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: context.borderColor),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            ),
            child: Icon(Icons.add_rounded,
                size: 16, color: pct >= 120 ? context.textTertiary : context.textPrimary),
          ),
        ),
      ],
    );
  }

  Widget _seg(String label, String value) {
    final on = _theme == value;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        onTap: () {
          setState(() => _theme = value);
          _apply(() => WidgetPrefs.setThemeFor(widget.kind, value));
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: on ? AppTheme.primaryColor : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            border: Border.all(
              color: on ? AppTheme.primaryColor : context.borderColor,
            ),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: AppTheme.fontSmall,
                color: on ? Colors.white : context.textSecondary,
              )),
        ),
      ),
    );
  }

  Widget _swatch(String hex) {
    final on = _accent.toUpperCase() == hex.toUpperCase();
    final color = Color(0xFF000000 | int.parse(hex, radix: 16));
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          setState(() => _accent = hex);
          _apply(() => WidgetPrefs.setAccentFor(widget.kind, hex));
        },
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: on ? context.textPrimary : Colors.transparent,
              width: 2,
            ),
          ),
          child: on
              ? const Icon(Icons.check, size: 14, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}
