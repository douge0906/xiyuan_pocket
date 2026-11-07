import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/services/campus/sygl_client.dart';

void main() {
  group('实验课抓取 → 普通课程', () {
    test('JSON 形态：layui 返回的行能解出课名/周次/节次/地点', () {
      final lab = SyglClient.labFromJsonForTest(<String, Object?>{
        'SYSMC': '电工电子实验',
        'SYSBH': 'SY001',
        'SYSDZ': '实验楼 A301',
        'JSXM': '张老师',
        'SKSJ': '星期二 第3-4节',
        'ZC': '1-16周',
      });
      expect(lab, isNotNull);
      expect(lab!.name, '电工电子实验');
      expect(lab.weekday, 2);
      expect(lab.startSlot, 3);
      expect(lab.endSlot, 4);
      expect(lab.place, '实验楼 A301');
      expect(lab.teacher, '张老师');
      expect(lab.weeks, '1-16周');
      expect(lab.hasSchedule, isTrue);
    });

    test('合并排课文本：只有 time 也能补出星期/节次/周次', () {
      final lab = SyglClient.labFromJsonForTest(<String, Object?>{
        'KCMC': '物理实验',
        '时间': '星期四 5-6节 2-14周',
      });
      expect(lab, isNotNull);
      expect(lab!.weekday, 4);
      expect(lab.startSlot, 5);
      expect(lab.endSlot, 6);
      expect(lab.weeks, '2-14周');
      expect(lab.hasSchedule, isTrue);
    });

    test('表头驱动：静态表格按列名解出节次与地点', () {
      const html = '<table>'
          '<tr><th>周次</th><th>日期</th><th>节次</th><th>实验课程</th><th>教师</th><th>实验室</th></tr>'
          '<tr><td>1-16周</td><td>2026-09-08</td><td>第3-4节</td><td>电路实验</td><td>李老师</td><td>B201</td></tr>'
          '</table>';
      final labs = SyglClient.labsFromTableForTest(html);
      expect(labs, isNotEmpty);
      final first = labs.first;
      expect(first.name, '电路实验');
      expect(first.weekday, DateTime(2026, 9, 8).weekday);
      expect(first.startSlot, 3);
      expect(first.endSlot, 4);
      expect(first.place, 'B201');
    });

    test('转成普通课程字段齐全：source=imported 防教务覆盖、结束节兜底', () {
      final lab = SyglClient.labFromJsonForTest(<String, Object?>{
        'SYSMC': '化学实验',
        'SYSDZ': 'C102',
        'SKSJ': '星期一 第7节',
      })!;
      final weeks = lab.weeks.isNotEmpty ? lab.weeks : '1-20周';
      final c = Course(
        id: 'lab_${lab.name.hashCode}',
        name: lab.name,
        teacher: lab.teacher,
        classroom: lab.place,
        weekday: lab.weekday,
        startSlot: lab.startSlot,
        endSlot: lab.safeEndSlot,
        weeks: weeks,
        colorValue: 0xFF8B5CF6,
        source: CourseSource.imported,
      );
      expect(c.name, '化学实验');
      expect(c.startSlot, 7);
      expect(c.endSlot, 7);
      expect(c.weeks, '1-20周');
      expect(c.source, CourseSource.imported);
      expect(c.weekday, 1);
    });

    test('空排课不瞎猜：weekday=0 时 hasSchedule=false', () {
      final lab = SyglClient.labFromJsonForTest(<String, Object?>{
        'SYSMC': '无时间的课',
      })!;
      expect(lab.hasSchedule, isFalse);
    });
  });
}
