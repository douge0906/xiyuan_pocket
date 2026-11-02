import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/todo.dart';
import 'package:xiyuan_pocket/repositories/todo_repository.dart';
import 'package:xiyuan_pocket/services/notification_service.dart';

/// 优先级 ↔ 振动强度、提前提醒的回归测试（2026-10-31）。
///
/// 钉住三件事：
///   1. **优先级必须映射到不同通知渠道** —— Android 8.0+ 的振动模式
///      由渠道决定，单条通知的 `setVibrate` 不生效；
///   2. 不同优先级的振动模式**强度不同**（普通 < 重要 < 紧急）；
///   3. 提前提醒分钟数能持久化并正确参与「完成态/通知」判定。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('🔴 优先级映射到不同渠道', () {
    final normal = NotificationService.channelForPriority(0);
    final important = NotificationService.channelForPriority(1);
    final urgent = NotificationService.channelForPriority(2);
    expect(normal, isNot(important));
    expect(important, isNot(urgent));
    expect(normal, isNot(urgent));
  });

  test('🔴 优先级越紧急，振动总时长越长', () {
    int total(List<int> p) => p.fold(0, (a, b) => a + b);
    final normal = NotificationService.vibrationForPriority(0);
    final important = NotificationService.vibrationForPriority(1);
    final urgent = NotificationService.vibrationForPriority(2);
    expect(total(normal), lessThan(total(important)));
    expect(total(important), lessThan(total(urgent)));
  });

  test('🔴 优先级渠道 id 带版本后缀（振动不可变，需换 id）', () {
    // 渠道设置一旦创建就被系统锁死，改振动强度只能换 id。
    for (final ch in [
      NotificationService.channelTodoNormal,
      NotificationService.channelTodoImportant,
      NotificationService.channelTodoUrgent,
    ]) {
      expect(ch, matches(RegExp(r'_v\d+$')), reason: '$ch 应带版本后缀');
    }
  });

  test('🔴 提前提醒分钟数可持久化', () async {
    final t = Todo(
      id: 'x1',
      title: '交作业',
      date: DateTime(2026, 11, 1, 15, 30),
      dueAt: DateTime(2026, 11, 1, 15, 30),
      reminderTime: DateTime(2026, 11, 1, 15, 20),
      remindLeadMinutes: 10,
    );
    await TodoRepository.instance.add(t);
    final all = await TodoRepository.instance.getAll();
    expect(all.first.remindLeadMinutes, 10);
  });

  test('🔴 历史数据没有该字段时默认准点', () {
    final t = Todo.fromJson(const {
      'id': 'x2',
      'title': '老数据',
      'date': '2026-11-01T00:00:00.000',
    });
    expect(t.remindLeadMinutes, 0);
  });

  test('🔴 脏数据（负数/超大）被夹到合法范围', () {
    final neg = Todo.fromJson(const {
      'id': 'x3',
      'title': '脏',
      'date': '2026-11-01T00:00:00.000',
      'remindLeadMinutes': -5,
    });
    expect(neg.remindLeadMinutes, 0);

    final big = Todo.fromJson(const {
      'id': 'x4',
      'title': '脏',
      'date': '2026-11-01T00:00:00.000',
      'remindLeadMinutes': 99999,
    });
    expect(big.remindLeadMinutes, lessThanOrEqualTo(24 * 60));
  });

  test('🔴 copyWith 能改提前量', () {
    final t = Todo(
      id: 'x5',
      title: 't',
      date: DateTime(2026, 11, 1),
    );
    expect(t.copyWith(remindLeadMinutes: 30).remindLeadMinutes, 30);
  });
}
