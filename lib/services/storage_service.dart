import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
  static const String _kDisclaimerDismissed = 'disclaimer_dismissed';
  static const String _kJwglNoticeDismissed = 'jwgl_notice_dismissed';
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
      // 清除可能残留的明文密码，杜绝双重存储
      await prefs.remove(_kPassword);
      await prefs.remove(_kOldPassword);
    }

    return UserConfig(
      showdocUrl: showdoc,
      username: username,
      password: password,
      rememberPassword: remember,
      themeMode: _parseThemeMode(prefs.getString(_kThemeMode)),
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

  static ThemeMode _parseThemeMode(String? v) {
    switch (v) {
      case 'dark':
        return ThemeMode.dark;
      // 旧版本存过 'system'（跟随系统）；该选项已取消 → 迁移为浅色。
      case 'system':
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

  // ---- 免责声明与公告弹窗「不再提醒」持久化 ----

  static Future<bool> loadDisclaimerDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kDisclaimerDismissed) ?? false;
  }

  static Future<void> saveDisclaimerDismissed(bool dismissed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDisclaimerDismissed, dismissed);
  }


  /// 教务系统时段提示（温馨提示）是否已被用户选择「不再提醒」。
  static Future<bool> loadJwglNoticeDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kJwglNoticeDismissed) ?? false;
  }

  static Future<void> saveJwglNoticeDismissed(bool dismissed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kJwglNoticeDismissed, dismissed);
  }

  // ---- 服务页显示/隐藏（v1.9.0） ----

  /// 读取被隐藏的服务 id 列表。未设置返回空列表（= 全部显示）。
  static Future<List<String>> loadHiddenServices() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kHiddenServices) ?? <String>[];
  }

  /// 保存被隐藏的服务 id 列表。
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

  // ---------------- 消息页栏目样式（v1.1.0） ----------------
  // 两套样式随时可切：'plain' 纯白无缝（默认）/ 'card' 圆角盒子。
  static const String _kMessageStyle = 'message_style';
  static const String kMessageStylePlain = 'plain';
  static const String kMessageStyleCard = 'card';

  static Future<String> loadMessageStyle() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kMessageStyle) ?? kMessageStylePlain;
  }

  static Future<void> saveMessageStyle(String style) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMessageStyle, style);
  }
}
