import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/campus/sygl_client.dart';

Map<String, Object?> row({
  required String className,
  required String date,
  required String week,
  String course = '模拟电子技术基础丨实验',
}) =>
    {
      'ZC': week,
      'BJMC': className,
      'SKRQ': date,
      'SKSJ': '9-10(18:45-20:25)',
      'KCMC': '$course(131302011)',
      'XMMC': '二极管伏安特性的测量',
      'ZJJS': '巫君杰(860015)',
      'SYSMC': '电路与电子技术实验室2',
    };

void main() {
  test('同一课程同班同学年多周合并成一条，周次取并集', () {
    final labs = SyglClient.debugLabsFromRuleManageRows([
      row(className: '25微电子1', date: '20260914', week: '2'),
      row(className: '25微电子1', date: '20260921', week: '3'),
    ]);
    expect(labs, hasLength(1));
    expect(labs.single.weeks, '2-3周');
    expect(labs.single.className, '25微电子1');
    expect(labs.single.academicYear, '2026-2027');
  });

  test('同课不同班不合并', () {
    final labs = SyglClient.debugLabsFromRuleManageRows([
      row(className: '25微电子1', date: '20260914', week: '2'),
      row(className: '25微电子2', date: '20260914', week: '2'),
    ]);
    expect(labs, hasLength(2));
    expect(labs.map((e) => e.className).toSet(), {'25微电子1', '25微电子2'});
  });

  test('同课不同学年不合并，且新学年排在前', () {
    final labs = SyglClient.debugLabsFromRuleManageRows([
      row(className: '25微电子1', date: '20250614', week: '2'),
      row(className: '25微电子1', date: '20260914', week: '2'),
    ]);
    expect(labs, hasLength(2));
    expect(labs.first.academicYear, '2026-2027');
    expect(labs.last.academicYear, '2024-2025');
    expect(labs.last.academicTerm, '第二学期');
  });

  test('合班字段顿号规范化，不被拆残', () {
    final labs = SyglClient.debugLabsFromRuleManageRows([
      row(className: '25电气1,25电气2,25电气3', date: '20260914', week: '2'),
    ]);
    expect(labs.single.className, '25电气1、25电气2、25电气3');
  });
}
