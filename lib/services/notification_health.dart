import 'package:flutter/foundation.dart';

/// 通知排程的**最近一次真实结果**（2026-11-02）。
///
/// ## 为什么需要它
///
/// 「通知不到位」这个反馈最难查的地方是：**失败是完全静默的**。
/// `NotificationService.schedule()` 内部有三级降级
/// （exactAllowWhileIdle → alarmClock → inexactAllowWhileIdle），
/// 三级全失败时只 `debugPrint` 一行，release 包里连日志都看不到。
///
/// 于是用户看到「待办列表里明明写着 18:30 提醒」，到点没响，
/// 而 App 自己「以为」排上了 —— 因为那个 bool 从来没人看。
///
/// 这个类把最近一次全量重排的结果留在内存里，供：
///   - 「提醒设置」页显示「已排上 N 条 / 失败 M 条」；
///   - 「通知自检」把失败原因归到正确的层。
class NotificationHealth {
  NotificationHealth._();
  static final NotificationHealth instance = NotificationHealth._();

  /// 最近一次全量重排成功排上的条数。
  int scheduled = 0;

  /// 最近一次全量重排中「本该排上但失败了」的条数。
  int failed = 0;

  /// 是否已经跑过一次全量重排（区分「0 条」和「还没跑」）。
  bool ran = false;

  void report({required int scheduled, required int failed}) {
    this.scheduled = scheduled;
    this.failed = failed;
    ran = true;
  }

  /// 给用户看的一句话结论（设置页/自检用）。
  String get summary {
    if (!ran) return '还没做过全量重排';
    if (failed > 0) {
      return '已排上 $scheduled 条，另有 $failed 条排程失败'
          '（系统拒绝了全部排程模式，多半是「闹钟和提醒」权限被关）';
    }
    return '已排上 $scheduled 条提醒';
  }

  @visibleForTesting
  void reset() {
    scheduled = 0;
    failed = 0;
    ran = false;
  }
}
