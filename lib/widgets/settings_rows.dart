import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_card.dart';

/// 设置类页面共用的行组件（v1.0.9 收口）。
///
/// 为什么单独抽出来：设置页 / 通用设置页 / 外观与个性化页以前各写一套
/// 「一行 = 图标 + 标题 + 右侧值 + ›」的代码，三份实现渐渐跑偏（左边距
/// 16 / 14 / 20 都有，右侧值字号 12 / 13 都有）。这里定成唯一真源，
/// 三个页面都用同一份，改一次全站一起变。

/// 分组标题（只留一行小字，不带任何说明）。
class SettingsSectionLabel extends StatelessWidget {
  const SettingsSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 20, 6, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppTheme.fontSmall,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
          color: context.textTertiary,
        ),
      ),
    );
  }
}

/// 设置卡片外壳：一行一行的纵向列表，靠外层圆角阴影与页面区分。
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      radius: AppTheme.radiusLg,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// 卡片内分隔线：第一行之前不加。
List<Widget> settingsWithDividers(BuildContext context, List<Widget> rows) {
  final out = <Widget>[];
  for (var i = 0; i < rows.length; i++) {
    if (i > 0) out.add(Divider(height: 1, color: context.borderColor));
    out.add(rows[i]);
  }
  return out;
}

/// 跳转型一行：图标 + 标题 + 右侧当前值 + ›。
///
/// [value] 是右侧状态文案（「已开启」「12.3 MB」「v1.0.9」）。
/// 不写灰色小字说明 —— 说明堆多了就是满屏噪音，而「右侧直接给当前值」
/// 才是用户真正想知道的。
class SettingsEntryRow extends StatelessWidget {
  const SettingsEntryRow({
    super.key,
    required this.icon,
    required this.title,
    this.value,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Icon(icon, size: 20, color: AppTheme.primaryColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                      fontSize: AppTheme.fontBody, color: context.textPrimary),
                ),
              ),
              if (value != null && value!.isNotEmpty)
                Text(value!,
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall,
                        color: context.textTertiary)),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 20, color: context.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

/// 就地操作一行：左边图标 + 标题，右边直接放控件（步进器 / 循环按钮）。
///
/// 和 [SettingsEntryRow] 的区别：没有 chevron、不跳转，右侧是能立刻改的控件。
class SettingsInlineRow extends StatelessWidget {
  const SettingsInlineRow({
    super.key,
    required this.icon,
    required this.title,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppTheme.primaryColor),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                    fontSize: AppTheme.fontBody, color: context.textPrimary),
              ),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    );
  }
}

/// 一个候选项。
class InlineSelectOption {
  const InlineSelectOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
}

/// 就地下拉选择器（v1.0.9 交互纠正的核心组件）。
///
/// 用户原话：「点最右侧的当前值，直接向下延伸出一个选择框」。
/// 所以这里刻意**不是**弹窗、**不是** Wrap 换行胶囊：
///
///  · 触发热区 = **整行**（图标 + 标题 + 当前值 + 箭头），不是只有那几个字；
///  · 展开体缩进 48，竖直列表，每项高 44，左文案右勾选；
///  · 选中一项立即收起（不用再点一次行）；
///  · 同时只允许一个展开 —— 由调用方用单值枚举控制，开新的自动收旧的。
class InlineSelect extends StatelessWidget {
  const InlineSelect({
    super.key,
    required this.icon,
    required this.title,
    required this.currentLabel,
    required this.open,
    required this.onToggle,
    required this.options,
  });

  final IconData icon;
  final String title;
  final String currentLabel;
  final bool open;
  final VoidCallback onToggle;
  final List<InlineSelectOption> options;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onToggle,
          child: SettingsInlineRow(
            icon: icon,
            title: title,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(currentLabel,
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall,
                        color: context.textTertiary)),
                const SizedBox(width: 2),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: AppTheme.durBase,
                  child: Icon(Icons.keyboard_arrow_down_rounded,
                      size: 22, color: context.textTertiary),
                ),
              ],
            ),
          ),
        ),
        // ClipRect + AnimatedSize 做展开收起的尺寸过渡。
        // 收起态必须留 `SizedBox(width: double.infinity)` 撑宽 ——
        // 换成 `SizedBox(height: 0)` 会让外层 Column 的宽度塌缩。
        AnimatedSize(
          duration: AppTheme.durBase,
          curve: AppTheme.curveStandard,
          alignment: Alignment.topCenter,
          child: open
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(48, 0, 8, 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final o in options) _SelectItem(option: o),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

class _SelectItem extends StatelessWidget {
  const _SelectItem({required this.option});

  final InlineSelectOption option;

  @override
  Widget build(BuildContext context) {
    final selected = option.selected;
    return InkWell(
      onTap: option.onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  option.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected
                        ? AppTheme.primaryColor
                        : context.textPrimary,
                  ),
                ),
              ),
              if (selected)
                Icon(Icons.check_rounded,
                    size: 18, color: AppTheme.primaryColor),
            ],
          ),
        ),
      ),
    );
  }
}

/// 字号 `-_18_+` 步进器。
///
/// 为什么不用滑杆：18 号是标准锚点，用户心里想的是「比现在大两号」，
/// 不是「0.87 倍」。步进器每点一下 +1 号，落点是整数，说得清也记得住。
class SettingsStepper extends StatelessWidget {
  const SettingsStepper({
    super.key,
    required this.value,
    required this.onChanged,
    // v1.0.9：默认值原来是 14/24，但 `UiPrefs.setFontSizeNumber` 会把
    // 字号夹到 textScale 的 [0.85, 1.30] → 实际可达范围是 **15..23**。
    // 于是显示 15 时按「−」永远没反应、显示 23 时按「+」永远没反应，
    // 按钮却是高亮的 —— 用户会觉得「按钮坏了」。
    this.min = 15,
    this.max = 23,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final int max;

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, bool enabled, VoidCallback onTap) {
      return InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon,
              size: 20,
              color: enabled ? AppTheme.primaryColor : context.textTertiary),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn(Icons.remove_rounded, value > min, () => onChanged(value - 1)),
        SizedBox(
          width: 34,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTheme.fontBody,
              fontWeight: FontWeight.w600,
              color: context.textPrimary,
            ),
          ),
        ),
        btn(Icons.add_rounded, value < max, () => onChanged(value + 1)),
      ],
    );
  }
}

/// 单按钮循环档（振动强度用）。
///
/// 用户原话：「最右侧只保留一个按钮，点击直接切下一个档位」。
/// 四档循环：关闭 → 轻 → 强 → 极强 → 关闭。
class SettingsCycleChip extends StatelessWidget {
  const SettingsCycleChip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;

  /// 档位 > 0 时用主色描边，为 0（关闭）时用普通边框 ——
  /// 一眼能看出现在是「开着」还是「关了」。
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: active
                ? AppTheme.primaryColor.withValues(alpha: 0.12)
                : context.surfaceColor,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            border: Border.all(
              color: active ? AppTheme.primaryColor : context.borderColor,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: AppTheme.fontSmall,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: active ? AppTheme.primaryColor : context.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
