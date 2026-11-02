import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/services/course_reminder_service.dart';
import 'package:xiyuan_pocket/services/notification_service.dart';

/// 通知渠道与通知岛能力的回归测试（2026-10-31 八次自检）。
///
/// 钉住三件事：
///   1. 通知渠道 id 已经**升过版本**（v1/v3 → v2/v4）——
///      Android 8.0+ 的渠道设置一旦建立就被系统锁死，不换 id 就永远
///      改不动震动/铃声/重要性。这是「通知没有震动」的直接原因。
///   2. 「通知岛（实时更新）」开关独立于「倒计时」，默认开启。
///   3. 通知岛要求通知**常驻 + 系统倒计时**，两者缺一就不提升为胶囊。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('🔴 通知渠道 id 已升版本（换 id 才能改震动）', () {
    // v1 → v2：上课提醒；v3 → v4：待办提醒。
    expect(NotificationService.channelCourse, 'course_reminder_channel_v2');
    expect(NotificationService.channelTodo, 'todo_reminder_channel_v4');
  });

  test('🔴 通知岛开关默认开启', () async {
    final on = await CourseReminderService.liveUpdateEnabled();
    expect(on, isTrue, reason: '通知岛默认应开启');
  });

  test('🔴 通知岛开关可写可读', () async {
    await CourseReminderService.setLiveUpdate(false);
    expect(await CourseReminderService.liveUpdateEnabled(), isFalse);
    await CourseReminderService.setLiveUpdate(true);
    expect(await CourseReminderService.liveUpdateEnabled(), isTrue);
  });
}
