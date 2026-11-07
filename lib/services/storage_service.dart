import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../theme/app_theme.dart';

/// 统一用户配置：ShowDoc 链接、统一认证账密、游客/登录状态、主题、最后版本。
class UserConfig {
  final String showdocUrl;
  final String username;
  final String password;
  final bool rememberPassword;
  final ThemeMode themeMode;

  /// 自定义主题色（v1.8.0）。存 ARGB 整数，0 表示「未设置」→ 用默认墨黑。
  final int primaryColor;

  const UserConfig({
    this.showdocUrl = '',
    this.username = '',
    this.password = '',
    this.rememberPassword = true,
    this.themeMode = ThemeMode.light,
    this.primaryColor = 0,
  });

  UserConfig copyWith({
    String? showdocUrl,
    String? username,
    String? password,
    bool? rememberPassword,
    ThemeMode? themeMode,
    int? primaryColor,
  }) => UserConfig(
        showdocUrl: showdocUrl ?? this.showdocUrl,
        username: username ?? this.username,
        password: password ?? this.password,
        rememberPassword: rememberPassword ?? this.rememberPassword,
        themeMode: themeMode ?? this.themeMode,
        primaryColor: primaryColor ?? this.primaryColor,
      );
}

/// 本地存储服务：用 SharedPreferences 持久化用户配置
class StorageService {
  static const String _kShowdoc = 'user_showdoc_url';
  static const String _kUsername = 'user_username';
  static const String _kPassword = 'user_password';
  static const String _kRemember = 'user_remember_password';
  static const String _kThemeMode = 'user_theme_mode';
  static const String _kPrimaryColor = 'user_primary_color'; // v1.8.0 自定义主题色
  static const String _kStudentName = 'student_name'; // 学生姓名缓存（「我的」页展示）
  static const String _kHiddenServices = 'hidden_services'; // v1.9.0 服务页显示/隐藏

  // 教务密码专用键：存放在系统安全存储（Android Keystore / iOS Keychain），
  // 不写入 SharedPreferences 明文。
  static const String _kSecurePassword = 'secure_school_password';
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  // 兼容旧键（首次读取若新键没有，尝试旧键）
  static const String _kOldShowdoc = 'grade_push_showdoc_url';
  static const String _kOldUsername = 'grade_push_username';
  static const String _kOldPassword = 'grade_push_password';
  static const String _kOldRemember = 'grade_push_remember_password';

  static Future<UserConfig> loadUserConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final remember = prefs.getBool(_kRemember) ??
        prefs.getBool(_kOldRemember) ??
        true;

    String showdoc = prefs.getString(_kShowdoc) ??
        prefs.getString(_kOldShowdoc) ??
        '';
    String username = prefs.getString(_kUsername) ??
        prefs.getString(_kOldUsername) ??
        '';
    String password = '';
    if (remember) {
      // 密码仅从安全存储读取；若为首次运行且旧版曾明文存于 SP，则迁移后删除明文
      password = await _secure.read(key: _kSecurePassword) ?? '';
      if (password.isEmpty) {
        final legacy = prefs.getString(_kPassword) ?? prefs.getString(_kOldPassword);
        if (legacy != null && legacy.isNotEmpty) {
          await _secure.write(key: _kSecurePassword, value: legacy);
          password = legacy;
        }
      }
      // 清除可能残留的明文密码，杜绝双重存储（仅 remember=true 分支内执行；
      // 关掉"记住密码"时历史明文残留不会被清掉 —— 已知缺口，见审查报告）
      await prefs.remove(_kPassword);
      await prefs.remove(_kOldPassword);
    }

