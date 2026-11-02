import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首页板块显隐（2026-10-16 新功能：**首页个性化设置**）。
///
/// 四个板块与用户点名的叫法一一对应：
///   · 信息栏         —— 「掌上锡院 / 日期 / Today」+ 时钟 + 校园网状态 + QQ 群
///   · 周次选择栏     —— 周导航（上一周 / 本周 / 下一周）+ 七天日期条
///   · 今日待办小卡片 —— 今日概览（今天几节课 / 待办完成数 / 最近考试倒计时）
///   · 待办事项       —— 「待办事项」标题（含右上角 + 号）+ 待办列表
///
/// 一律**默认显示**，设置页里给的是「隐藏」开关。
/// 改动**即时生效**：首页监听 [notifier] 重建，不用重启。
class HomePrefs {
  HomePrefs._();

  static const String _kHeader = 'home_show_header';
  static const String _kWeekStrip = 'home_show_week_strip';
  static const String _kOverview = 'home_show_overview';
  static const String _kTodos = 'home_show_todos';

  /// 四个板块 id（设置页与本文件共用，避免手打字符串写错）。
  static const String idHeader = 'header';
  static const String idWeekStrip = 'weekStrip';
  static const String idOverview = 'overview';
  static const String idTodos = 'todos';

  /// 四个板块当前是否**显示**（默认全显示）。
  static bool showHeader = true;
  static bool showWeekStrip = true;
  static bool showOverview = true;
  static bool showTodos = true;

  /// 变更通知：首页用 ValueListenableBuilder 监听它重建。
  static final ValueNotifier<int> notifier = ValueNotifier<int>(0);

  /// 首帧之前读完（在 `main()` 里 await）—— 否则启动会先按默认画一遍再跳，
  /// 隐藏掉的板块会肉眼可见地闪一下。与 [NavPrefs.ensureLoaded] 同一套路。
  static Future<void> ensureLoaded() async {
    final p = await SharedPreferences.getInstance();
    showHeader = p.getBool(_kHeader) ?? true;
    showWeekStrip = p.getBool(_kWeekStrip) ?? true;
    showOverview = p.getBool(_kOverview) ?? true;
    showTodos = p.getBool(_kTodos) ?? true;
    notifier.value++;
  }

  static bool isShown(String id) {
    if (id == idHeader) return showHeader;
    if (id == idWeekStrip) return showWeekStrip;
    if (id == idOverview) return showOverview;
    if (id == idTodos) return showTodos;
    return true;
  }

  /// 设置某板块是否显示（写盘 + 通知首页重建）。
  static Future<void> setShown(String id, bool shown) async {
    final p = await SharedPreferences.getInstance();
    if (id == idHeader) {
      showHeader = shown;
      await p.setBool(_kHeader, shown);
    } else if (id == idWeekStrip) {
      showWeekStrip = shown;
      await p.setBool(_kWeekStrip, shown);
    } else if (id == idOverview) {
      showOverview = shown;
      await p.setBool(_kOverview, shown);
    } else if (id == idTodos) {
      showTodos = shown;
      await p.setBool(_kTodos, shown);
    }
    notifier.value++;
  }
}
