import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppTheme {
  /// 默认主题色（墨黑）。
  static const Color defaultPrimary = Color(0xFF1F2937);

  /// 当前主题色（v1.8.0 支持自定义，见设置页「主题色 · 实验性」）。
  ///
  /// ⚠️ 这里从 `static const` 改成了 getter —— 因此**不能再用于 const 上下文**，
  ///    使用处若写了 `const` 需去掉（编译器会报错提示，不会静默出错）。
  static final ValueNotifier<Color> primaryNotifier =
      ValueNotifier<Color>(defaultPrimary);

  static Color get primaryColor => primaryNotifier.value;

  /// 可选的预设主题色（设计取舍：均为足够深的色，可配白字，
  /// 保证导航选中态、按钮文字的可读性）。
  static const List<(String, Color)> primaryPresets = [
    ('墨黑', Color(0xFF1F2937)),   // 默认
    ('小鹿紫', Color(0xFF7C5CD6)), // 呼应吉祥物
    ('学院蓝', Color(0xFF185FA5)),
    ('松绿', Color(0xFF0F6E56)),
    ('暖橙', Color(0xFFB45309)),
    ('玫红', Color(0xFFBE185D)),
  ];

  static void setPrimary(Color c) {
    if (primaryNotifier.value != c) primaryNotifier.value = c;
  }
  static const Color backgroundColor = Color(0xFFF8F9FC);

  // ---------------------------------------------------------------------------
  // 语义色板（v1.0.0 收敛）
  //
  // 此前全工程散落 707 处 `0xFF......` 字面量 + 351 处 `Colors.grey.shade*`，
  // 同一个色值在几十个文件里各写一遍，改配色要全工程搜替换。
  // 这里把**经统计确认的高频色值**提升为具名常量，值与原字面量完全一致
  // （纯改名，不改任何视觉）。
  //
  // 明暗配对采用 `context.surfaceColor` 这类扩展一次性给出，
  // 替代 90 处重复的 `Theme.of(context).brightness == Brightness.dark` 三元式。
  // ---------------------------------------------------------------------------

  /// 暗色下的表面色（卡片 / 弹窗底色）。原 0xFF1E1E1E。
  static const Color surfaceDark = Color(0xFF1E1E1E);

  /// 暗色下的页面底色（比表面更深）。原 0xFF121212。
  static const Color scaffoldDark = Color(0xFF121212);

  /// 亮色下正文/标题色。原 0xFF1F2937。
  static const Color textPrimaryLight = Color(0xFF1F2937);

  /// 亮色下次级文字。原 0xFF6B7280。
  static const Color textSecondaryLight = Color(0xFF6B7280);

  /// 亮色下更弱的提示文字（占位符 / 箭头）。原 0xFF9CA3AF。
  static const Color textTertiaryLight = Color(0xFF9CA3AF);

  /// 亮色下正文（比标题浅一档）。原 0xFF374151。
  static const Color textBodyLight = Color(0xFF374151);

  /// 成功 / 已绑定 / 通过。原 0xFF10B981。
  static const Color success = Color(0xFF10B981);

  /// 警告 / 进行中 / 积分。原 0xFFF59E0B。
  static const Color warning = Color(0xFFF59E0B);

  /// 危险 / 删除 / 未读点。原 0xFFEF4444。
  static const Color danger = Color(0xFFEF4444);

  /// 信息 / 链接类强调。原 0xFF3B82F6。
  static const Color info = Color(0xFF3B82F6);

  /// 亮色下描边。原 0xFFE5E7EB。
  static const Color borderLight = Color(0xFFE5E7EB);

  /// 暗色下描边 / 次级背景。原 0xFF2A2A2A。
  static const Color borderDark = Color(0xFF2A2A2A);

  /// 亮色下轻填充（输入框底 / 未选中态）。原 0xFFF3F4F6。
  static const Color fillLight = Color(0xFFF3F4F6);

  // ---------------------------------------------------------------------------
  // 设计令牌（v1.6.2 统一）：圆角 / 间距 / 字号
  //
  // 为什么要收敛：全工程原有 18 种圆角、19 种竖直间距、26 种字号 ——
  // 相近的数值（12/13/14、6/8/10）混用会让界面「差一点点整齐」，
  // 而这正是「看起来不正规」的根因。收敛后每类只保留 3~4 档语义。
  //
  // ⚠️ 收敛原则：**只统一「语义相同」的用法**。
  //    以下刻意保留不动：
  //    · 圆形头像、开关这类由尺寸决定的圆角（如 width/2）；
  //    · 进度条、Chrome 式 pill（999）等由形状决定的取值。
  // ---------------------------------------------------------------------------

  /// 圆角（Radius）：小控件 / 卡片 / 大容器 三档。
  ///
  /// - [radiusSm] 24 — 小控件：标签、chip、小按钮
  /// - [radiusMd] 14 — 常规卡片、输入框、弹窗条目（**最常用**）
  /// - [radiusLg] 20 — 大容器、底部弹层、强调卡
  static const double radiusSm = 12;
  static const double radiusMd = 14;
  static const double radiusLg = 20;

  /// 常用圆角对象（省去每次 `BorderRadius.circular(...)`）。
  static const BorderRadius radiusSmAll = BorderRadius.all(Radius.circular(radiusSm));
  static const BorderRadius radiusMdAll = BorderRadius.all(Radius.circular(radiusMd));
  static const BorderRadius radiusLgAll = BorderRadius.all(Radius.circular(radiusLg));

  /// 间距（Gap）：4 的倍数，四档。
  ///
  /// - [gapXs] 4  — 紧邻元素（图标与文字之间）
  /// - [gapSm] 8  — 同组元素
  /// - [gapMd] 12 — 组与组之间（**最常用**）
  /// - [gapLg] 16 — 区块之间
  /// - [gapXl] 24 — 大分区之间
  static const double gapXs = 4;
  static const double gapSm = 8;
  static const double gapMd = 12;
  static const double gapLg = 16;
  static const double gapXl = 24;

  /// 字号（FontSize）：六档语义层级。
  ///
  /// - [fontCaption] 11 — 角标、辅助说明
  /// - [fontSmall] 12.5 — 次要信息
  /// - [fontBody] 14 — 正文（**最常用**）
  /// - [fontTitle] 16 — 小标题 / 列表主标题
  /// - [fontHeading] 18 — 区块标题
  /// - [fontDisplay] 24 — 页面大标题
  static const double fontCaption = 11;
  static const double fontSmall = 12.5;
  static const double fontBody = 14;
  static const double fontTitle = 16;
  static const double fontHeading = 18;
  static const double fontDisplay = 24;

  // 可观察主题模式，用于运行时切换
  static final ValueNotifier<ThemeMode> modeNotifier = ValueNotifier<ThemeMode>(ThemeMode.light);

  static ThemeMode get currentMode => modeNotifier.value;

  static void setMode(ThemeMode mode) {
    if (modeNotifier.value != mode) {
      modeNotifier.value = mode;
      _setSystemOverlay(mode);
    }
  }

  static void _setSystemOverlay(ThemeMode mode) {
    // 主题只有「浅色 / 深色」两种（「跟随系统」已取消）
    final brightness = mode == ThemeMode.dark ? Brightness.dark : Brightness.light;
    final isDark = brightness == Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: isDark ? const Color(0xFF121212) : Colors.white,
        systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      ),
    );
  }

  // 主题缓存（v1.9.1 性能修复）
  //
  // ⚠️ 原来这两个是**纯 getter**，每次访问都重新构造整个 ThemeData
  //    （含 ColorScheme.fromSeed —— 要做色彩算法推导，很贵）。
  //    MaterialApp 每次 build 都会取它，于是「相同主题也生成新对象」，
  //    新对象会让整棵依赖主题的组件树重建 —— 这是「进 App 变慢」的主因之一。
  // 现改为：仅当主题色变化时才重建，其余时候复用同一个实例。
  static ThemeData? _lightCache;
  static ThemeData? _darkCache;
  static int _lightKey = -1;
  static int _darkKey = -1;

  static ThemeData get lightTheme {
    final key = primaryColor.value;
    if (_lightCache == null || _lightKey != key) {
      _lightKey = key;
      _lightCache = _buildTheme(Brightness.light);
    }
    return _lightCache!;
  }

  static ThemeData get darkTheme {
    final key = primaryColor.value;
    if (_darkCache == null || _darkKey != key) {
      _darkKey = key;
      _darkCache = _buildTheme(Brightness.dark);
    }
    return _darkCache!;
  }

  static ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryColor,
        brightness: brightness,
      ),
      scaffoldBackgroundColor: isDark ? const Color(0xFF121212) : backgroundColor,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.transparent,
        systemOverlayStyle: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        foregroundColor: isDark ? Colors.white : AppTheme.primaryColor,
        // M3 滚动态：内容滚到 AppBar 下方时默认叠加 tint+阴影（顶部突现固定色块），全局禁用。
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(vertical: 14),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF2C2C2C) : Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: isDark ? borderDark : borderLight),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: isDark ? borderDark : borderLight),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: primaryColor, width: 1.5),
        ),
        hintStyle: TextStyle(color: isDark ? Colors.grey.shade500 : Colors.grey.shade400),
      ),
      cardColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        selectedItemColor: primaryColor,
        unselectedItemColor: isDark ? Colors.grey.shade600 : const Color(0xFF9CA3AF),
      ),
    );
  }

  static List<BoxShadow> get cardShadow => [
        BoxShadow(
          color: Colors.black.withOpacity(0.04),
          blurRadius: 20,
          offset: const Offset(0, 4),
        ),
      ];
}

