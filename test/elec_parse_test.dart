import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/dorm_service.dart';

/// 电费文案解析：三个片区的格式各不相同，且可能为负（欠费）。
/// 这些字符串全部是平台 2026-10-26 的真实返回。
void main() {
  group('金额解析（三个片区）', () {
    test('448：当前余额517.05元,当前剩余电量957.50度', () {
      const t = '当前余额517.05元,当前剩余电量957.50度';
      expect(DormService.parseMoney(t), 517.05);
      expect(DormService.parseKwh(t), 957.50);
    });

    test('449：房间当前剩余电费625.35（无「元」字、无电量）', () {
      const t = '房间当前剩余电费625.35';
      expect(DormService.parseMoney(t), 625.35);
      expect(DormService.parseKwh(t), isNull);
    });

    test('450：房间号：211,剩余金额：29.79，单价：0.5400', () {
      const t = '房间号：211,剩余金额：29.79，单价：0.5400';
      expect(DormService.parseMoney(t), 29.79);
      expect(DormService.parseKwh(t), isNull);
      // 关键：不能把房间号 211 或单价 0.54 当成余额
      expect(DormService.parseMoney(t), isNot(211));
      expect(DormService.parseMoney(t), isNot(0.54));
    });

    test('负数（欠费）', () {
      const t = '当前余额-12.19元,当前剩余电量-22.57度';
      expect(DormService.parseMoney(t), -12.19);
      expect(DormService.parseKwh(t), -22.57);
    });

    test('450 欠费：房间号：101,剩余金额：-545.70，单价：0.5400', () {
      const t = '房间号：101,剩余金额：-545.70，单价：0.5400';
      expect(DormService.parseMoney(t), -545.70);
    });

    test('整数余额', () {
      expect(DormService.parseMoney('房间当前剩余电费878'), 878);
    });
  });

  group('单价与电量换算（449/450 不发电量）', () {
    test('单价解析：450 文案自带', () {
      const t = '房间号：211,剩余金额：29.79，单价：0.5400';
      expect(DormService.parseUnitPrice(t), 0.54);
    });

    test('单价解析：448/449 文案没有 → null', () {
      expect(DormService.parseUnitPrice('当前余额10元'), isNull);
      expect(DormService.parseUnitPrice('房间当前剩余电费625.35'), isNull);
    });

    test('无电量时按 0.54 换算', () {
      const t = '房间当前剩余电费625.35';
      final balance = DormService.parseMoney(t)!;
      expect(DormService.parseKwh(t), isNull);
      expect(balance / DormService.defaultUnitPrice, closeTo(1158.06, 0.05));
    });
  });

  group('边界情况（宁缺勿错）', () {
    test('空串 / 无关键词 / 只有房间号 → null', () {
      expect(DormService.parseMoney(''), isNull);
      expect(DormService.parseMoney('查询成功'), isNull);
      expect(DormService.parseMoney('房间号：211'), isNull);
      expect(DormService.parseKwh('当前余额10元'), isNull);
    });

    test('关键词后没数字 → null（不臆造）', () {
      expect(DormService.parseMoney('余额：'), isNull);
      expect(DormService.parseMoney('剩余金额未知'), isNull);
    });

    test('分隔符变体', () {
      expect(DormService.parseMoney('余额=12.5'), 12.5);
      expect(DormService.parseMoney('余额为12.5'), 12.5);
      expect(DormService.parseMoney('余额 12.5 元'), 12.5);
    });
  });
}
