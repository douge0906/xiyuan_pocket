import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用语言（中文 / 英文）。
///
/// 刻意**不依赖 flutter_localizations**：只翻译我们自己写的文案，
/// Material 自带文案保持系统默认，避免「半中半英」的割裂感。
enum AppLanguage {
  zh('zh', '中文'),
  en('en', 'English');

  const AppLanguage(this.code, this.label);
  final String code;
  final String label;
}

/// 语言状态：切换后立即生效（监听 [notifier] 重建）。
class AppLocale {
  AppLocale._();

  static const String _kKey = 'ui_language';

  static AppLanguage current = AppLanguage.zh;
  static final ValueNotifier<int> notifier = ValueNotifier<int>(0);

  static Future<void> ensureLoaded() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_kKey);
    current = AppLanguage.values.firstWhere(
      (l) => l.code == code,
      orElse: () => AppLanguage.zh,
    );
  }

  static Future<void> setLanguage(AppLanguage l) async {
    if (current == l) return;
    current = l;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, l.code);
    notifier.value++;
  }

  /// 取当前语言的文案（key 缺失时返回 key 本身，便于排查）。
  static String t(String key) => strings[current]?[key] ?? key;

  /// 应用文案表（仅收录**我们自己写**的界面文案）。
  ///
  /// 中英两份**键必须完全一致**（自检脚本会校验），缺一个键就会回退成 key 本身。
  static const Map<AppLanguage, Map<String, String>> strings = {
    AppLanguage.zh: {
      'nav_home': '首页',
      'nav_message': '消息',
      'nav_course': '课表',
      'nav_service': '服务',
      'nav_user': '用户',
      'app_name': '掌上锡院',
      'sec_general': '通用',
      'sec_function': '功能',
      'sec_help': '帮助与反馈',
      // ---- v1.0.9 设置页信息架构重排新增 ----
      'set_title': '设置',
      'sec_notify': '通知与提醒',
      'sec_display': '界面与显示',
      'sec_data': '数据与存储',
      'item_course_reminder': '课程提醒',
      'item_message': '消息设置',
      'item_appearance': '外观与个性化',
      'item_course_style': '课表个性化',
      'item_service_manager': '服务管理',
      'item_clear_cache': '清理缓存',
      'item_clear_all': '清除所有数据与登录状态',
      'item_check_update': '检查更新',
      'set_general': '通用设置',
      'set_font': '字体',
      'set_font_size': '字号',
      'set_haptic': '振动强度',
      'set_language': '语言',
      'cancel': '取消',
      'clear': '清除',
      'confirm_logout': '退出',
      'item_notifications': '通知提醒',
      'item_display': '界面与显示',
      'item_feedback': '意见反馈',
      'item_privacy': '隐私政策',
      'item_terms': '用户协议',
      'item_contact': '联系 / 投诉邮箱',
      'item_clear': '清除本机数据',
      'item_logout': '退出登录',
      'item_general_all': '全部设置',
      'display_theme': '主题色',
      'display_nav': '底部导航',
      'display_home': '首页个性化',
      'display_font': '字体大小',
      'display_lang': '语言',
      'display_motion': '动效强度',
      'display_haptic': '振动反馈',
      'display_preview': '预览：今天的课程在 08:00 开始',
      'display_title': '外观与个性化',
      'display_mode': '明暗模式',
      'display_bg': '背景色',
      'display_radius': '圆角',
      'display_font_preview': '预览：今天的课程在 08:00 开始',
      'display_font_preview2': '待办完成 3/5 · 概率统计 5 天后',
      'light': '浅色',
      'dark': '深色',
      'system': '跟随系统',
      'small': '小',
      'standard': '标准',
      'large': '大',
      'off': '关闭',
      'full': '完整',
      'notif_title': '通知提醒',
      'notif_sub': '通知权限、精确闹钟、电池优化、自启动一站搞定',
      'notif_perm': '通知权限',
      'notif_perm_desc': 'Android 13 及以上需要单独授权，否则所有提醒都不会弹出。',
      'notif_exact': '精确闹钟（闹钟和提醒）',
      'notif_exact_desc': '没有它时提醒会降级为「大致时间」，可能晚十几分钟甚至不响。',
      'notif_battery': '关闭电池优化',
      'notif_battery_desc':
          '系统省电会杀掉后台闹钟。在应用详情页里找到「电池优化」，选择「不受限制」即可。',
      'notif_bg': '后台运行 / 自启动',
      'notif_bg_desc':
          '小米、华为、OPPO、vivo 等需在「应用管理」里允许自启动与后台运行，否则进程会被清掉。',
      'notif_channel': '通知渠道',
      'notif_channel_desc': '「上课提醒」「待办提醒」两个渠道可分别设为重要，并单独开启震动。',
      'notif_check': '提醒自检',
      'notif_test': '发送一条测试提醒',
      'granted': '已开启',
      'not_granted': '未开启',
      'authorized': '已授权',
      'not_authorized': '未授权',
      'need_manual': '需手动确认',
      'to_system': '去系统调整',
      'normal': '正常',
      'not_queued': '未排入',
      'greeting_morning': '早上好',
      'greeting_noon': '中午好',
      'greeting_evening': '晚上好',
      'greeting_late': '夜深了',
    },
    AppLanguage.en: {
      'nav_home': 'Home',
      'nav_message': 'Inbox',
      'nav_course': 'Timetable',
      'nav_service': 'Tools',
      'nav_user': 'Me',
      'app_name': 'Wuxi Toolbox',
      'sec_general': 'General',
      'sec_function': 'Features',
      'sec_help': 'Help & Feedback',
      // ---- v1.0.9 Settings IA rebuild ----
      'set_title': 'Settings',
      'sec_notify': 'Notifications',
      'sec_display': 'Interface & Display',
      'sec_data': 'Data & Storage',
      'item_course_reminder': 'Class Reminders',
      'item_message': 'Message Settings',
      'item_appearance': 'Appearance',
      'item_course_style': 'Timetable Style',
      'item_service_manager': 'Manage Services',
      'item_clear_cache': 'Clear Cache',
      'item_clear_all': 'Clear All Data & Sign Out',
      'item_check_update': 'Check for Updates',
      'set_general': 'General',
      'set_font': 'Font',
      'set_font_size': 'Font Size',
      'set_haptic': 'Vibration',
      'set_language': 'Language',
      'cancel': 'Cancel',
      'clear': 'Clear',
      'confirm_logout': 'Log Out',
      'item_notifications': 'Notifications',
      'item_display': 'Display',
      'item_feedback': 'Feedback',
      'item_privacy': 'Privacy Policy',
      'item_terms': 'Terms of Use',
      'item_contact': 'Contact / Report',
      'item_clear': 'Clear Local Data',
      'item_logout': 'Log Out',
      'item_general_all': 'All Settings',
      'display_theme': 'Accent Color',
      'display_nav': 'Bottom Navigation',
      'display_home': 'Home Layout',
      'display_font': 'Font Size',
      'display_lang': 'Language',
      'display_motion': 'Motion',
      'display_haptic': 'Haptics',
      'display_preview': 'Preview: today\'s class starts at 08:00',
      'display_title': 'Appearance',
      'display_mode': 'Theme Mode',
      'display_bg': 'Background',
      'display_radius': 'Corner Radius',
      'display_font_preview': 'Preview: today\'s class starts at 08:00',
      'display_font_preview2': 'Tasks 3/5 · Calculus exam in 5 days',
      'light': 'Light',
      'dark': 'Dark',
      'system': 'System',
      'small': 'Small',
      'standard': 'Standard',
      'large': 'Large',
      'off': 'Off',
      'full': 'Full',
      'notif_title': 'Notifications',
      'notif_sub': 'Permission, exact alarm, battery, auto-start',
      'notif_perm': 'Notification Permission',
      'notif_perm_desc':
          'Android 13+ needs an explicit grant, otherwise nothing pops up.',
      'notif_exact': 'Exact Alarms',
      'notif_exact_desc':
          'Without it, reminders may be delayed by 10+ minutes or not at all.',
      'notif_battery': 'Disable Battery Optimisation',
      'notif_battery_desc':
          'Find "Battery optimisation" in app details and choose "Unrestricted".',
      'notif_bg': 'Background / Auto-start',
      'notif_bg_desc':
          'On Xiaomi, Huawei, OPPO, vivo: allow auto-start and background running.',
      'notif_channel': 'Notification Channels',
      'notif_channel_desc':
          'Set "Class reminder" and "Task reminder" as important separately.',
      'notif_check': 'Diagnostics',
      'notif_test': 'Send a Test Reminder',
      'granted': 'Granted',
      'not_granted': 'Not Granted',
      'authorized': 'Allowed',
      'not_authorized': 'Not Allowed',
      'need_manual': 'Check Manually',
      'to_system': 'Open Settings',
      'normal': 'Normal',
      'not_queued': 'Not Queued',
      'greeting_morning': 'Good morning',
      'greeting_noon': 'Good afternoon',
      'greeting_evening': 'Good evening',
      'greeting_late': 'It\'s late',
    },
  };

}

/// 便捷别名：写文案时用 `S.t('key')`。
class S {
  S._();
  static String t(String key) => AppLocale.t(key);
}
