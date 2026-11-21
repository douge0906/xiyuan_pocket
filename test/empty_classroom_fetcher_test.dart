import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/campus/empty_classroom_fetcher.dart';

void main() {
  group('位掩码与星期序列化', () {
    test('周次 1-4 位掩码为 15，第 11 周为 1024', () {
      expect(EmptyClassroomFetcher.maskOf([1, 2, 3, 4]), 15);
      expect(EmptyClassroomFetcher.maskOf([11]), 1024);
    });

    test('节次 1-4 为 15，晚 9-11 节为 1792', () {
      expect(EmptyClassroomFetcher.maskOf([1, 2, 3, 4]), 15);
      expect(EmptyClassroomFetcher.maskOf([9, 10, 11]), 1792);
    });

    test('无效节次不参与掩码，空列表为 0', () {
      expect(EmptyClassroomFetcher.maskOf([]), 0);
      expect(EmptyClassroomFetcher.maskOf([0, -1, 2]), 2);
    });

    test('星期多选排序后用英文逗号拼接', () {
      expect(EmptyClassroomFetcher.joinWeekdays([2, 1]), '1,2');
      expect(EmptyClassroomFetcher.joinWeekdays([7]), '7');
    });
  });

  group('楼号选项解析', () {
    test('动态 lhList 保留 value/label，并在最前追加全部', () {
      final buildings = EmptyClassroomFetcher.parseBuildings(const {
        'lhList': [
          {'JXLDM': 'C1', 'JXLMC': 'C1勤学楼'},
          {'JXLDM': 'C2', 'JXLMC': 'C2笃学楼'},
        ],
      }, '');

      expect(buildings.first.isAll, true);
      expect(buildings.first.value, '');
      expect(buildings.first.label, '全部');
      expect(buildings[1].value, 'C1');
      expect(buildings[1].label, 'C1勤学楼');
      expect(buildings[2].value, 'C2');
      expect(buildings[2].label, 'C2笃学楼');
    });

    test('动态列表会过滤空 value/label，并去重', () {
      final buildings = EmptyClassroomFetcher.parseBuildings(const {
        'lhList': [
          {'JXLDM': '', 'JXLMC': '缺编码'},
          {'JXLDM': 'C1', 'JXLMC': ''},
          {'JXLDM': 'C1', 'JXLMC': 'C1勤学楼'},
          {'JXLDM': 'C1', 'JXLMC': 'C1勤学楼'},
        ],
      }, '');

      expect(buildings.length, 2);
      expect(buildings[1].value, 'C1');
      expect(buildings[1].label, 'C1勤学楼');
    });
    test('动态列表为空时，从真实页面 #lh 的 option 补齐', () {
      const html = '''
      <select id="lh" name="lh">
        <option value="">全部</option>
        <option value="C1">C1勤学楼</option>
        <option value="DXLYL">大学科技园立业楼</option>
      </select>
      ''';
      final buildings = EmptyClassroomFetcher.parseBuildings(const {}, html);

      expect(buildings.length, 3);
      expect(buildings[1].value, 'C1');
      expect(buildings[1].label, 'C1勤学楼');
      expect(buildings[2].value, 'DXLYL');
      expect(buildings[2].label, '大学科技园立业楼');
    });

    test('楼号提交 value 与展示 label 不混淆', () {
      final buildings = EmptyClassroomFetcher.parseHtmlBuildings('''
      <select id="lh">
        <option value="C1">C1勤学楼</option>
        <option value="ydc">运动场</option>
      </select>
      ''');

      expect(buildings.first.value, 'C1');
      expect(buildings.first.label, 'C1勤学楼');
      expect(buildings.last.value, 'ydc');
      expect(buildings.last.label, '运动场');
    });
  });

  group('节次选项解析', () {
    test('解析 JCMC/RSDMC/SJD 并按节次号排序', () {
      final sections = EmptyClassroomFetcher.parseSections(const {
        'jcList': [
          {'JCMC': '4', 'RSDMC': '上午', 'SJD': '11:05-11:50'},
          {'JCMC': '1', 'RSDMC': '上午', 'SJD': '08:00-08:45'},
          {'JCMC': '11', 'RSDMC': '晚上', 'SJD': '20:35-21:20'},
        ],
      });

      expect(sections.map((e) => e.index).toList(), [1, 4, 11]);
      expect(sections.first.period, '上午');
      expect(sections.first.time, '08:00-08:45');
      expect(sections.last.period, '晚上');
    });

    test('节次号缺失或为 0 的畸形项被过滤', () {
      final sections = EmptyClassroomFetcher.parseSections(const {
        'jcList': [
          {'JCMC': '0', 'RSDMC': '上午'},
          {'JCMC': '', 'RSDMC': '下午'},
          {'JCMC': '3', 'RSDMC': '上午', 'SJD': '10:10-10:55'},
        ],
      });

      expect(sections.map((e) => e.index).toList(), [3]);
    });
  });

  group('查询结果解析与排序', () {
    test('字段映射使用教务原始字段，座位数字符串可转整数', () {
      final result = EmptyClassroomFetcher.parseResult(const {
        'totalResult': 1,
        'items': [
          {
            'cd_id': 'room-1',
            'cdbh': 'C1304',
            'cdmc': 'C1勤学楼304',
            'jxlmc': 'C1勤学楼',
            'lh': 'C1',
            'lch': '3',
            'cdlbmc': '多媒体教室',
            'zws': '64',
            'kszws1': '32',
          },
        ],
      });

      expect(result.total, 1);
      expect(result.rooms.first.name, 'C1勤学楼304');
      expect(result.rooms.first.code, 'C1304');
      expect(result.rooms.first.building, 'C1勤学楼');
      expect(result.rooms.first.buildingCode, 'C1');
      expect(result.rooms.first.floor, '3');
      expect(result.rooms.first.category, '多媒体教室');
      expect(result.rooms.first.seats, 64);
      expect(result.rooms.first.examSeats, 32);
    });

    test('空列表返回空结果和提示文案', () {
      final result = EmptyClassroomFetcher.parseResult(const {
        'totalResult': 0,
        'items': [],
      });

      expect(result.rooms, isEmpty);
      expect(result.total, 0);
      expect(result.message, '这个时段没有空闲教室');
    });

    test('畸形行和缺失字段不崩，座位缺失保持 null', () {
      final result = EmptyClassroomFetcher.parseResult(const {
        'totalCount': 2,
        'items': [
          null,
          'not-a-map',
          {'cdbh': 'C1001', 'cdmc': 'C1勤学楼101'},
        ],
      });

      expect(result.rooms.length, 1);
      expect(result.total, 2);
      expect(result.rooms.first.seats, isNull);
      expect(result.rooms.first.examSeats, isNull);
      expect(result.rooms.first.category, '');
    });

    test('按楼号、楼层、房号自然排序', () {
      final result = EmptyClassroomFetcher.parseResult(const {
        'items': [
          {'cdbh': 'D5202', 'jxlmc': 'D5尚真楼', 'lh': 'D5', 'lch': '2'},
          {'cdbh': 'C1304', 'jxlmc': 'C1勤学楼', 'lh': 'C1', 'lch': '3'},
          {'cdbh': 'C1201', 'jxlmc': 'C1勤学楼', 'lh': 'C1', 'lch': '2'},
        ],
      });

      expect(result.rooms.map((e) => e.code).toList(),
          ['C1201', 'C1304', 'D5202']);
    });
  });

  group('四项必填校验', () {
    EmptyClassroomQuery makeQuery({
      List<int> weeks = const [11],
      List<int> weekdays = const [2],
      List<int> slots = const [1, 2, 3, 4],
      String buildingValue = 'C1',
    }) =>
        EmptyClassroomQuery(
          xnm: '2026',
          xqm: '3',
          campusId: 'campus',
          weeks: weeks,
          weekdays: weekdays,
          slots: slots,
          buildingValue: buildingValue,
        );

    test('完整选择时校验通过，空串楼号表示全部也合法', () {
      expect(makeQuery().validateMissing(), isNull);
      expect(makeQuery(buildingValue: '').validateMissing(), isNull);
    });

    test('依次提示缺失的周次、星期、节次', () {
      expect(makeQuery(weeks: const []).validateMissing(), '请选择周次');
      expect(makeQuery(weekdays: const []).validateMissing(), '请选择星期');
      expect(makeQuery(slots: const []).validateMissing(), '请选择节次');
    });
  });
}
