import 'package:shared_preferences/shared_preferences.dart';

/// 桌面小组件的个性化设置（v1.0.4）。
///
/// 数据流：本文件读写在 SharedPreferences（App 自己的偏好），
/// [toJson] 的结果会并进 [WidgetSyncService] 写给桌面小组件的 JSON 里，
/// 原生侧（TodayWidgetRenderer.kt）按这些字段决定外观与内容。
///
/// ⚠️ 字段名是 Dart ↔ Kotlin 的约定，改名字要**两边一起改**
///    （原生侧默认值见 WidgetModels.kt 的 WidgetPrefs）。
class WidgetPrefs {
  // ---------- 键名 ----------
  static const String kTableId = 'widget_table_id'; // '' = 跟随当前课表
  static const String kTheme = 'widget_theme'; // system | light | dark
  static const String kAccent = 'widget_accent'; // RRGGBB（不带 #）
  static const String kFontScale = 'widget_font_scale'; // 0.85 / 1.0 / 1.15
  static const String kShowTeacher = 'widget_show_teacher';
  static const String kShowClassroom = 'widget_show_classroom';
  static const String kShowTime = 'widget_show_time';
  static const String kShowWeek = 'widget_show_week';
  // v1.6.7：中号 / 大号**各自独立**的显示开关（此前三种尺寸共用同一组，
  // 中号关掉「老师」大号也跟着变 —— 用户反馈的 bug）。
  static const String kShowTeacherMedium = 'widget_show_teacher_medium';
  static const String kShowClassroomMedium = 'widget_show_classroom_medium';
  static const String kShowTimeMedium = 'widget_show_time_medium';
  static const String kShowTeacherLarge = 'widget_show_teacher_large';
  static const String kShowClassroomLarge = 'widget_show_classroom_large';
  static const String kShowTimeLarge = 'widget_show_time_large';
  static const String kCountdown = 'widget_countdown';

  // ---------- 默认值 ----------
  static const String defTableId = '';
  static const String defTheme = 'system';
  static const String defAccent = '1F2937'; // 与 App 主题色默认一致
  static const double defFontScale = 1.0;

  /// 可选主题色（与设置页的色块一一对应）。
  static const List<String> accentChoices = [
    '1F2937', // 墨黑（默认）
    '3B82F6', // 蓝
    '10B981', // 绿
    'F59E0B', // 橙
    '8B5CF6', // 紫
    'EC4899', // 粉
  ];

  /// 字号档位（倍数）。
  static const List<double> fontScaleChoices = [0.85, 1.0, 1.15];

  static Future<SharedPreferences> get _p => SharedPreferences.getInstance();

  // ---------- 读 ----------
  static Future<String> tableId() async => (await _p).getString(kTableId) ?? defTableId;
  static Future<String> theme() async => (await _p).getString(kTheme) ?? defTheme;
  static Future<String> accent() async => (await _p).getString(kAccent) ?? defAccent;
  static Future<double> fontScale() async =>
      (await _p).getDouble(kFontScale) ?? defFontScale;

  static Future<bool> showTeacher() async =>
      (await _p).getBool(kShowTeacher) ?? true;
  static Future<bool> showClassroom() async =>
      (await _p).getBool(kShowClassroom) ?? true;
  static Future<bool> showTime() async => (await _p).getBool(kShowTime) ?? true;
  static Future<bool> showWeek() async => (await _p).getBool(kShowWeek) ?? true;

  // ---- 中号 / 大号各自的开关（v1.6.7）----
  static Future<bool> showTeacherMedium() async =>
      (await _p).getBool(kShowTeacherMedium) ?? await showTeacher();
  static Future<bool> showClassroomMedium() async =>
      (await _p).getBool(kShowClassroomMedium) ?? await showClassroom();
  static Future<bool> showTimeMedium() async =>
      (await _p).getBool(kShowTimeMedium) ?? await showTime();
  static Future<bool> showTeacherLarge() async =>
      (await _p).getBool(kShowTeacherLarge) ?? await showTeacher();
  static Future<bool> showClassroomLarge() async =>
      (await _p).getBool(kShowClassroomLarge) ?? await showClassroom();
  static Future<bool> showTimeLarge() async =>
      (await _p).getBool(kShowTimeLarge) ?? await showTime();
  static Future<bool> countdown() async => (await _p).getBool(kCountdown) ?? true;

  // ---------- 写 ----------
  static Future<void> setTableId(String v) async =>
      (await _p).setString(kTableId, v);
  static Future<void> setTheme(String v) async => (await _p).setString(kTheme, v);
  static Future<void> setAccent(String v) async =>
      (await _p).setString(kAccent, v);
  static Future<void> setFontScale(double v) async =>
      (await _p).setDouble(kFontScale, v);

  static Future<void> setShowTeacher(bool v) async =>
      (await _p).setBool(kShowTeacher, v);
  static Future<void> setShowClassroom(bool v) async =>
      (await _p).setBool(kShowClassroom, v);
  static Future<void> setShowTime(bool v) async =>
      (await _p).setBool(kShowTime, v);
  static Future<void> setShowTeacherMedium(bool v) async =>
      (await _p).setBool(kShowTeacherMedium, v);
  static Future<void> setShowClassroomMedium(bool v) async =>
      (await _p).setBool(kShowClassroomMedium, v);
  static Future<void> setShowTimeMedium(bool v) async =>
      (await _p).setBool(kShowTimeMedium, v);
  static Future<void> setShowTeacherLarge(bool v) async =>
      (await _p).setBool(kShowTeacherLarge, v);
  static Future<void> setShowClassroomLarge(bool v) async =>
      (await _p).setBool(kShowClassroomLarge, v);
  static Future<void> setShowTimeLarge(bool v) async =>
      (await _p).setBool(kShowTimeLarge, v);

  static Future<void> setShowWeek(bool v) async =>
      (await _p).setBool(kShowWeek, v);
  static Future<void> setCountdown(bool v) async =>
      (await _p).setBool(kCountdown, v);

  /// 打包给原生侧（键名与 WidgetModels.kt 的 WidgetPrefs 一一对应）。
  static Future<Map<String, dynamic>> toJson() async {
    final p = await _p;
    return {
      'tableId': p.getString(kTableId) ?? defTableId,
      'theme': p.getString(kTheme) ?? defTheme,
      'accent': p.getString(kAccent) ?? defAccent,
      'fontScale': p.getDouble(kFontScale) ?? defFontScale,
      'showTeacher': p.getBool(kShowTeacher) ?? true,
      'showClassroom': p.getBool(kShowClassroom) ?? true,
      'showTime': p.getBool(kShowTime) ?? true,
      'showWeek': p.getBool(kShowWeek) ?? true,
      'countdown': p.getBool(kCountdown) ?? true,
      // v1.6.7：中/大号各自开关（缺失时原生侧会回落到全局旧值）
      'showTeacherMedium': p.getBool(kShowTeacherMedium) ??
          p.getBool(kShowTeacher) ?? true,
      'showClassroomMedium': p.getBool(kShowClassroomMedium) ??
          p.getBool(kShowClassroom) ?? true,
      'showTimeMedium': p.getBool(kShowTimeMedium) ?? p.getBool(kShowTime) ?? true,
      'showTeacherLarge': p.getBool(kShowTeacherLarge) ??
          p.getBool(kShowTeacher) ?? true,
      'showClassroomLarge': p.getBool(kShowClassroomLarge) ??
          p.getBool(kShowClassroom) ?? true,
      'showTimeLarge': p.getBool(kShowTimeLarge) ?? p.getBool(kShowTime) ?? true,
    };
  }
}
