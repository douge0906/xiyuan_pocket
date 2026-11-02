import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 课表背景色选择器：8 个预设 + 色相 / 饱和度 / 透明度三条滑杆。
///
/// 为什么不是「只有明度滑杆」：明度只改深浅，色相和饱和度不动，
/// 调出来就是一片灰蒙蒙的脏色（用户原话「很丑很恶心」）。这里给完整 HSV，
/// 并单独给**透明度** —— 背景色要能透出底下的网格和课块。
class CourseBgColorPicker extends StatefulWidget {
  const CourseBgColorPicker({
    super.key,
    required this.initial,
    required this.onChanged,
    this.gradient = false,
    this.onGradientChanged,
    this.gradientStrength = 0.78,
    this.onGradientStrengthChanged,
  });

  /// 当前颜色（ARGB），null = 未设置。
  final int? initial;

  final ValueChanged<int> onChanged;

  /// 背景色是否走同色系渐变（上浅下深）。
  final bool gradient;
  final ValueChanged<bool>? onGradientChanged;

  /// 渐变强度（0~1）：上沿混多少白。
  final double gradientStrength;
  final ValueChanged<double>? onGradientStrengthChanged;

  @override
  State<CourseBgColorPicker> createState() => _CourseBgColorPickerState();
}

class _CourseBgColorPickerState extends State<CourseBgColorPicker> {
  late HSVColor _hsv;
  late double _alpha;

  /// 预设：都是低饱和的浅色，配深色文字不刺眼。
  static const _presets = <int>[
    0xFFEAF2FB, // 雾蓝
    0xFFEFF6EE, // 浅绿
    0xFFFDF3F0, // 浅杏
    0xFFF6F0FA, // 淡紫
    0xFFF0F7F8, // 青白
    0xFFFBF7EC, // 米黄
    0xFFF2F2F4, // 中性灰
    0xFFFFF9E9, // 暖白
  ];

  @override
  void initState() {
    super.initState();
    final c = Color(widget.initial ?? 0xFFF5F7FA);
    _hsv = HSVColor.fromColor(c).withSaturation(
      HSVColor.fromColor(c).saturation.clamp(0.0, 0.6),
    );
    _alpha = widget.initial == null ? 0.85 : c.a;
  }

  void _emit() {
    final c = _hsv.withAlpha(_alpha).toColor();
    widget.onChanged(c.toARGB32());
  }

  @override
  Widget build(BuildContext context) {
    final cur = _hsv.withAlpha(_alpha).toColor();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 预设
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final p in _presets)
              _swatch(Color(p), cur.toARGB32() == p, () {
                setState(() {
                  final h = HSVColor.fromColor(Color(p));
                  _hsv = h;
                  _alpha = 1.0;
                });
                _emit();
              }),
            // 自定义（当前值）
            _swatch(cur,
                !_presets.contains(cur.toARGB32()), () {}, dashed: true),
          ],
        ),
        const SizedBox(height: 16),

        // 色相
        _label(context, '色相', '${_hsv.hue.round()}°'),
        const SizedBox(height: 6),
        _GradientBar(
          gradient: const LinearGradient(colors: [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ]),
          value: _hsv.hue / 360,
          thumbColor: cur,
          onChanged: (v) {
            setState(() => _hsv = _hsv.withHue(v * 360));
            _emit();
          },
        ),
        const SizedBox(height: 12),

        // 饱和度
        _label(context, '饱和度', '${(_hsv.saturation * 100).round()}%'),
        const SizedBox(height: 6),
        _GradientBar(
          gradient: LinearGradient(colors: [
            HSVColor.fromAHSV(1, _hsv.hue, 0, 1).toColor(),
            HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(),
          ]),
          value: _hsv.saturation,
          thumbColor: cur,
          onChanged: (v) {
            setState(() => _hsv = _hsv.withSaturation(v));
            _emit();
          },
        ),
        const SizedBox(height: 12),

        // 透明度
        _label(context, '不透明度', '${(_alpha * 100).round()}%'),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: SliderComponentShape.noOverlay,
          ),
          child: Slider(
            value: _alpha,
            min: 0.1,
            max: 1.0,
            // 用**不透明**版本做轨道色：半透明时拉到 10% 轨道几乎看不见，
            // 看起来就像「没有这个滑杆」（2026-10-26 反馈）
            activeColor: _hsv.withAlpha(1.0).toColor(),
            inactiveColor: context.borderColor,
            onChanged: (v) {
              setState(() => _alpha = v);
              _emit();
            },
          ),
        ),

        // 渐变：同一色相，上沿发白、往下逐渐饱和
        Row(
          children: [
            Text('渐变（上浅下深）',
                style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textSecondary)),
            const Spacer(),
            Switch.adaptive(
              value: widget.gradient,
              onChanged: widget.onGradientChanged,
            ),
          ],
        ),
        // 渐变强度：开关打开时才给滑杆
        if (widget.gradient) ...[
          Row(
            children: [
              Text('渐变强度',
                  style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textSecondary)),
              const Spacer(),
              Text('${(widget.gradientStrength * 100).round()}%',
                  style:
                      TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              value: widget.gradientStrength.clamp(0.0, 1.0),
              min: 0,
              max: 1,
              activeColor: _hsv.withAlpha(1.0).toColor(),
              inactiveColor: context.borderColor,
              onChanged: widget.onGradientStrengthChanged,
            ),
          ),
        ],
      ],
    );
  }

  Widget _label(BuildContext context, String a, String b) => Row(
        children: [
          Text(a,
              style:
                  TextStyle(fontSize: AppTheme.fontSmall, color: context.textSecondary)),
          const Spacer(),
          Text(b,
              style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary)),
        ],
      );

  Widget _swatch(Color c, bool selected, VoidCallback onTap,
      {bool dashed = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? AppTheme.primaryColor : context.borderColor,
            width: selected ? 2 : 1,
          ),
        ),
        child: dashed
            ? Icon(Icons.add, size: 14, color: context.textTertiary)
            : null,
      ),
    );
  }
}

/// 可拖动的渐变取色条（色相 / 饱和度共用）。
class _GradientBar extends StatelessWidget {
  const _GradientBar({
    required this.gradient,
    required this.value,
    required this.thumbColor,
    required this.onChanged,
  });

  final Gradient gradient;
  final double value; // 0~1
  final Color thumbColor;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        void handle(Offset p) => onChanged((p.dx / w).clamp(0.0, 1.0));
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) => handle(d.localPosition),
          onHorizontalDragUpdate: (d) => handle(d.localPosition),
          onTapDown: (d) => handle(d.localPosition),
          child: SizedBox(
            height: 26,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 10,
                  decoration: BoxDecoration(
                    gradient: gradient,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: context.borderColor),
                  ),
                ),
                Positioned(
                  left: (w - 16) * value,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: thumbColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: const [
                        BoxShadow(
                            color: Color(0x22000000),
                            blurRadius: 3,
                            offset: Offset(0, 1)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