    return UserConfig(
      showdocUrl: showdoc,
      username: username,
      password: password,
      rememberPassword: remember,
      themeMode: parseThemeMode(prefs.getString(_kThemeMode)),
      primaryColor: prefs.getInt(_kPrimaryColor) ?? 0,
    );
  }

  static Future<void> saveUserConfig(UserConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kShowdoc, config.showdocUrl);
    await prefs.setString(_kUsername, config.username);
    await prefs.setBool(_kRemember, config.rememberPassword);
    await prefs.setString(_kThemeMode, config.themeMode.name);
    await prefs.setInt(_kPrimaryColor, config.primaryColor);
    // 密码仅写入系统安全存储，绝不落 SharedPreferences 明文
    if (config.rememberPassword) {
      await _secure.write(key: _kSecurePassword, value: config.password);
    } else {
      await _secure.delete(key: _kSecurePassword);
    }
    // 确保旧明文已被清除
    await prefs.remove(_kPassword);
    await prefs.remove(_kOldPassword);
  }

  /// 解析持久化的主题模式字符串。
  ///
  /// 🔴 「跟随系统」(system) 必须原样返回：它是设置页里真实存在的选项，
  ///    之前这里把它迁移成浅色 → 用户选了跟随系统、重启后又变回浅色。
  ///    公开出来是为了能直接测这条规则。
  @visibleForTesting
  static ThemeMode parseThemeMode(String? v) {
    switch (v) {
      case 'dark':
        return ThemeMode.dark;
      // 「跟随系统」是真实存在的选项（设置 → 界面与显示 → 明暗模式），
      // 必须原样读回 —— 之前这里把它强制迁移成浅色，导致用户选了
      // 「跟随系统」重启后又变回浅色。
      case 'system':
        return ThemeMode.system;
      default:
        return ThemeMode.light;
    }
  }

  // ---- 学生姓名缓存（「我的」页展示用）----
  //
  // 姓名来自教务成绩查询返回的学生信息，成功后缓存到本地，避免每次进「我的」
  // 页都重新查询一遍（成绩查询本身较重）。

  static Future<void> saveStudentName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    if (name.trim().isEmpty) {
      await prefs.remove(_kStudentName);
    } else {
      await prefs.setString(_kStudentName, name.trim());
    }
  }

  static Future<String> loadStudentName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kStudentName) ?? '';
  }

  // ---- 公告弹窗「不再提醒」持久化 ----
  // 2026-10-18：免责声明弹窗已按用户要求整段删除，这两个读写方法一并移除。

  /// 教务系统时段提示（温馨提示）是否已被用户选择「不再提醒」。
  // ---- 服务页显示/隐藏（v1.9.0） ----

  /// 读取被隐藏的服务 id 列表。未设置返回空列表（= 全部显示）。
  static Future<List<String>> loadHiddenServices() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kHiddenServices) ?? <String>[];
  }

  /// 保存被隐藏的服务 id 列表。
  // ---------------- 待办排序方式（2026-11-03） ----------------
  // 'time' = 按时间（默认，原行为）；'priority' = 按优先级再按时间。
  static const String _kTodoSortMode = 'todo_sort_mode';

  static Future<String> loadTodoSortMode() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_kTodoSortMode);
    return (v == 'priority') ? 'priority' : 'time';
  }

  static Future<void> saveTodoSortMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTodoSortMode, mode == 'priority' ? 'priority' : 'time');
  }

  // ---------------- 服务页排序（2026-11-03） ----------------
  // 存的是**用户拖出来的 id 顺序**；不在列表里的新服务由调用方追加到末尾，
  // 这样以后加了新服务、老用户也能按「老顺序 + 新服务补末尾」展示。
  static const String _kServiceOrder = 'service_order';

  static Future<List<String>> loadServiceOrder() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kServiceOrder) ?? <String>[];
  }

  static Future<void> saveServiceOrder(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kServiceOrder, ids);
  }

  static Future<void> saveHiddenServices(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kHiddenServices, ids);
  }

  // ---- 我的成绩（本地缓存，仅在推送时更新） ----

  static const String _kGradeCache = 'grade_cache_v1';

  /// 保存成绩缓存（semesters/summary/saved_at），不遗漏任何学期。
  static Future<void> saveGradeCache(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString(_kGradeCache, jsonEncode(data));
    } catch (_) {
      // 序列化异常时忽略，不阻断主流程
    }
  }

  /// 读取成绩缓存；无则返回 null。
  static Future<Map<String, dynamic>?> loadGradeCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kGradeCache);
    if (raw == null || raw.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  // ---- 一卡通余额缓存（v2.4.5）----
  // 目的：余额获取成功后缓存到本地，再次进入用户页直接展示缓存值，
  //       不必每次都重新走一遍"登录门户 → 抓卡片"，避免长时间转圈。

  static const String _kCardBalanceCache = 'card_balance_cache_v1';

  /// 保存一卡通余额缓存（金额 + 时间戳）。
  static Future<void> saveCardBalanceCache(double balance) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString(
        _kCardBalanceCache,
        jsonEncode({
          'balance': balance,
          'saved_at': DateTime.now().toIso8601String(),
        }),
      );
    } catch (_) {
      // 序列化异常时忽略，不阻断主流程
    }
  }

  /// 读取一卡通余额缓存；无 / 解析失败返回 null。
  static Future<({double balance, DateTime savedAt})?> loadCardBalanceCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kCardBalanceCache);
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final b = m['balance'];
      final t = DateTime.tryParse((m['saved_at'] ?? '').toString());
      if (b is! num || t == null) return null;
      return (balance: b.toDouble(), savedAt: t);
    } catch (_) {
      return null;
    }
  }

  /// 清除一卡通余额缓存（解除绑定、切换账号时调用，避免残留上个账号的金额）。
  static Future<void> clearCardBalanceCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kCardBalanceCache);
  }

  // ---------------- 全局外观：圆角缩放（2026-10-13） ----------------
  //
  // 设置 → 外观 → 圆角：滑杆 0.2（趋近直角）~ 1.6（很圆润）。
  // 启动时读出并 apply 到 AppTheme；改的时候立刻 apply + 存盘。
  static const String _kUiRadiusScale = 'ui_radius_scale';

  /// 没调过 → 用 [AppTheme.defaultRadiusScale]（设计稿原值）；
  /// 调过 → 以存盘值为准并夹到合法区间。
  ///
  /// 2026-11-02（用户审批 D1「圆角恢复成设计稿大小」）：
  /// 这里原来写死 `0.55`，只改 AppTheme 的默认值对**老用户完全无效** ——
  /// 他们手机上已经存了 0.55，启动时照样把 0.55 读回来覆盖掉新默认。
  /// 现在改成：没有存盘值就用 AppTheme 的默认值；存的是 0.55 就一次性迁到默认值。
  ///
  /// 为什么 0.55 可以无脑迁：它既是 2026-10-24 之前的 AppTheme 默认值，
  /// 也是那次「0.2 → 0.55」强制迁移的目标值，停在这个数上的人几乎都不是主动选的。
  /// 真主动调过 0.55 的人重新拨一下只要两秒，而留在 0.55 等于 D1 永远不生效。
  static Future<double> loadUiRadiusScale() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getDouble(_kUiRadiusScale);
    if (v == null || v <= 0) return AppTheme.defaultRadiusScale;

    // 0.2 是更早的「趋近直角」默认值，直接归到新默认，不再经过中间态 0.55。
    const migrated020 = 'ui_radius_default_migrated_055';
    const migratedDefault = 'ui_radius_default_migrated_design';
    final lookedLikeOldDefault = (v - 0.2).abs() < 0.001 || (v - 0.55).abs() < 0.001;
    if (lookedLikeOldDefault && prefs.getBool(migratedDefault) != true) {
      await prefs.setBool(migrated020, true);
      await prefs.setBool(migratedDefault, true);
      await prefs.setDouble(_kUiRadiusScale, AppTheme.defaultRadiusScale);
      return AppTheme.defaultRadiusScale;
    }

    return v.clamp(AppTheme.minRadiusScale, AppTheme.maxRadiusScale);
  }

  static Future<void> saveUiRadiusScale(double scale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kUiRadiusScale, scale);
  }

  // ---------------- 全局外观：字体缩放 / 动效强度 ----------------

  static const String _kUiTextScale = 'ui_text_scale';
  static const String _kUiMotion = 'ui_motion';

  /// 字体缩放（0.85~1.30）；没调过 → 1.0。
  static Future<double> loadUiTextScale() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getDouble(_kUiTextScale);
    if (v == null || v <= 0) return 1.0;
    return v.clamp(0.85, 1.30);
  }

  static Future<void> saveUiTextScale(double v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kUiTextScale, v);
  }

  /// 动效强度（0~1）；没调过 → 1.0。
  static Future<double> loadUiMotion() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getDouble(_kUiMotion);
    if (v == null || v < 0) return 1.0;
    return v.clamp(0.0, 1.0);
  }

  static Future<void> saveUiMotion(double v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kUiMotion, v);
  }

  static const String _kUiHaptics = 'ui_haptics';

  /// 振动反馈开关；没调过 → 开。
  ///
  /// 2026-11-03（1.0.9）：开关升级成四档强度（关闭/轻/强/极强），
  /// 新键 [_kUiHapticLevel]。这里保留旧键是为了**老用户迁移**：
  /// 老版本关过振动的人，升级后不该突然开始震。
  static Future<bool> loadUiHaptics() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kUiHaptics) ?? true;
  }

  static Future<void> saveUiHaptics(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUiHaptics, v);
  }

  static const String _kUiHapticLevel = 'ui_haptic_level';

  /// 振动强度档位（0 关闭 / 1 轻 / 2 强 / 3 极强）。
  ///
  /// 迁移规则：如果新键还没写过，就看旧开关 —— 明确关过的读成 0，
  /// 其余一律默认 2（「强」）。
  static Future<int> loadUiHapticLevel() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_kUiHapticLevel);
    if (v != null) return v.clamp(0, 3);
    final legacy = prefs.getBool(_kUiHaptics);
    return legacy == false ? 0 : 2;
  }

  static Future<void> saveUiHapticLevel(int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kUiHapticLevel, v.clamp(0, 3));
  }

  // ---------------- 字体族（2026-11-03，设置页「字体设置」） ----------------
  static const String _kUiFontFamily = 'ui_font_family';

  /// 全局字体族；空串 = 跟随系统默认。
  static Future<String> loadUiFontFamily() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kUiFontFamily) ?? '';
  }

  static Future<void> saveUiFontFamily(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUiFontFamily, v);
  }

  // ---- 通知页「我已手动设置好」的自检确认（2026-11-03，设置页 #9） ----
  //
  // 电池优化 / 自启动 / 通知渠道这三项**系统不给我们读状态**，
  // 只能用户自己进系统设置看。以前页面永远显示灰色的「需手动确认」，
  // 用户回来也不知道自己算不算搞定了。改成让用户自己点一下确认，
  // 勾了就变绿，并且跨启动记住。
  static const String _kNotifChecked = 'notif_manual_checked';

  static Future<Set<String>> loadNotifChecked() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_kNotifChecked) ?? const <String>[]).toSet();
  }

  static Future<void> saveNotifChecked(Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kNotifChecked, ids.toList()..sort());
  }

  // ---------------- 页面背景色（v1.5.0，浅色模式生效） ----------------
  static const String _kUiBackgroundColor = 'ui_bg_color';

  /// 页面背景色；null = 默认（跟随 AppTheme.backgroundColor）。存 -1 表示未设置。
  static Future<Color?> loadUiBackgroundColor() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_kUiBackgroundColor);
    if (v == null || v < 0) return null;
    return Color(v);
  }

  static Future<void> saveUiBackgroundColor(Color? c) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kUiBackgroundColor, c?.toARGB32() ?? -1);
  }

  // ---------------- 深色模式背景色（2026-11-03） ----------------
  // 与浅色背景**分开存**：共用一份的话，浅色挑过米黄后一进深色就会
  // 变成「亮底 + 深字」—— 这是原来把该设置项在深色下整行隐藏的原因。
  static const String _kUiBackgroundColorDark = 'ui_bg_color_dark';

  static Future<Color?> loadUiBackgroundColorDark() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_kUiBackgroundColorDark);
    if (v == null || v < 0) return null;
    return Color(v);
  }

  static Future<void> saveUiBackgroundColorDark(Color? c) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kUiBackgroundColorDark, c?.toARGB32() ?? -1);
  }

  // ---------------- 手绘纸纹背景（2026-11-04，实验性） ----------------
  // 存的是 `HandDrawnBackground.id`（'none'/'ruled'/...），不是序号 ——
  // 以后往枚举里插新风格不会把老用户的选择串位。null / 未知值一律回落 'none'。
  static const String _kHandDrawnBackground = 'hand_drawn_background_v1';
  static const String kHandDrawnBackgroundNone = 'none';

  static Future<String> loadHandDrawnBackground() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_kHandDrawnBackground);
    if (v == null || v.isEmpty) return kHandDrawnBackgroundNone;
    return v;
  }

  static Future<void> saveHandDrawnBackground(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kHandDrawnBackground, id);
  }

  // ---------------- 消息页栏目样式（v1.1.0） ----------------
  // 两套样式随时可切：'plain' 纯白无缝（默认）/ 'card' 圆角卡片。
  static const String _kMessageStyle = 'message_style';
  static const String kMessageStylePlain = 'plain';
  static const String kMessageStyleCard = 'card';

  // ---------------- 冲突忽略名单（v1.6.0） ----------------
  // 用户在「时间冲突」弹窗里选择删掉的教务课会记在这里（签名 = 课名|教师|星期|
  // 起止节次|周次），之后每次同步都把它们过滤掉 —— 否则下次同步教务又下发，
  // 用户删过的冲突课会复活。可随时在「课表设置」里恢复。
  static const String _kDroppedCourseKeys = 'dropped_course_keys';

  static Future<List<String>> loadDroppedCourseKeys() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kDroppedCourseKeys) ?? const <String>[];
  }

  static Future<void> saveDroppedCourseKeys(List<String> keys) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kDroppedCourseKeys, keys);
  }

  // ---------------- 已确认过的冲突组（2026-10-16）----------------
  // 「进课表页自动提示一次教务内部冲突」用过的去重表：用户处理过的冲突组
  // （**包括选「都保留」**——那也是一种明确处理）记在这里，之后进页面不再自动弹。
  // 否则「都保留」不删课 = 冲突还在 → 每次进课表页都再弹一遍，很打扰。
  static const String _kAckedConflicts = 'acked_conflict_groups';

  static Future<List<String>> loadAcknowledgedConflicts() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kAckedConflicts) ?? const <String>[];
  }

  static Future<void> saveAcknowledgedConflicts(List<String> keys) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kAckedConflicts, keys);
  }

  static Future<String> loadMessageStyle() async {
    final prefs = await SharedPreferences.getInstance();
    // 2026-10-11：默认改为圆角卡片（v1.7.1 起 —— 此前此前还停在纯白，
    // 新装用户在两个版本上看到的默认样式不一样）
    return prefs.getString(_kMessageStyle) ?? kMessageStyleCard;
  }

  static Future<void> saveMessageStyle(String style) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMessageStyle, style);
  }

  // ---------------- 消息同步量（「最多同步 N 条」） ----------------
  // 一个数字同时决定三件事：每个源**抓多少**、本机档案**存多少**、界面**显示多少**。
  // 用户拍板用「条数」而不是「页数」——不该让他去记"一页算几条"。
  static const String _kMessageSyncCount = 'message_sync_count';

  /// 默认 40 条。
  ///
  /// 🔴 从 200 改成 40 是**实测之后的修正**，不是口味问题：教务处分页实测
  /// 每页 12 条、全站 150 页（1793 条），200 条 = 至少 17 页网络请求。
  /// 首次进入消息页就默默打十几分钟级别的请求量，既慢又对校方站点不礼貌。
  /// 40 条（约 4 页）是"一屏看得到变化"与"首次进页面秒开"的平衡点，
  /// 想要更多的人可以在设置里加档 —— 档位快捷键第一项就写着 40。
  static const int kMessageSyncCountDefault = 40;
  static const int kMessageSyncCountMin = 20;
  static const int kMessageSyncCountMax = 2000;

  /// 设置页的档位快捷键。第一个就是默认值，方便用户一眼认出当前在哪一档。
  static const List<int> kMessageSyncCountPresets = [40, 60, 120, 200, 400];

  /// 🔴 **钳制**，不是"非法就回落默认值"。
  ///
  /// 曾经写成「白名单 + 非法回落默认」：用户输入 7 页会被**悄悄改回 3 页**，
  /// 设置项形同摆设。钳制的语义是"超界就收到边界"，用户填 5000 得到 2000，
  /// 至少他知道自己填的生效了。
  static int normalizeMessageSyncCount(int? raw) {
    if (raw == null) return kMessageSyncCountDefault;
    if (raw < kMessageSyncCountMin) return kMessageSyncCountMin;
    if (raw > kMessageSyncCountMax) return kMessageSyncCountMax;
    return raw;
  }

  static Future<int> loadMessageSyncCount() async {
    final prefs = await SharedPreferences.getInstance();
    return normalizeMessageSyncCount(prefs.getInt(_kMessageSyncCount));
  }

  static Future<void> saveMessageSyncCount(int count) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kMessageSyncCount, normalizeMessageSyncCount(count));
  }

  // ---------------- 消息页「每次进入自动更新」 ----------------
  // `true`（默认）：进消息页立刻读档案秒开，同时在后台悄悄抓一次增量。
  // `false`：进消息页**只读档案、不联网**；只有该栏目档案为空时才兜底抓一次
  //         （否则全新安装的用户会面对一个空页面，且无从下手）。
  // ⚠️ 它管不到**下拉刷新** —— 那是用户的明确动作，任何时候都该真的联网。
  static const String _kMessageAutoRefresh = 'message_auto_refresh';
  static const bool kMessageAutoRefreshDefault = true;

  static Future<bool> loadMessageAutoRefresh() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kMessageAutoRefresh) ?? kMessageAutoRefreshDefault;
  }

  static Future<void> saveMessageAutoRefresh(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kMessageAutoRefresh, value);
  }
}
