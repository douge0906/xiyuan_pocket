import 'package:flutter/services.dart';

/// 小组件自检结果（原生侧读到的真实状态）。
///
/// 2026-11-03 新增。用户反馈「小组件取不到数据」，但这条链路上**三层静默**：
///  · Dart `WidgetSyncService.syncTodayCourses()` 外层 `catch (_) {}`；
///  · 原生 `WidgetDataStore.read()` 解析失败 `catch { null }`；
///  · 原生 `TodayWidgetProvider.onUpdate` 外层 `catch (_: Throwable) {}`。
///
/// 叠加之后，「JSON 没写进去」「写进去了但解析失败」「数据正常只是今天没课」
/// 三件事在用户眼里完全一样 —— 都是「没数据」。所以这里补一条可核对的通道：
/// 把原生侧此刻读到的原始字符串长度、解析出的课程数、最后一次错误原样取回来。
class WidgetDiagnostics {
  static const MethodChannel _channel = MethodChannel('wxxy/widget_status');

  static bool _broken = false;

  /// 读取自检快照。取不到时返回 null（老安装包没有这个分支）。
  static Future<WidgetDiagnosticsSnapshot?> read() async {
    if (_broken) return null;
    try {
      final map = await _channel
          .invokeMapMethod<String, Object?>('diagnose');
      if (map == null) return null;
      return WidgetDiagnosticsSnapshot.fromMap(map);
    } on MissingPluginException {
      // 老安装包 / 非 Android：静默降级，不当成错误
      _broken = true;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 清空历史错误记录。
  static Future<void> clear() async {
    if (_broken) return;
    try {
      await _channel.invokeMethod<bool>('clearDiagnostics');
    } catch (_) {
      // 忽略
    }
  }
}

/// 自检快照。字段与原生 `WidgetDiagnostics.snapshot()` 一一对应。
class WidgetDiagnosticsSnapshot {
  /// 原生此刻是否解析出了数据。
  final bool hasData;

  /// 数据里的日期（yyyy-MM-dd）。
  final String date;

  /// 解析出的课程条数。
  final int courseCount;

  /// `HomeWidgetPreferences` 里原始字符串的长度。
  /// **0 表示 Dart 侧从来没写进来过** —— 这是区分「没写入」与「写入但解析失败」的关键。
  final int rawLength;

  /// 原始字符串前 160 字符（便于肉眼确认结构）。
  final String rawHead;

  /// 读取过程抛的异常（正常为 null）。
  final String? readError;

  /// 最后一次渲染失败的位置与原因。
  final String lastError;

  /// 最后一次成功读取的记录。
  final String lastRead;

  /// 最后一次「系统调到了我们」的记录（2026-11-03 新增）。
  ///
  /// 与 [lastRead] 的区别很关键：
  ///  · 本字段有值、但 `数据字节` 为 0 → 系统确实来调了，是 Dart 没写进去；
  ///  · 本字段为空 → Provider 的 `onUpdate` / `onEnabled` / 闹钟 `onReceive`
  ///    一次都没被触发过（组件没注册、广播没到、或系统根本没唤我们）。
  final String lastTick;

  /// 最后一次渲染时间（毫秒时间戳，0 表示从未）。
  final int lastRenderAt;

  final bool smallInstalled;
  final bool mediumInstalled;
  final bool largeInstalled;

  /// 是否具备精确闹钟权限。
  final bool exactAlarm;

  /// 每次渲染里 `updateAppWidget` 实际调通的条数，`"N/M"` 形式（M 个实例）。
  ///
  /// 空串 = 还没跑过任何一次渲染。2026-11-04 晚新增：
  /// 「桌面上有组件」(`installedCount > 0`) 和「渲染结果真的交出去了」是两件事，
  /// 之前自检页只有前者，两种失败在用户眼里一样，只能靠这一层分开。
  final String appliedSmall;
  final String appliedMedium;
  final String appliedLarge;

  /// 2026-11-05：信息型三组件也留同样的证据（原来只记课表三档，
  /// 所以「考试 / 校园卡 / 倒数日停在默认文字」时自检页一片空白）。
  final String appliedExam;
  final String appliedCard;
  final String appliedCountdown;

  const WidgetDiagnosticsSnapshot({
    required this.hasData,
    required this.date,
    required this.courseCount,
    required this.rawLength,
    required this.rawHead,
    required this.readError,
    required this.lastError,
    required this.lastRead,
    required this.lastTick,
    required this.lastRenderAt,
    required this.smallInstalled,
    required this.mediumInstalled,
    required this.largeInstalled,
    required this.exactAlarm,
    this.appliedSmall = '',
    this.appliedMedium = '',
    this.appliedLarge = '',
    this.appliedExam = '',
    this.appliedCard = '',
    this.appliedCountdown = '',
  });

  factory WidgetDiagnosticsSnapshot.fromMap(Map<String, Object?> m) {
    int asInt(Object? v) => (v is num) ? v.toInt() : 0;
    bool asBool(Object? v) => v == true;
    String asStr(Object? v) => v?.toString() ?? '';
    return WidgetDiagnosticsSnapshot(
      hasData: asBool(m['hasData']),
      date: asStr(m['date']),
      courseCount: asInt(m['courseCount']),
      rawLength: asInt(m['rawLength']),
      rawHead: asStr(m['rawHead']),
      readError: (m['readError'] as String?)?.trim().isEmpty ?? true
          ? null
          : (m['readError'] as String?),
      lastError: asStr(m['lastError']),
      lastRead: asStr(m['lastRead']),
      lastTick: asStr(m['lastTick']),
      lastRenderAt: asInt(m['lastRenderAt']),
      smallInstalled: asBool(m['smallInstalled']),
      mediumInstalled: asBool(m['mediumInstalled']),
      largeInstalled: asBool(m['largeInstalled']),
      exactAlarm: asBool(m['exactAlarm']),
      appliedSmall: asStr(m['appliedSmall']),
      appliedMedium: asStr(m['appliedMedium']),
      appliedLarge: asStr(m['appliedLarge']),
      appliedExam: asStr(m['appliedExam']),
      appliedCard: asStr(m['appliedCard']),
      appliedCountdown: asStr(m['appliedCountdown']),
    );
  }

  /// 装了任意一个课表组件。
  bool get anyInstalled => smallInstalled || mediumInstalled || largeInstalled;

  /// 已装的课表组件实例总数。
  int get installedCount =>
      (smallInstalled ? 1 : 0) + (mediumInstalled ? 1 : 0) + (largeInstalled ? 1 : 0);

  /// 三档的「调通条数」拼成一行给自检页显示，例如 `小 1/1 · 中 1/1`。
  ///
  /// 只列出真的装了的那几档 —— 没装的档位空串没有信息量。
  String get appliedSummary {
    final parts = <String>[];
    if (smallInstalled) parts.add('小 ${appliedSmall.isEmpty ? '—' : appliedSmall}');
    if (mediumInstalled) parts.add('中 ${appliedMedium.isEmpty ? '—' : appliedMedium}');
    if (largeInstalled) parts.add('大 ${appliedLarge.isEmpty ? '—' : appliedLarge}');
    if (appliedExam.isNotEmpty) parts.add('考试 $appliedExam');
    if (appliedCard.isNotEmpty) parts.add('卡 $appliedCard');
    if (appliedCountdown.isNotEmpty) parts.add('倒数 $appliedCountdown');
    return parts.join(' · ');
  }

  /// 有实例、但一次都没调通过（`0/M`）。
  ///
  /// 这是「渲染整份被丢」的判据：`updateAppWidget` 不抛异常，但 launcher 侧
  /// 把 RemoteViews 整个丢掉了 —— 桌面停在 `initialLayout` 的默认文字上。
  bool get appliedNone {
    bool zero(String s, bool installed) {
      if (!installed || s.isEmpty) return false;
      return s.startsWith('0/');
    }

    return zero(appliedSmall, smallInstalled) ||
        zero(appliedMedium, mediumInstalled) ||
        zero(appliedLarge, largeInstalled);
  }

  /// 一句话结论（直接给用户看）。
  ///
  /// 判定顺序刻意从「最底层的原因」往上传：先看有没有写入，
  /// 再看能不能解析，最后才看「今天是否真的有课」。
  String get verdict {
    if (!anyInstalled) {
      return '还没有把小组件添加到桌面，添加后这里才会显示数据。';
    }
    if (rawLength == 0 && lastTick.isEmpty) {
      return '系统一次都没有刷新过组件（桌面上的组件可能已被移除，或被系统的省电策略完全冻结）。'
          '试着先删掉桌面上的组件再重新添加一次。';
    }
    if (rawLength == 0) {
      return 'App 还没有把课表写给小组件。请先打开一次课表页，再回来看。';
    }
    if (readError != null) {
      return '小组件读取数据时出错：$readError';
    }
    if (!hasData) {
      return '数据已写入（$rawLength 字节），但小组件解析失败。这是一条缺陷，请把下面的原始数据反馈给我们。';
    }
    if (appliedNone) {
      return '数据正常（$courseCount 门课），但系统把这次渲染整份丢了 —— '
          '桌面会停在组件自带的默认文字上。删掉桌面上的组件再重新添加一次通常能恢复。';
    }
    if (courseCount == 0) {
      return '数据正常，今天这门课表里没有课。';
    }
    return '正常：读到 $courseCount 门课（$date）。';
  }

  /// 是否处于「有问题」状态（用于标红）。
  bool get isProblem =>
      anyInstalled && (rawLength == 0 || readError != null || !hasData);
}
