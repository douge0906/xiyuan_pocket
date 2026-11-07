import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/services/campus/sygl_client.dart';

/// 实验课表接口（`Syjx.asmx/getRuleManage`）的解析回归。
///
/// 下面是 2026-11-06 用真实账号抓到的 39 条排课原样快照，
/// 外层是站点返回的 XML 包 JSON 形态 —— 和线上逐字节一致。
void main() {
  group('getRuleManage 解析', () {
    test('XML 包 JSON 能剥出来', () {
      final rows = SyglClient.rowsFromAsmxBody(_raw);
      expect(rows, isNotNull);
      expect(rows!.length, 39);
      expect(rows.first['KCMC'], '地理信息系统原理Ⅰ(141306309)');
      expect(rows.first['SKSJ'], '7-11(15:55-21:20)');
    });

    test('裸 JSON（没有 XML 外壳）也能解析', () {
      final rows = SyglClient.rowsFromAsmxBody(
        '{"code":0,"msg":"","count":1,"data":'
        '[{"ZC":"3","SKRQ":"20260916","SKSJ":"1-2(08:00-09:40)",'
        '"KCMC":"测试课(123)","ZJJS":"某人(001)","SYSMC":"某实验室"}]}',
      );
      expect(rows, isNotNull);
      expect(rows!.length, 1);
    });

    test('39 条排课聚合成 9 条课表记录', () {
      final labs = SyglClient.labsFromRuleManageForTest(_raw);
      expect(labs.length, 9);
      // 一条都不许被 hasSchedule 过滤掉，否则用户会「导入成功但课表空空」。
      expect(labs.where((l) => !l.hasSchedule), isEmpty);
    });

    test('周次并集拼成 parseWeeks 认得的文本', () {
      final labs = SyglClient.labsFromRuleManageForTest(_raw);
      final cad = labs.firstWhere(
        (l) => l.name == '测绘CAD' && l.weekday == 4,
      );
      expect(cad.weeks, '5-14周');
      expect(cad.startSlot, 7);
      expect(cad.endSlot, 8);
      expect(cad.place, '遥感信息工程实验室');
      expect(cad.teacher, '刘曙光');
      expect(cad.time, '15:55-17:35');

      final gis = labs.firstWhere(
        (l) => l.name == '地理信息系统原理Ⅰ' && l.startSlot == 7 && l.endSlot == 11,
      );
      // 2 周与 6 周不连续，不能被压成 1-6 周。
      expect(gis.weeks, '2周,6周');
    });

    test('课程名与教师名剥掉尾部代码', () {
      final labs = SyglClient.labsFromRuleManageForTest(_raw);
      for (final l in labs) {
        expect(l.name.contains('('), isFalse, reason: l.name);
        expect(l.teacher.contains('('), isFalse, reason: l.teacher);
      }
      expect(labs.any((l) => l.name == '地理信息系统原理Ⅰ'), isTrue);
      expect(labs.any((l) => l.teacher == '尹静秋'), isTrue);
    });

    test('周次文本能被 parseWeeks 原样还原（存进去不会一周都不显示）', () {
      final labs = SyglClient.labsFromRuleManageForTest(_raw);
      for (final l in labs) {
        final weeks = l.weeks.isNotEmpty ? l.weeks : '1-20周';
        final parsed = parseWeeks(weeks);
        expect(parsed, isNotNull, reason: '${l.name} / $weeks');
        expect(parsed!.length, greaterThan(0), reason: '${l.name} / $weeks');
      }
      final gis = labs.firstWhere(
        (l) => l.name == '地理信息系统原理Ⅰ' && l.startSlot == 7,
      );
      // 2 周与 6 周不连续，往返后必须还是 {2,6}。
      expect(parseWeeks(gis.weeks), {2, 6});
      final cad = labs.firstWhere(
        (l) => l.name == '测绘CAD' && l.weekday == 4,
      );
      expect(parseWeeks(cad.weeks), {for (var i = 5; i <= 14; i++) i});
    });

    test('空数据 / 空正文不瞎猜', () {
      expect(
        SyglClient.labsFromRuleManageForTest(
          '<?xml version="1.0"?><string xmlns="http://tempuri.org/">'
          '{"code":0,"msg":"","count":0,"data":[]}</string>',
        ),
        isEmpty,
      );
      expect(SyglClient.labsFromRuleManageForTest(''), isEmpty);
      expect(SyglClient.labsFromRuleManageForTest('随便一段文字'), isEmpty);
    });

    test('解析不出节次的行被跳过，不会冒出 weekday=0 的卡片', () {
      final labs = SyglClient.labsFromRuleManageForTest(
        '<?xml version="1.0"?><string xmlns="http://tempuri.org/">'
        '{"code":0,"data":[{"ZC":"3","SKRQ":"20260916","SKSJ":"",'
        '"KCMC":"没排时间的课(1)","ZJJS":"某人(001)","SYSMC":"实验室"}]}</string>',
      );
      expect(labs, isEmpty);
    });
  });
}

