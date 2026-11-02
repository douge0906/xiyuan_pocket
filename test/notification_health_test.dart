import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/notification_health.dart';

/// 通知健康度快照 —— 把「到底排上了几条」这件以前完全不可见的事锁成测试。
///
/// 2026-11-02 之前 `TodoRepository.rescheduleAll()` 返回 void，
/// 三级降级链（exactAllowWhileIdle → alarmClock → inexact）全失败时
/// 整个 App 没有任何一处知道，用户只能靠「到点看它响不响」盲试。
void main() {
  setUp(() => NotificationHealth.instance.reset());
  tearDownAll(() => NotificationHealth.instance.reset());

  test('还没跑过全量重排时不能谎报「已排上 0 条」', () {
    expect(NotificationHealth.instance.ran, isFalse);
    expect(NotificationHealth.instance.summary, contains('还没做'));
    // 必须明确说「没跑过」而不是「排上 0 条」——前者可行动，后者像结论。
    expect(NotificationHealth.instance.summary, isNot(contains('已排上')));
  });

  test('全部排上时给出成功结论', () {
    NotificationHealth.instance.report(scheduled: 8, failed: 0);
    expect(NotificationHealth.instance.ran, isTrue);
    expect(NotificationHealth.instance.scheduled, 8);
    expect(NotificationHealth.instance.failed, 0);
    expect(NotificationHealth.instance.summary, contains('8'));
    expect(NotificationHealth.instance.summary, isNot(contains('失败')));
  });

  test('🔴 有失败时必须点名「闹钟和提醒」权限，否则用户无从下手', () {
    NotificationHealth.instance.report(scheduled: 3, failed: 5);
    final s = NotificationHealth.instance.summary;
    expect(s, contains('3'));
    expect(s, contains('5'));
    expect(s, contains('闹钟和提醒'));
  });

  test('全部失败（scheduled=0）也要说得清楚', () {
    NotificationHealth.instance.report(scheduled: 0, failed: 4);
    final s = NotificationHealth.instance.summary;
    expect(s, contains('0'));
    expect(s, contains('4'));
    expect(s, contains('失败'));
  });

  test('重排一次之后再重排，结果必须被覆盖而不是累加', () {
    NotificationHealth.instance.report(scheduled: 9, failed: 1);
    NotificationHealth.instance.report(scheduled: 2, failed: 0);
    expect(NotificationHealth.instance.scheduled, 2);
    expect(NotificationHealth.instance.failed, 0);
    expect(NotificationHealth.instance.summary, isNot(contains('失败')));
  });
}
