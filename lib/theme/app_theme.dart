import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/ui_prefs.dart';

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

  /// 页面背景色（v1.5.0，2026-10-14，2026-11-03 修订）。
  ///
  /// **浅色模式**用的背景色。存的是用户原样选中的颜色（不再 `alphaBlend`
  /// 到白底）。深色模式用独立的 [backgroundDarkNotifier]，两者互不影响 ——
  /// 共用一份的话，浅色挑过米黄后一进深色就会变成「亮底 + 深字」。
  static final ValueNotifier<Color?> backgroundNotifier =
      ValueNotifier<Color?>(null);

  /// **深色模式**用的页面背景色（2026-11-03 新增）。null = 跟随 [scaffoldDark]。
  static final ValueNotifier<Color?> backgroundDarkNotifier =
      ValueNotifier<Color?>(null);

  static void setBackground(Color? c) {
    if (backgroundNotifier.value != c) {
      backgroundNotifier.value = c;
      // 系统手势条的颜色也跟着背景走，否则页面变了、底部还是老色带。
      refreshSystemOverlay();
    }
  }

  static void setBackgroundDark(Color? c) {
    if (backgroundDarkNotifier.value != c) {
      backgroundDarkNotifier.value = c;
      refreshSystemOverlay();
    }
  }

  /// 背景色预设（浅色系）。
  ///
  /// v1.6.3：色值按同一明度层级重调（更柔和、彼此更协调）。
  /// 2026-11-03：另加一组**深色系**预设 [backgroundPresetsDark]，
  /// 让深色模式也能选背景色 —— 此前那一行在深色下被整行隐藏。
  static const List<(String, Color)> backgroundPresets = [
    ('默认', Color(0xFFFFFFFF)),
    ('米黄', Color(0xFFFAF6EE)),
    ('浅灰', Color(0xFFF1F2F5)),
    ('淡蓝', Color(0xFFEDF3FA)),
    ('淡绿', Color(0xFFEDF6F0)),
  ];

  /// 深色模式背景预设（2026-11-03 新增）。
  ///
  /// 与浅色那组一一对应，保持同一层级关系：默认接近纯黑，
  /// 其余四个分别带一点点冷/暖倾向，避免深色下所有页面都是一模一样的死黑。
  static const List<(String, Color)> backgroundPresetsDark = [
    ('默认', Color(0xFF121212)),
    ('石墨', Color(0xFF1A1A1A)),
    ('冷灰', Color(0xFF161A1F)),
    ('墨蓝', Color(0xFF131820)),
    ('松绿', Color(0xFF141A16)),
  ];
  static const Color backgroundColor = Color(0xFFFFFFFF);

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
  // 🔴 2026-10-13：圆角改为**可全局缩放**（设置 → 外观 → 圆角）。
  //
  // 做法：三个基准值仍是 12/14/20，但乘一个全局缩放系数。所有用到圆角的地方
  // 统一走这三个 getter（脚本把 95 处 `BorderRadius.circular(12|14|20)` 字面量
  // 全部换成了 getter），改缩放系数 + 通知重建 = 全 App 圆角一起变。
  //
  // 为什么能用 getter 而不是 const：改之前已确认**没有任何一处**在 const 上下文
  // 里用这三个值（唯一一处 const BorderRadius.vertical 已一并去掉 const）。
  /// 默认圆角缩放。
  ///
  /// 2026-10-24 曾改为 0.55（「最小」—— 视觉上趋近直角）；
  /// **2026-11-02 按用户审批 D1 恢复为 1.0**，即三档回到设计稿原值
  /// （sm 12 / md 14 / lg 20）。想回到偏直角的观感，改这一个数即可。
  ///
  /// 未手动调过的用户一律用它；调过的用户以存盘值为准。
  static const double defaultRadiusScale = 1.0;

  /// 滑杆可调范围：0.2（趋近直角）~ 1.6（很圆润）。
  static const double minRadiusScale = 0.2;
  static const double maxRadiusScale = 1.6;

  static double _radiusScale = defaultRadiusScale;

  /// 全局圆角缩放。
  static double get radiusScale => _radiusScale;

  /// 圆角缩放变化通知：main.dart 监听它做整树重建（与 [modeNotifier] 同一套路）。
  static final ValueNotifier<double> radiusNotifier =
      ValueNotifier<double>(defaultRadiusScale);

  static void setRadiusScale(double s) {
    final v = s.clamp(minRadiusScale, maxRadiusScale);
    if ((v - _radiusScale).abs() < 0.001) return;
    _radiusScale = v;
    // 🔴 v1.0.9：主题缓存必须一起失效。
    //    `_buildTheme` 里 5 处用了 `radiusMd`（SnackBar / ElevatedButton / 输入框描边），
    //    但缓存 key 只含 主色 ^ 背景 ^ 字体 → 拖圆角滑杆后卡片（widget 层直接读
    //    getter）立刻变圆，按钮/输入框/SnackBar 却纹丝不动，直到重启。
    _lightCache = null;
    _darkCache = null;
    radiusNotifier.value = v;
  }

  static double radiusSmRaw = 12;
  static double radiusMdRaw = 14;
  static double radiusLgRaw = 20;

  static double get radiusSm => (radiusSmRaw * _radiusScale).roundToDouble();
  static double get radiusMd => (radiusMdRaw * _radiusScale).roundToDouble();
  static double get radiusLg => (radiusLgRaw * _radiusScale).roundToDouble();

  /// 常用圆角对象（省去每次 `BorderRadius.circular(...)`）。
  static BorderRadius get radiusSmAll => BorderRadius.all(Radius.circular(radiusSm));
  static BorderRadius get radiusMdAll => BorderRadius.all(Radius.circular(radiusMd));
  static BorderRadius get radiusLgAll => BorderRadius.all(Radius.circular(radiusLg));

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

  /// 特大标题（2026-11-03 新增，UI P0）。
  ///
  /// 首页「掌上锡院」31px 原本是三处硬编码里最突出的一处。它不是任一层级，
  /// 是**展示性大字**（一个页面只出现一次），故单独给一档，不与 fontDisplay(24) 混。
  /// 补这一档之后，「改字号」才真正不需要再动页面文件。
  static const double fontHero = 31;

  /// 行高（2026-11-03 新增，UI P0）。
  ///
  /// 中文正文行高比西文需要更松：1.5 是正文，1.2 是标题，1.0 是单行大字。
  /// 散写 1.15 / 1.3 / 1.4 会让「同一段话在不同位置看起来疏密不一样」。
  static const double lineBody = 1.5;
  static const double lineTitle = 1.2;
  static const double lineTight = 1.0;

  // ---------------------------------------------------------------------------
  // 动效令牌（2026-11-03 新增，UI P0，来自 docs/UI_POLISH_PLAN.md 4.3）
  //
  // 原来散写 Duration(milliseconds: 180) / 220 / 250 / 300 共 28 处，
  // 同一个「淡入」在三个页面是三档速度 —— 用户感受不到差别，但会觉得「有点不齐」。
  // ---------------------------------------------------------------------------

  /// 快速反馈：按钮按下、勾选、开关。
  static const Duration durFast = Duration(milliseconds: 120);

  /// 常规过渡：内容淡入淡出、卡片展开。
  static const Duration durBase = Duration(milliseconds: 200);

  /// 较慢过渡：页面内大块内容切换。
  static const Duration durSlow = Duration(milliseconds: 320);

  /// 标准缓动：进入用 easeOutCubic（快出慢收），符合「东西飞过来减速停下」的直觉。
  static const Curve curveStandard = Curves.easeOutCubic;

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
    // 「跟随系统」时按系统当前亮度算状态栏图标颜色。
    final brightness = switch (mode) {
      ThemeMode.dark => Brightness.dark,
      ThemeMode.light => Brightness.light,
      ThemeMode.system => WidgetsBinding.instance.platformDispatcher
              .platformBrightness ==
          Brightness.dark
          ? Brightness.dark
          : Brightness.light,
    };
    final isDark = brightness == Brightness.dark;
    // 🔴 2026-11-04 审查 P1：系统手势条原来写死 121212 / 白。
    //    用户在深色里选石墨/冷灰/墨蓝/松绿后，页面变了、系统导航条还是纯黑，
    //    底部又是一条色带。这里与 `context.scaffoldColor` 保持同一口径。
    final navBar = isDark
        ? (backgroundDarkNotifier.value ?? scaffoldDark)
        : (backgroundNotifier.value ?? Colors.white);
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: navBar,
        systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      ),
    );
  }

  /// 背景色变更后重算系统栏配色（背景与明暗是两条独立的通知线）。
  static void refreshSystemOverlay() => _setSystemOverlay(modeNotifier.value);

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

  /// 字体族进缓存 key 的低位扰动（2026-11-03）。
  ///
  /// 换字体必须让 `_buildTheme` 重跑，否则缓存命中会返回旧字体，
  /// 用户会以为「字体设置没生效」。
  static int get _fontKey => UiPrefs.fontFamily.hashCode & 0xFFFF;

  static ThemeData get lightTheme {
    // 缓存 key 同时含主题色与背景色（2026-11-03：深色背景也进 key，
    // 否则深色换背景色不生效 —— 缓存命中直接返回旧主题）
    final bg = backgroundNotifier.value?.toARGB32() ?? -1;
    final bgDark = backgroundDarkNotifier.value?.toARGB32() ?? -1;
    final key = primaryColor.toARGB32() ^ (bg * 97) ^ (bgDark * 31) ^ _fontKey;
    if (_lightCache == null || _lightKey != key) {
      _lightKey = key;
      _lightCache = _buildTheme(Brightness.light);
    }
    return _lightCache!;
  }

  static ThemeData get darkTheme {
    final key = primaryColor.toARGB32() ^ (backgroundDarkNotifier.value?.toARGB32() ?? -1) * 31 ^ _fontKey;
    if (_darkCache == null || _darkKey != key) {
      _darkKey = key;
      _darkCache = _buildTheme(Brightness.dark);
    }
    return _darkCache!;
  }

  static ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    // 2026-11-03：全局字体族。空串 = 跟随系统默认中文字体。
    final family = UiPrefs.fontFamily;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: family.isEmpty ? null : family,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryColor,
        brightness: brightness,
      ),
      scaffoldBackgroundColor: isDark
          ? (backgroundDarkNotifier.value ?? scaffoldDark)
          : (backgroundNotifier.value ?? backgroundColor),
      // 2026-10-20：选择类弹窗统一纯白底（M3 默认会叠一层 surfaceTint，看起来发灰）
      dialogTheme: DialogTheme(
        backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          // v1.0.9：原来是写死的 20（= radiusLgRaw 的初始值，被抄成了常量）。
          // 圆角调到最小时弹窗仍是大圆角，与全 App 的风格对着干，而且重启也不变。
          borderRadius: BorderRadius.circular(radiusLg),
        ),
      ),
      // 🔴 2026-11-03 新增：全局 SnackBar 规范。
      //
      // 加它之前全库有 **11 份各写一遍的 `_toast()`**，行为分三种：
      //   · 底部贴边（grade_query / my_study 等，最简版什么都没设）
      //   · 悬浮 + margin(20,0,20,80) + 2s（home_page）
      //   · 悬浮 + margin(20,0,20,80) + 1600ms（home_todo_list）
      // 同一个 App 里同一条提示出现在三种位置，是「质感不一致」里最刺眼的一类。
      // 这里定死一种：**悬浮、距底部 24、2 秒、圆角 14、不吃满宽度**。
      // 注意不能设 margin 里的 bottom 太大 —— 底部导航高 56，24 刚好在它上方。
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark
            ? const Color(0xFF2C2C2C)
            : const Color(0xFF1F2937),
        contentTextStyle: const TextStyle(
          fontSize: fontBody,
          height: lineBody,
          color: Colors.white,
        ),
        actionTextColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
        insetPadding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        elevation: 4,
        showCloseIcon: false,
      ),
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
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
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
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          borderSide: BorderSide(color: isDark ? borderDark : borderLight),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          borderSide: BorderSide(color: isDark ? borderDark : borderLight),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
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

  /// 卡片阴影（2026-11-03 改多层，替代 1px 硬边框）。
  ///
  /// 🔴 **为什么要改**：原来是单层 `alpha 0.04 / blur 20` —— 在浅色背景上
  /// 几乎不可见，等于「没有纵深」；而 `AppCard` 同时又画了 1px
  /// `borderColor`（浅色 `#E5E7EB`），那是一道硬线，等于「不轻盈」。
  /// 两个都想占，结果两头不占：卡片既没有浮起来的层次，又有生硬的框。
  ///
  /// 现在按「隐形描边 + 双层纵深」来：
  /// 1. `spreadRadius: 1 / blur 0` 做 6% 黑的一圈「隐形描边」，替代硬边框
  ///    —— 它比 `Border.all` 柔和，且随圆角走，不会在深色下变脏。
  /// 2. `0 1 2 -1` 贴边微影，负责「卡片有一点点厚度」。
  /// 3. `0 2 4` 柔和外扩，负责「离开背景」。
  ///
  /// 深色模式下黑色阴影天然不可见，所以改用更深的黑 + 更大 blur，
  /// 靠 `cardShadowFor(context.isDark)` 区分。
  static List<BoxShadow> get cardShadow => cardShadowFor(false);

  /// 🔴 2026-11-03 修「多处边框出现消失部分边线」：描边必须画在**内侧**。
  ///
  /// 上一版把「隐形描边」做成了 `BoxShadow(blurRadius: 0, spreadRadius: 1)`,
  /// 也就是**盒子外侧扩 1px 的黑圈**。它有两个必坏场景：
  /// 1. 父级有裁剪（`ListView` 默认 `clipBehavior: Clip.hardEdge`、
  ///    `ClipRRect`、`Clip.hardEdge`）：外扩那 1px 直接被切掉 ——
  ///    于是卡片「上边有、下边没」「左边有、右边没」，正是用户看到的样子。
  /// 2. 相邻卡片贴得近时，两圈外扩阴影互相覆盖，中间那道边时有时无。
  ///
  /// `Border.all` 画在盒子**内侧**，无论父级怎么裁剪都不会丢。
  /// 所以：**轮廓回退到 `Border.all`，阴影只负责纵深**。
  /// 颜色不用 `borderColor`（那道硬线太脏），改用 6% 黑 / 深色 55% 黑，
  /// 观感与上一版想要的「隐形描边」一致，但永远不丢边。
  static Color cardStrokeColor(bool isDark) => isDark
      ? Colors.black.withValues(alpha: 0.55)
      : Colors.black.withValues(alpha: 0.06);

  /// 按明暗返回卡片阴影（**只做纵深，不做描边**，描边见 [cardStrokeColor]）。
  static List<BoxShadow> cardShadowFor(bool isDark) {
    if (isDark) {
      return [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.30),
          blurRadius: 6,
          offset: const Offset(0, 2),
        ),
      ];
    }
    return [
      // 贴边微影：-1 的 spread 让它只落在下沿，不会把四边都描黑。
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.06),
        blurRadius: 2,
        spreadRadius: -1,
        offset: const Offset(0, 1),
      ),
      // 柔和外扩：卡片「离开背景」的那点纵深。
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.04),
        blurRadius: 4,
        offset: const Offset(0, 2),
      ),
    ];
  }
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

  /// 卡片底色：语义上等同 [surfaceColor]，单独命名是为了替换
  /// 全库 50 处 `isDark ? const Color(0xFF1E1E1E) : Colors.white` 时读起来更贴切。
  Color get cardColor => surfaceColor;

  /// 页面底色：暗色默认 0xFF121212、亮色默认 [AppTheme.backgroundColor]，
  /// 用户设了背景色就用用户的（2026-11-03 起**深色也生效**）。
  ///
  /// 约束：深色下如果用户挑的是浅色背景，页面会变成亮底 + 深字，
  /// 那是用户自己的选择（设置页给的是深色系预设，正常不会撞上）。
  Color get scaffoldColor => isDark
      ? (AppTheme.backgroundDarkNotifier.value ?? AppTheme.scaffoldDark)
      : (AppTheme.backgroundNotifier.value ?? AppTheme.backgroundColor);

  /// 主文字色：暗色白，亮色 0xFF1F2937。
  Color get textPrimary => isDark ? Colors.white : AppTheme.textPrimaryLight;

  /// 次级文字色：暗色 grey.shade400，亮色 0xFF6B7280。
  Color get textSecondary => isDark ? Colors.grey.shade400 : AppTheme.textSecondaryLight;

  /// 更弱的提示文字：暗色 grey.shade500，亮色 0xFF9CA3AF。
  Color get textTertiary => isDark ? Colors.grey.shade500 : AppTheme.textTertiaryLight;

  /// 描边色：暗色 0xFF2A2A2A，亮色 0xFFE5E7EB。
  Color get borderColor => isDark ? AppTheme.borderDark : AppTheme.borderLight;

  // ---- 语义色（2026-11-03 新增） ----------------------------------------
  //
  // 加这四个 getter 之前，想用一个「红/黄/绿/蓝」就得自己写
  // `isDark ? const Color(0xFF...) : const Color(0xFF...)`，于是全库沉淀了
  // 356 处硬编码 `Color(0xFF........)`，其中最高频的 6 个色**全都已有令牌**：
  //   0xFF9CA3AF ×31 = textTertiaryLight
  //   0xFF6B7280 ×31 = textSecondaryLight
  //   0xFFEF4444 ×21 = danger
  //   0xFFF59E0B ×15 = warning
  //   0xFFE5E7EB ×14 = borderLight
  //   0xFF10B981 ×13 = success
  // 硬编码的原因不是不知道有令牌，而是**令牌只有亮色值、暗色要自己调**。
  // 这四个 getter 把「暗色该怎么调」也一并定死，才谈得上收敛。
  //
  // 调法：亮色直接用原值；暗色提亮一档（暗背景上原来那档会发闷），
  // 只有 `danger` 在暗色下略微降饱和 —— 纯 #EF4444 在黑底上刺眼。
  Color get successColor =>
      isDark ? const Color(0xFF34D399) : AppTheme.success;

  Color get warningColor =>
      isDark ? const Color(0xFFFBBF24) : AppTheme.warning;

  Color get dangerColor =>
      isDark ? const Color(0xFFF87171) : AppTheme.danger;

  Color get infoColor => isDark ? const Color(0xFF60A5FA) : AppTheme.info;

  /// 服务/工具图标底：主题色 10%（亮）/ 20%（暗）—— 全库最高频的一处手写。
  Color get iconTintBg =>
      AppTheme.primaryColor.withValues(alpha: isDark ? 0.20 : 0.10);

  /// 卡片/弹窗里第二层的浅底色（比 [cardColor] 再深一档）。
  Color get subtleFill => isDark ? AppTheme.borderDark : AppTheme.fillLight;
}
