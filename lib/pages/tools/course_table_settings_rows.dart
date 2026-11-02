part of 'course_table_settings_page.dart';

/// 「课表设置」页的行级 UI 构建（2026-11-02 C2 拆分）。
///
/// 这些是纯展示控件：只读 State 的字段、调回调，不持有自己的状态。
/// 用 extension 而不是挪到别的类，是为了让私有成员继续可见、调用点一行不改。
extension _CourseTableSettingsRows on _CourseTableSettingsPageState {
  /// 开关行：**单行**（左图标 + 标题 + 右侧开关）。
  /// [enabled] 为 false 时置灰不可点（例如「显示网格线」关着时的粗细滑杆）。
  /// 入口行（v1.6.0，恢复已忽略的冲突课程）：图标 + 标题 + 右侧值。
  Widget _entryTile({
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
  }) {
    return ListTile(
      onTap: onTap,
      dense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(icon, size: 20, color: context.textTertiary),
      title: Text(title,
          style: TextStyle(
              fontSize: AppTheme.fontBody,
              fontWeight: FontWeight.w500,
              color: context.textPrimary)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style:
                  TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right_rounded,
              size: 18, color: context.textTertiary),
        ],
      ),
    );
  }

  /// 把忽略名单的签名还原成可读文案：课名（教师）· 周X 第a-b节。
  String _droppedLabel(String key) {
    final p = key.split('|');
    if (p.length < 6) return key;
    final wd = switch (int.tryParse(p[2]) ?? 1) {
      0 => '每天',
      -1 => '工作日',
      final w => '周$w',
    };
    final teacher = p[1].isEmpty ? '' : '（${p[1]}）';
    return '${p[0]}$teacher · $wd 第${p[3]}-${p[4]}节';
  }

  /// 色彩方案行（v1.6.9；2026-10-16 起升级为「整套外观方案」）：
  /// 一排三个色卡，点了**立即套用该方案的配色 + 外观预设**（圆角 / 课节 / 边框等）。
  ///
  /// 色卡里的小圆点用**同一批示例色**在该方案下的实际颜色 ——
  /// 三套方案并排一眼能比出区别（用户要求：不要只给文字档位名字）。
  Widget _schemeTile() {
    final cur = CourseColorScheme.parse(_display['scheme']);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.palette_outlined,
                  size: 20, color: AppTheme.primaryColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text('色彩方案',
                    style:
                        TextStyle(fontSize: AppTheme.fontBody, color: context.textPrimary)),
              ),
              Text(cur.label,
                  style: TextStyle(
                    fontSize: AppTheme.fontSmall,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primaryColor,
                  )),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final s in CourseColorScheme.values) ...[
                Expanded(child: _schemeChip(s, cur)),
                if (s != CourseColorScheme.values.last) const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _cardOrderTile() {
    final labels = <String, String>{
      'name': '课程名',
      'teacher': '任课老师',
      'classroom': '教室',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.reorder_rounded,
                  size: 20, color: AppTheme.primaryColor),
              const SizedBox(width: 12),
              Text('内容顺序',
                  style: TextStyle(
                      fontSize: AppTheme.fontBody, color: context.textPrimary)),
              const Spacer(),
              Text('拖动排序',
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption, color: context.textTertiary)),
            ],
          ),
          const SizedBox(height: 6),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: _cardOrder.length,
            onReorder: (oldIndex, newIndex) {
              final list = [..._cardOrder];
              if (newIndex > oldIndex) newIndex--;
              final item = list.removeAt(oldIndex);
              list.insert(newIndex, item);
              _set('cardFieldOrder', list);
            },
            itemBuilder: (context, index) {
              final key = _cardOrder[index];
              return Container(
                key: ValueKey(key),
                height: 40,
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: context.surfaceColor,
                  borderRadius: AppTheme.radiusSmAll,
                  border: Border.all(color: context.borderColor),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(labels[key] ?? key,
                          style: const TextStyle(fontSize: AppTheme.fontSmall)),
                    ),
                    ReorderableDragStartListener(
                      index: index,
                      child: Icon(Icons.drag_indicator_rounded,
                          size: 18, color: context.textTertiary),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _switchTile({
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) =>
      SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
            children: [
              Icon(icon,
                  size: 20,
                  color: enabled
                      ? AppTheme.primaryColor
                      : context.textTertiary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        color: enabled
                            ? context.textPrimary
                            : context.textTertiary)),
              ),
              Transform.scale(
                scale: 0.8,
                child: Switch(
                  value: value,
                  onChanged: enabled ? onChanged : null,
                  activeColor: Colors.white,
                  activeTrackColor: AppTheme.primaryColor,
                ),
              ),
            ],
          ),
        ),
      );

  /// 滑杆行（v1.3.0）：标题 + 当前值一行，滑杆一行。
  ///
  /// [onChanged] 拖动中回调（实时预览），[onChangeEnd] 松手回调（存盘）。
  /// [enabled] 为 false 时置灰不可拖（例如「显示网格线」关着时的粗细 / 深浅）。
  Widget _sliderTile({
    required IconData icon,
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
    required Future<void> Function() onChangeEnd,
    bool enabled = true,
  }) {
    final v = value.clamp(min, max).toDouble();
    // v1.4.0 紧凑化（用户要求）：行内边距收紧 + 滑杆区压到 32 高（原 48），
    // 单条约 80px → 58px，一屏能多看到两三条。
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
      child: Column(
        children: [
          Row(
            children: [
              Icon(icon,
                  size: 20,
                  color: enabled
                      ? AppTheme.primaryColor
                      : context.textTertiary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        color: enabled
                            ? context.textPrimary
                            : context.textTertiary)),
              ),
              Text(
                format(v),
                style: TextStyle(
                  fontSize: AppTheme.fontSmall,
                  fontWeight: FontWeight.w600,
                  color: enabled
                      ? AppTheme.primaryColor
                      : context.textTertiary,
                ),
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
                disabledActiveTrackColor:
                    AppTheme.primaryColor.withValues(alpha: 0.3),
                disabledInactiveTrackColor:
                    context.borderColor.withValues(alpha: 0.7),
                thumbColor: AppTheme.primaryColor,
                disabledThumbColor: AppTheme.primaryColor.withValues(alpha: 0.3),
                overlayColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7, disabledThumbRadius: 7, elevation: 0),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
              ),
              child: Slider(
                value: v,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: enabled ? onChanged : null,
                onChangeEnd: enabled ? (_) => onChangeEnd() : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 操作行：单行（左图标 + 标题 + 右箭头）。
  Widget _actionTile({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    bool danger = false,
  }) =>
      SizedBox(
        height: 48,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(icon,
                    size: 20,
                    color: danger ? AppTheme.danger : AppTheme.primaryColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(title,
                      style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        color: danger ? AppTheme.danger : context.textPrimary,
                      )),
                ),
                Icon(Icons.chevron_right, color: context.textTertiary),
              ],
            ),
          ),
        ),
      );

}
