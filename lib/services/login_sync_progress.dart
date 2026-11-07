import 'package:flutter/foundation.dart';

/// 登录成功之后那串「自动同步」的进度。
///
/// 为什么要有它：首次登录会一次性触发课表 / 成绩 / 考试 / 教材 / 一卡通
/// 五件事，以前全在后台静默跑，用户看到的是「点完登录，等了十几秒，
/// 课表突然换了」—— 像是 App 自己动了。现在把每一步摊开：
/// 一行一件事，从「同步中…」走到「同步成功」，用户看着它走完就不慌。
///
/// 设计约束：
/// · 只做**展示**，不改变任何同步语义（失败仍然静默跳过，不打断登录）；
/// · 全部状态放在一个 [ValueNotifier] 里，对话框 `ValueListenableBuilder` 直读，
///   不需要 setState 回调链；
/// · [reset] 在每次登录开始时调用，避免上一次的「成功」残留。
enum LoginSyncStep {
  /// 课表（走 CourseSyncService，可能带冲突）
  courses('课表', '同步课表'),

  /// 成绩
  grades('成绩', '同步成绩'),

  /// 考试
  exams('考试', '同步考试'),

  /// 教材
  textbooks('教材', '同步教材'),

  /// 一卡通余额
  card('一卡通', '同步余额'),

  /// 我的学业（培养方案 + 已修课程），登录时顺手抓一次
  study('学业', '同步学业'),

  /// 电费（宿舍已绑定时顺手查一次余额）
  elec('电费', '同步电费');

  const LoginSyncStep(this.title, this.action);

  final String title;
  final String action;
}

/// 单步状态。
enum LoginSyncStatus {
  /// 还没开始
  pending,

  /// 正在进行
  running,

  /// 成功
  done,

  /// 失败（界面写「同步失败」但不阻断）
  failed,
}

/// 单步的不可变快照。
@immutable
class LoginSyncItem {
  const LoginSyncItem({
    required this.step,
    this.status = LoginSyncStatus.pending,
    this.note,
  });

  final LoginSyncStep step;
  final LoginSyncStatus status;

  /// 附加说明，例如「12 门课」「无新数据」。
  final String? note;

  LoginSyncItem copyWith({LoginSyncStatus? status, String? note}) =>
      LoginSyncItem(
        step: step,
        status: status ?? this.status,
        note: note ?? this.note,
      );
}

/// 全局进度。对话框与同步逻辑通过它通信。
class LoginSyncProgress {
  LoginSyncProgress._();

  /// 整条流程的所有步骤（固定顺序 = 实际执行顺序）。
  static const List<LoginSyncStep> order = LoginSyncStep.values;

  static final ValueNotifier<List<LoginSyncItem>> notifier =
      ValueNotifier<List<LoginSyncItem>>(_blank());

  static List<LoginSyncItem> _blank() =>
      [for (final s in order) LoginSyncItem(step: s)];

  /// 这一轮是否真的在跑（对话框据此决定要不要自己关掉）。
  static bool get isRunning => notifier.value.any(
      (e) => e.status == LoginSyncStatus.running);

  static void reset() => notifier.value = _blank();

  /// 是否还有未完成的步骤。
  static bool get hasPending =>
      notifier.value.any((e) => e.status == LoginSyncStatus.pending);

  static void mark(LoginSyncStep step, LoginSyncStatus status, {String? note}) {
    notifier.value = [
      for (final it in notifier.value)
        it.step == step ? it.copyWith(status: status, note: note) : it,
    ];
  }

  static void done(LoginSyncStep step, {String? note}) =>
      mark(step, LoginSyncStatus.done, note: note);

  static void running(LoginSyncStep step) => mark(step, LoginSyncStatus.running);

  static void failed(LoginSyncStep step, {String? note}) =>
      mark(step, LoginSyncStatus.failed, note: note);

  /// 剩下的全部跳过（用于中途异常退出，避免界面永远停在「同步中…」）。
  static void skipRest({String? note}) {
    notifier.value = [
      for (final it in notifier.value)
        it.status == LoginSyncStatus.pending
            ? it.copyWith(status: LoginSyncStatus.failed, note: note)
            : it,
    ];
  }
}