const String _raw = r'''
<?xml version="1.0" encoding="utf-8"?>
<string xmlns="http://tempuri.org/">{"code":0,"msg":"","count":39,"data":[{"ZC":"2","BJMC":"25测绘1","SKRQ":"20260918","SKSJ":"7-11(15:55-21:20)","rs":"37","KCMC":"地理信息系统原理Ⅰ(141306309)","XMMC":"地理信息系统原理Ⅰ-25地信","ZJJS":"尹静秋(001310)","SYSMC":"天气预报综合实验室2"},{"ZC":"5","BJMC":"25测绘1","SKRQ":"20261009","SKSJ":"7-10(15:55-20:25)","rs":"37","KCMC":"地理信息系统原理Ⅰ(141306309)","XMMC":"空间数据的可视化表达","ZJJS":"尹静秋(001310)","SYSMC":"天气预报综合实验室2"},{"ZC":"5","BJMC":"25测绘1","SKRQ":"20261008","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"6","BJMC":"25测绘1","SKRQ":"20261015","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"6","BJMC":"25测绘1","SKRQ":"20261012","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"6","BJMC":"25测绘1","SKRQ":"20261016","SKSJ":"7-11(15:55-21:20)","rs":"37","KCMC":"地理信息系统原理Ⅰ(141306309)","XMMC":"空间数据处理方法","ZJJS":"尹静秋(001310)","SYSMC":"天气预报综合实验室2"},{"ZC":"6","BJMC":"25测绘1","SKRQ":"20261012","SKSJ":"9-10(18:45-20:25)","rs":"37","KCMC":"测绘程序设计(152306314)","XMMC":"测绘程序设计实验","ZJJS":"陈泽(860361)","SYSMC":"遥感信息工程实验室"},{"ZC":"7","BJMC":"25测绘1","SKRQ":"20261019","SKSJ":"9-10(18:45-20:25)","rs":"37","KCMC":"测绘程序设计(152306314)","XMMC":"测绘程序设计实验","ZJJS":"陈泽(860361)","SYSMC":"遥感信息工程实验室"},{"ZC":"7","BJMC":"25测绘1","SKRQ":"20261023","SKSJ":"5-8(13:45-17:35)","rs":"37","KCMC":"大地测量学基础(131306304)","XMMC":"大地测量学基础实践课程","ZJJS":"刘曙光(860486)","SYSMC":"测绘工程实验室"},{"ZC":"7","BJMC":"25测绘1","SKRQ":"20261019","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"7","BJMC":"25测绘1","SKRQ":"20261022","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"8","BJMC":"25测绘1","SKRQ":"20261029","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"8","BJMC":"25测绘1","SKRQ":"20261026","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"8","BJMC":"25测绘1","SKRQ":"20261030","SKSJ":"5-8(13:45-17:35)","rs":"37","KCMC":"大地测量学基础(131306304)","XMMC":"大地测量学基础实践课程","ZJJS":"刘曙光(860486)","SYSMC":"测绘工程实验室"},{"ZC":"8","BJMC":"25测绘1","SKRQ":"20261026","SKSJ":"9-10(18:45-20:25)","rs":"37","KCMC":"测绘程序设计(152306314)","XMMC":"测绘程序设计实验","ZJJS":"陈泽(860361)","SYSMC":"遥感信息工程实验室"},{"ZC":"9","BJMC":"25测绘1","SKRQ":"20261102","SKSJ":"9-10(18:45-20:25)","rs":"37","KCMC":"测绘程序设计(152306314)","XMMC":"测绘程序设计实验","ZJJS":"陈泽(860361)","SYSMC":"遥感信息工程实验室"},{"ZC":"9","BJMC":"25测绘1","SKRQ":"20261106","SKSJ":"1-2(08:00-09:40)","rs":"37","KCMC":"地理信息系统原理Ⅰ(141306309)","XMMC":"地理信息系统原理Ⅰ-25地信","ZJJS":"尹静秋(001310)","SYSMC":"天气预报综合实验室1"},{"ZC":"9","BJMC":"25测绘1","SKRQ":"20261102","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"9","BJMC":"25测绘1","SKRQ":"20261105","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"10","BJMC":"25测绘1","SKRQ":"20261112","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"10","BJMC":"25测绘1","SKRQ":"20261109","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"10","BJMC":"25测绘1","SKRQ":"20261109","SKSJ":"9-10(18:45-20:25)","rs":"37","KCMC":"测绘程序设计(152306314)","XMMC":"测绘程序设计实验","ZJJS":"陈泽(860361)","SYSMC":"遥感信息工程实验室"},{"ZC":"11","BJMC":"25测绘1","SKRQ":"20261116","SKSJ":"9-10(18:45-20:25)","rs":"37","KCMC":"测绘程序设计(152306314)","XMMC":"测绘程序设计实验","ZJJS":"陈泽(860361)","SYSMC":"遥感信息工程实验室"},{"ZC":"11","BJMC":"25测绘1","SKRQ":"20261116","SKSJ":"11-11(20:35-21:20)","rs":"37","KCMC":"测绘程序设计(152306314)","XMMC":"测绘程序设计实验","ZJJS":"陈泽(860361)","SYSMC":"遥感信息工程实验室"},{"ZC":"11","BJMC":"25测绘1","SKRQ":"20261116","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"11","BJMC":"25测绘1","SKRQ":"20261119","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"12","BJMC":"25测绘1","SKRQ":"20261126","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"12","BJMC":"25测绘1","SKRQ":"20261123","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"12","BJMC":"25测绘1","SKRQ":"20261123","SKSJ":"11-11(20:35-21:20)","rs":"37","KCMC":"测绘程序设计(152306314)","XMMC":"测绘程序设计实验","ZJJS":"陈泽(860361)","SYSMC":"遥感信息工程实验室"},{"ZC":"12","BJMC":"25测绘1","SKRQ":"20261123","SKSJ":"9-10(18:45-20:25)","rs":"37","KCMC":"测绘程序设计(152306314)","XMMC":"测绘程序设计实验","ZJJS":"陈泽(860361)","SYSMC":"遥感信息工程实验室"},{"ZC":"13","BJMC":"25测绘1","SKRQ":"20261204","SKSJ":"5-8(13:45-17:35)","rs":"40","KCMC":"地图制图学基础(141306306)","XMMC":"地图制图学基础实验课","ZJJS":"徐敏(860538)","SYSMC":"天气预报综合实验室3"},{"ZC":"13","BJMC":"25测绘1","SKRQ":"20261130","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"13","BJMC":"25测绘1","SKRQ":"20261203","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"14","BJMC":"25测绘1","SKRQ":"20261210","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"14","BJMC":"25测绘1","SKRQ":"20261207","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"14","BJMC":"25测绘1","SKRQ":"20261211","SKSJ":"5-8(13:45-17:35)","rs":"40","KCMC":"地图制图学基础(141306306)","XMMC":"地图制图学基础实验课","ZJJS":"徐敏(860538)","SYSMC":"天气预报综合实验室3"},{"ZC":"15","BJMC":"25测绘1","SKRQ":"20261218","SKSJ":"5-8(13:45-17:35)","rs":"40","KCMC":"地图制图学基础(141306306)","XMMC":"地图制图学基础实验课","ZJJS":"徐敏(860538)","SYSMC":"天气预报综合实验室3"},{"ZC":"15","BJMC":"25测绘1","SKRQ":"20261214","SKSJ":"7-8(15:55-17:35)","rs":"37","KCMC":"测绘CAD(141306307)","XMMC":"二维图形绘制","ZJJS":"刘曙光(860486)","SYSMC":"遥感信息工程实验室"},{"ZC":"16","BJMC":"25测绘1","SKRQ":"20261225","SKSJ":"5-8(13:45-17:35)","rs":"40","KCMC":"地图制图学基础(141306306)","XMMC":"地图制图学基础实验课","ZJJS":"徐敏(860538)","SYSMC":"天气预报综合实验室3"}]}</string>
''';
