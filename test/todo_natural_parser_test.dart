import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/services/todo_natural_parser.dart';

/// 待办自然语言解析测试（2026-10-31）。
///
/// 这套解析现在被**两处**共用：
///   · 手打输入（[AddTodoDialog] 的标题框）
///   · 语音输入（长按「＋」→ 语言球 → 识别结果）
///
/// 所以它必须稳定 —— 语音识别出来的文本质量参差，
/// 解析器要能从「明天下午3点交高数作业」这类口语里稳稳取出时间。
void main() {
  DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  test('🔴 解析「今天」', () {
    final r = TodoNaturalParser.parse('今天交高数作业');
    expect(r.day, today());
    expect(r.clean, '交高数作业');
  });

  test('🔴 解析「明天」', () {
    final r = TodoNaturalParser.parse('明天交高数作业');
    expect(r.day, today().add(const Duration(days: 1)));
    expect(r.clean, '交高数作业');
  });

  test('🔴 解析「后天」', () {
    final r = TodoNaturalParser.parse('后天交高数作业');
    expect(r.day, today().add(const Duration(days: 2)));
  });

  test('🔴 解析「下午3点」为 15 点', () {
    final r = TodoNaturalParser.parse('明天下午3点交高数作业');
    expect(r.day, today().add(const Duration(days: 1)));
    expect(r.hour, 15);
    expect(r.minute, 0);
    expect(r.clean, '交高数作业');
  });

  test('🔴 解析「3点半」', () {
    final r = TodoNaturalParser.parse('明天3点半开会');
    expect(r.hour, 3);
    expect(r.minute, 30);
  });

  test('🔴 解析「15:30」', () {
    final r = TodoNaturalParser.parse('明天15:30交高数作业');
    expect(r.hour, 15);
    expect(r.minute, 30);
  });

  test('🔴 解析「周X」', () {
    final r = TodoNaturalParser.parse('周五交高数作业');
    expect(r.day, isNotNull);
    expect(r.day!.weekday, 5);
  });

  test('🔴 解析「下周三」', () {
    final r = TodoNaturalParser.parse('下周三交高数作业');
    expect(r.day, isNotNull);
    // 下周三一定在今天之后 7~13 天内
    final diff = r.day!.difference(today()).inDays;
    expect(diff, greaterThanOrEqualTo(7));
    expect(diff, lessThanOrEqualTo(13));
    expect(r.day!.weekday, 3);
  });

  test('🔴 解析「X月X日」', () {
    final r = TodoNaturalParser.parse('12月25日交高数作业');
    final now = DateTime.now();
    expect(r.day!.month, 12);
    expect(r.day!.day, 25);
    expect(r.day!.year, now.year);
  });

  test('🔴 清掉「提醒我」等虚词', () {
    final r = TodoNaturalParser.parse('提醒我明天交高数作业');
    expect(r.clean, '交高数作业');
  });

  test('🔴 非法月份不炸，且不影响其它字段', () {
    final r = TodoNaturalParser.parse('13月99日明天交高数');
    // 非法月日被忽略，但「明天」仍能解析
    expect(r.day, today().add(const Duration(days: 1)));
  });

  test('🔴 空输入不炸', () {
    final r = TodoNaturalParser.parse('');
    expect(r.day, isNull);
    expect(r.hour, isNull);
    expect(r.clean, '');
  });

  test('🔴 没有时间描述时 clean == 原标题', () {
    final r = TodoNaturalParser.parse('交高数作业');
    expect(r.hour, isNull);
    expect(r.minute, isNull);
    expect(r.clean, '交高数作业');
  });

  test('🔴 「晚上8点」换算为 20 点', () {
    final r = TodoNaturalParser.parse('今晚8点开会');
    expect(r.hour, 20);
  });
}
