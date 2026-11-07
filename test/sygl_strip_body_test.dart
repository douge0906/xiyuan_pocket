import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/campus/sygl_client.dart';

/// `_stripBody` 曾因为 raw string 里写了双反斜杠（`\\s`）而**恒返回空串**，
/// 导致所有 asmx 请求体都是空的。这条测试专门钉住它。
void main() {
  group('SyglClient.stripBody', () {
    test('正常的 kzJson 外壳能被剥开', () {
      expect(SyglClient.stripBody("{kzJson:'1'}"), '1');
    });

    test('空值外壳剥出空串', () {
      expect(SyglClient.stripBody("{kzJson:''}"), '');
    });

    test('带分页参数的请求体能原样取出（不被截断）', () {
      // 真实用例：仪器列表那类请求体里既有引号又有冒号，
      // 双反斜杠的正则会把整段吃掉返回空串。
      const raw = """{kzJson:'{"strJson":"a","PageIndex":"0"}'}""";
      final inner = SyglClient.stripBody(raw);
      expect(inner, '{"strJson":"a","PageIndex":"0"}');
    });

    test('换行与多余空格不影响剥离结果', () {
      expect(SyglClient.stripBody("{ kzJson : 'x' }"), 'x');
      expect(SyglClient.stripBody("{\n  kzJson: 'y'\n}"), 'y');
    });

    test('不带外壳的输入返回空串（不返回半截）', () {
      expect(SyglClient.stripBody('{}'), '');
      expect(SyglClient.stripBody(''), '');
    });
  });

  group('实验排课文本', () {
    test('从合并文本解析星期、节次和周次', () {
      final lab = SyglClient.labFromJsonForTest({
        'SYSMC': '单片机实验',
        'SKSJ': '星期二 第3-4节 1-16周',
        'SYSDZ': '实验楼 A201',
      });
      expect(lab, isNotNull);
      expect(lab!.hasSchedule, isTrue);
      expect(lab.weekday, 2);
      expect(lab.startSlot, 3);
      expect(lab.endSlot, 4);
      expect(lab.weeks, '1-16周');
    });

    test('独立字段优先于文本，周天的两种写法都能识别', () {
      final lab = SyglClient.labFromJsonForTest({
        'name': '嵌入式实验',
        'time': '星期天 第1节 2周',
        'weekday': '星期一',
        'startSlot': '5',
        'endSlot': '6',
      });
      expect(lab!.weekday, 1);
      expect(lab.startSlot, 5);
      expect(lab.endSlot, 6);
      expect(SyglClient.labFromJsonForTest({
        'name': '周日实验', 'time': '周天 第1节 2周',
      })!.weekday, 7);
    });

    test('表格按时间列识别，不再把编号当课程名', () {
      final labs = SyglClient.labsFromTableForTest(
        '<table><tr><td>序号</td><td>课程名称</td><td>排课时间</td></tr>'
        '<tr><td>01</td><td>数字电路实验</td>'
        '<td>星期三 第5-6节 3-8周</td><td>实验楼 B302</td><td>王老师</td></tr></table>',
      );
      expect(labs, hasLength(1));
      expect(labs.single.name, '数字电路实验');
      expect(labs.single.weekday, 3);
      expect(labs.single.startSlot, 5);
      expect(labs.single.endSlot, 6);
      expect(labs.single.place, '实验楼 B302');
    });
  });

  group('我的课表真实列（截图 m26006）', () {
    test('按表头列映射：星期由日期推、节次由 7-11 推、周次写 N周', () {
      final labs = SyglClient.labsFromTableForTest(
        '<table>'
        '<tr><th>周次</th><th>班级</th><th>日期</th><th>节次/时间</th>'
        '<th>人数</th><th>实验课程</th><th>实验项目</th><th>教师</th>'
        '<th>实验室</th></tr>'
        '<tr><td>2</td><td>25测绘1</td><td>20260918</td>'
        '<td>7-11(15:55-21:20)</td><td>37</td>'
        '<td>地理信息系统原理实验</td><td>空间数据的可视化</td>'
        '<td>尹静秋(001310)</td><td>天气预报综合实验室</td></tr>'
        '</table>',
      );
      expect(labs, hasLength(1));
      final lab = labs.single;
      expect(lab.name, '地理信息系统原理实验');
      expect(lab.weekday, 5); // 2026-09-18 是周五，由日期列推出
      expect(lab.startSlot, 7);
      expect(lab.endSlot, 11);
      expect(lab.weeks, '2周');
      expect(lab.place, '天气预报综合实验室');
      expect(lab.teacher, '尹静秋(001310)');
      expect(lab.hasSchedule, isTrue);
    });

    test('同一课程跨多行时按课程名分组所需字段都保留', () {
      final labs = SyglClient.labsFromTableForTest(
        '<table>'
        '<tr><th>周次</th><th>班级</th><th>日期</th><th>节次/时间</th>'
        '<th>人数</th><th>实验课程</th><th>实验项目</th><th>教师</th>'
        '<th>实验室</th></tr>'
        '<tr><td>2</td><td>25测绘1</td><td>20260918</td>'
        '<td>7-11(15:55-21:20)</td><td>37</td><td>测绘CAD</td>'
        '<td>二维图形绘制</td><td>刘曙光(860486)</td>'
        '<td>遥感信息工程实验室</td></tr>'
        '<tr><td>6</td><td>25测绘1</td><td>20261016</td>'
        '<td>7-8(15:55-17:35)</td><td>37</td><td>测绘CAD</td>'
        '<td>二维图形绘制</td><td>刘曙光(860486)</td>'
        '<td>遥感信息工程实验室</td></tr>'
        '</table>',
      );
      expect(labs, hasLength(2));
      expect(labs.map((l) => l.name).toSet(), {'测绘CAD'});
      expect(labs.map((l) => l.weeks).toSet(), {'2周', '6周'});
    });
  });

}
