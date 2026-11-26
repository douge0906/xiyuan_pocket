import 'package:shared_preferences/shared_preferences.dart';

/// 课表功能在**本机**记的一点小状态。
///
/// 为什么不放服务端：上传者名称是「这个人上次交作业时自称什么」，
/// 换手机就该重新想一个；而且服务端只该存那份上传记录的名字，
/// 不该维护一张「我的昵称」表 —— 那就变成账号体系了。
class TimetablePrefs {
  TimetablePrefs._();

  static const String _kUploader = 'timetable_uploader_name';

  /// 上次上传时填的上传者名称。没有就返回空串（不是 null，省得调用方到处判空）。
  static Future<String> loadUploaderName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getString(_kUploader) ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  static Future<void> saveUploaderName(String name) async {
    final v = name.trim();
    if (v.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUploader, v);
    } catch (_) {
      // 记不住名字不影响上传，静默失败。
    }
  }
}
