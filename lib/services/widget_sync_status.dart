import 'package:shared_preferences/shared_preferences.dart';

/// 小组件「Flutter 侧同步」的结果快照（2026-11-03）。
///
/// ## 为什么需要它
///
/// 原生侧 [WidgetDiagnostics] 只能说清「原生读到了什么」，说不出
/// **「Dart 有没有跑、跑成功了没」**：
///
/// `WidgetSyncService.syncTodayCourses()` 的最外层是 `catch (_) {}`，
/// 而 `main()` 里又是「不 await 直接调用」。于是三种情况在原生侧
/// 完全长得一样（都是 `rawLength == 0`）：
///
///  1. 同步根本没被调用（比如某个入口提前 return）；
///  2. 调用了，但在 `loadTables()` / `jsonEncode` 阶段抛异常；
///  3. 写成功了，但写的是**别的课表**或**空课表**。
///
/// 这里把每次尝试的结果（时刻 / 是否成功 / 教学周 / 课程数 / 错误原文）
/// 落一份到本地，自检卡把它和原生快照并排显示，就能一眼定责：
///
///  · Dart 侧「从未同步」     → 是调用链没走到
///  · Dart 侧「失败 + 错误原文」→ 是代码抛了，按错误改
///  · Dart 侧「成功 N 门」而原生 `rawLength == 0` → 写入通道断了
///  · 两边都成功但组件是默认文字 → 是原生渲染抛异常（看原生 `lastError`）
class WidgetSyncStatus {
  static const String _kAt = 'widget_sync_at';
  static const String _kOk = 'widget_sync_ok';
  static const String _kWeek = 'widget_sync_week';
  static const String _kCount = 'widget_sync_count';
  static const String _kError = 'widget_sync_error';
  static const String _kTable = 'widget_sync_table';

  /// 记一次成功。
  static Future<void> recordSuccess({
    required int week,
    required int courseCount,
    required String tableName,
  }) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _kAt, DateTime.now().toIso8601String().substring(0, 19));
      await p.setBool(_kOk, true);
      await p.setInt(_kWeek, week);
      await p.setInt(_kCount, courseCount);
      await p.setString(_kTable, tableName);
      await p.remove(_kError);
    } catch (_) {
      // 自检写盘失败不能影响同步本身
    }
  }

  /// 记一次失败（含错误原文）。
  static Future<void> recordFailure(Object error, [StackTrace? st]) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _kAt, DateTime.now().toIso8601String().substring(0, 19));
      await p.setBool(_kOk, false);
      final detail = st == null ? '$error' : '$error @ ${_firstFrame(st)}';
      await p.setString(_kError, detail.length > 300
          ? '${detail.substring(0, 300)}…'
          : detail);
    } catch (_) {
      // 同上
    }
  }

  static const String _kInstances = 'widget_sync_instances';

  /// 记一次「原生真实更新到的桌面实例数」（2026-11-04）。
  ///
  /// 全 0 = 桌面上没有这些组件；有数据但全 0 = 数据对了、桌面没组件可更新。
  static Future<void> recordInstanceCounts(Map<String, int> counts) async {
    try {
      final p = await SharedPreferences.getInstance();
      final brief = counts.entries
          .where((e) => e.value > 0)
          .map((e) => '${e.key}=${e.value}')
          .join(' ');
      await p.setString(
          _kInstances, brief.isEmpty ? '全部为 0（桌面没有组件）' : brief);
    } catch (_) {
      // 自检写盘失败不能影响同步
    }
  }

  /// 读出来给自检卡用。
  static Future<WidgetSyncSnapshot> read() async {
    try {
      final p = await SharedPreferences.getInstance();
      return WidgetSyncSnapshot(
        at: p.getString(_kAt) ?? '',
        ok: p.getBool(_kOk),
        week: p.getInt(_kWeek) ?? 0,
        courseCount: p.getInt(_kCount) ?? 0,
        tableName: p.getString(_kTable) ?? '',
        error: p.getString(_kError) ?? '',
        instances: p.getString(_kInstances) ?? '',
      );
    } catch (_) {
      return const WidgetSyncSnapshot(
        at: '',
        ok: null,
        week: 0,
        courseCount: 0,
        tableName: '',
        error: '',
        instances: '',
      );
    }
  }

  static String _firstFrame(StackTrace st) {
    final line = st.toString().split('\n');
    for (final l in line) {
      final t = l.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('package:') || t.contains('.dart')) return t;
    }
    return line.isEmpty ? '' : line.first.trim();
  }
}

/// [WidgetSyncStatus.read] 的结果。
class WidgetSyncSnapshot {
  /// 上次同步时刻（`yyyy-MM-ddTHH:mm:ss`），空串表示从未同步过。
  final String at;

  /// null 表示还没记录过；true 成功；false 失败。
  final bool? ok;

  final int week;
  final int courseCount;
  final String tableName;

  /// 失败时的错误原文（含首个栈帧）。
  final String error;

  /// 上次同进程直调渲染时，原生交回的「真实更新到的实例数」摘要。
  /// 空串 = 还没跑过直调（老版本）；`全部为 0` = 桌面上没有组件。
  final String instances;

  const WidgetSyncSnapshot({
    required this.at,
    required this.ok,
    required this.week,
    required this.courseCount,
    required this.tableName,
    required this.error,
    this.instances = '',
  });

  bool get neverRan => at.isEmpty;

  /// 一句话结论，给自检卡直接用。
  String get verdict {
    if (neverRan) return 'App 还没有同步过课表（同步代码没被调用）。';
    if (ok == false) return '上次同步失败：$error';
    if (courseCount == 0) {
      return '上次同步成功，但这一周课表里没有课（第 $week 周 · $tableName）。';
    }
    return '上次同步成功：第 $week 周，$courseCount 门课（$tableName）。';
  }
}
