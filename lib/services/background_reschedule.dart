import 'package:flutter/widgets.dart';
import '../repositories/todo_repository.dart';
import 'course_reminder_service.dart';

/// 开机后由原生 BootReceiver 调起的无界面入口：重排所有未来的本地提醒。
/// v2.2.21：待办提醒 + 上课提醒（WakeUp 式本地精确闹钟）都在此补排。
///
/// 必须为顶层函数并用 @pragma('vm:entry-point') 标注，否则 release 包会被
/// tree-shake 掉，原生侧 executeDartEntrypoint 将找不到该入口。
///
/// 关键：必须 `await` 重排完成，否则后台隔离区可能在异步任务尚未落地前退出，
/// 导致开机后提醒漏排。
@pragma('vm:entry-point')
Future<void> notificationRescheduleEntrypoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  await TodoRepository.instance.rescheduleAll();
  await CourseReminderService.rescheduleAll();
}
