part of 'course_table_home_page.dart';

/// 初次进课表的背景色引导（只弹一次）。
///
/// 设计取向：一屏解决「好看」这一件事 —— 挑个色、决定要不要网格、然后走人。
/// 不铺全套设置（那是设置页的活），所以第三行只留一句指路。
class _CourseWelcomeSheet extends StatefulWidget {
  const _CourseWelcomeSheet({
    required this.onPickColor,
    required this.onToggleGrid,
  });

  final void Function(int argb, bool gradient) onPickColor;
  final ValueChanged<bool> onToggleGrid;

  @override
  State<_CourseWelcomeSheet> createState() => _CourseWelcomeSheetState();
}

class _CourseWelcomeSheetState extends State<_CourseWelcomeSheet> {
  /// 弹层底色写死纯白（色球是浅色系，深色底上很难看），
  /// 所以文字也必须用固定深色常量 —— 用 context.textPrimary 的话
  /// 深色模式下它就是白色，白底白字（v1.0.9 修正）。
  static const Color _ink = Color(0xFF1F1F1F);
  static const Color _sub = Color(0xFF9CA3AF);

  /// 第一个是推荐蓝（配 100% 渐变最好看）。
  static const _presets = <(int, String)>[
    (0xFFE8F1FB, '推荐蓝'),
    (0xFFEFF6EE, '浅绿'),
    (0xFFFDF3F0, '浅杏'),
    (0xFFF6F0FA, '淡紫'),
    (0xFFFBF7EC, '米黄'),
    (0xFFF2F2F4, '中性灰'),
  ];

  int? _picked;
  bool _grid = true;

  @override
  void initState() {
    super.initState();
    // 初始状态跟随当前设置，避免用户以为"默认没网格"
    _grid = CourseStorage.showGridLinesCache;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题行 + 右上角 ×（UI 死律：居中 Dialog 必须可关）
        Row(
          children: [
            Expanded(
              child: Text('初次使用，换一个喜欢的背景色吧！',
                  style: TextStyle(
                      fontSize: AppTheme.fontTitle,
                      fontWeight: FontWeight.w600,
                      color: _ink)),
            ),
            IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded,
                  size: 20, color: _sub),
              tooltip: '关闭',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 8),

            // 一排颜色球
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final p in _presets)
                  GestureDetector(
                    onTap: () {
                      setState(() => _picked = p.$1);
                      widget.onPickColor(p.$1, true);
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: Color(p.$1),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _picked == p.$1
                                  ? AppTheme.primaryColor
                                  : context.borderColor,
                              width: _picked == p.$1 ? 2 : 1,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(p.$2,
                            style: TextStyle(
                                fontSize: 9.5, color: _sub)),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),

            // 网格开关
            Row(
              children: [
                Text('加入网格',
                    style: TextStyle(fontSize: AppTheme.fontBody, color: _ink)),
                const Spacer(),
                Checkbox(
                  value: _grid,
                  visualDensity: VisualDensity.compact,
                  onChanged: (v) {
                    setState(() => _grid = v ?? false);
                    widget.onToggleGrid(_grid);
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),

        Text('更多个性化设置，请前往设置页查看。',
            style: TextStyle(fontSize: AppTheme.fontSmall, color: _sub)),
      ],
    );
  }
}