/// 主题便捷读取（v1.0.0）。
///
/// 替代全工程 90 处重复的
/// `Theme.of(context).brightness == Brightness.dark` 及其三元式。
/// 用法：`Container(color: context.surfaceColor)`
extension AppThemeContext on BuildContext {
  /// 当前是否深色模式。
  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  /// 表面色（卡片 / 弹窗底）：暗色 0xFF1E1E1E，亮色白。
  Color get surfaceColor => isDark ? AppTheme.surfaceDark : Colors.white;

  /// 页面底色：暗色 0xFF121212，亮色 AppTheme.backgroundColor。
  Color get scaffoldColor => isDark ? AppTheme.scaffoldDark : AppTheme.backgroundColor;

  /// 主文字色：暗色白，亮色 0xFF1F2937。
  Color get textPrimary => isDark ? Colors.white : AppTheme.textPrimaryLight;

  /// 次级文字色：暗色 grey.shade400，亮色 0xFF6B7280。
  Color get textSecondary => isDark ? Colors.grey.shade400 : AppTheme.textSecondaryLight;

  /// 更弱的提示文字：暗色 grey.shade500，亮色 0xFF9CA3AF。
  Color get textTertiary => isDark ? Colors.grey.shade500 : AppTheme.textTertiaryLight;

  /// 描边色：暗色 0xFF2A2A2A，亮色 0xFFE5E7EB。
  Color get borderColor => isDark ? AppTheme.borderDark : AppTheme.borderLight;
}
