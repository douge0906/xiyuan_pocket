import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/services/course_transfer_service.dart';
import 'package:xiyuan_pocket/services/timetable/timetable_import_service.dart';
import 'package:xiyuan_pocket/services/timetable/timetable_models.dart';

/// 在线课表 → 本机课表的转换、差异与文件解析回归。
///
/// 这里钉死的是三件会「静默出错」的事：
/// 1. 导入的课必须标 `CourseSource.imported`。标成 `server` 的话，下一次教务
///    同步会把它当成「教务已经没有这门课了」直接删掉 —— 用户会莫名其妙丢课。
/// 2. 差异摘要必须按**课程名**配对，不是按 id。两份课表来自不同人，
///    id 天生不同（甚至两边都没 id），按 id 配等于永远算成「全变了」。
/// 3. 方案文件解析要能分清「课表方案」「完整方案」和「仅外观方案」，
///    选错文件要给出人能看懂的话，而不是空列表。
void main() {
  Course course({
    String id = 'c1',
    String name = '数字电子技术',
    String teacher = '李老师',
    String classroom = '思贤楼203',
    int weekday = 1,
    int startSlot = 1,
    int endSlot = 2,
    String weeks = '1-16',
    CourseSource source = CourseSource.manual,
  }) {
    return Course(
      id: id,
      name: name,
      teacher: teacher,
      classroom: classroom,
      weekday: weekday,
      startSlot: startSlot,
      endSlot: endSlot,
      weeks: weeks,
      colorValue: 0xFF123456,
      source: source,
    );
  }

  TimetableCourseItem item({
    String name = '数字电子技术',
    String teacher = '李老师',
    String classroom = '思贤楼203',
    int weekday = 1,
    int startSlot = 1,
    int endSlot = 2,
    String weeks = '1-16',
  }) {
    return TimetableCourseItem(
      name: name,
      teacher: teacher,
      classroom: classroom,
      weekday: weekday,
      startSlot: startSlot,
      endSlot: endSlot,
      weeks: weeks,
    );
  }

  group('在线课表 · Course ↔ 上传条目', () {
    test('从本机课程表转上传条目：只保留固定节次的课', () {
      final courses = [
        course(id: 'a', name: '数字电子技术'),
        course(id: 'b', name: '晚自习', source: CourseSource.manual),
      ];
      final items = TimetableImportService.fromCourses(courses);
      expect(items.length, 2);
      expect(items.first.name, '数字电子技术');
      expect(items.first.weekday, 1);
      expect(items.first.startSlot, 1);
      expect(items.first.endSlot, 2);
      expect(items.first.weeks, '1-16');
    });

    test('非固定节次的课（daily / workday）不进上传', () {
      final daily = Course(
        id: 'd',
        name: '每日打卡',
        weekday: 1,
        startSlot: 1,
        endSlot: 1,
        weeks: '1-16',
        colorValue: 0,
        pattern: CoursePattern.daily,
      );
      expect(TimetableImportService.fromCourses([daily]), isEmpty);
    });

    test('落库时 source 必须是 imported，绝不能是 server', () {
      final courses = TimetableImportService.toCourses([item()]);
      expect(courses.length, 1);
      expect(
        courses.first.source,
        CourseSource.imported,
        reason: '标成 server 的话，下一次教务同步会把这门课当"教务已删除"清掉',
      );
    });

    test('同一门课重复导入不产生新 id（按内容生成稳定 id）', () {
      final a = TimetableImportService.toCourses([item()]).first;
      final b = TimetableImportService.toCourses([item()]).first;
      expect(a.id, b.id);
      final c = TimetableImportService.toCourses([
        item(startSlot: 3, endSlot: 4),
      ]).first;
      expect(c.id, isNot(a.id), reason: '节次变了就是另一节课');
    });
  });

  group('在线课表 · 覆盖前差异摘要', () {
    test('新增 + 变更 + 移除三类分别计数', () {
      final existing = [
        course(id: 'a', name: '数字电子技术', startSlot: 9, endSlot: 10),
        course(id: 'b', name: '大学物理'),
        course(id: 'c', name: '被删掉的课'),
      ];
      final incoming = [
        item(name: '数字电子技术', startSlot: 7, endSlot: 8), // 节次变了
        item(name: '大学物理'), // 一样
        item(name: '新加的课'), // 新增
      ];
      final d = TimetableImportService.diff(existing, incoming);
      expect(d.added, 1);
      expect(d.changed, 1);
      expect(d.removed, 1);
      expect(d.hasChanges, isTrue);
      final changed = d.details.firstWhere((e) => e.kind == 'changed');
      expect(changed.detail.contains('第9-10节'), isTrue);
      expect(changed.detail.contains('第7-8节'), isTrue);
    });

    test('完全一样时没有变化（不弹差异区）', () {
      final existing = [course()];
      final incoming = [item()];
      final d = TimetableImportService.diff(existing, incoming);
      expect(d.added, 0);
      expect(d.changed, 0);
      expect(d.removed, 0);
      expect(d.hasChanges, isFalse);
    });

    test('课程名比对忽略括注与空白（教务和同学写法不同）', () {
      final existing = [course(name: '高等数学（上）')];
      final incoming = [item(name: '高等数学(上)')];
      final d = TimetableImportService.diff(existing, incoming);
      expect(d.added, 0, reason: '全角/半角括号与括注内容都不该算成两门课');
      expect(d.removed, 0);
      expect(d.changed, 0);
    });

    test('教室 / 教师 / 周次变化都算变更', () {
      final existing = [course()];
      final incoming = [item(classroom: '思贤楼305', teacher: '王老师', weeks: '1-8')];
      final d = TimetableImportService.diff(existing, incoming);
      expect(d.changed, 1);
      final detail = d.details.first.detail;
      expect(detail.contains('教室'), isTrue);
      expect(detail.contains('教师'), isTrue);
      expect(detail.contains('周次'), isTrue);
    });
  });

  group('在线课表 · 需要确认的问题标记', () {
    test('缺教室 / 缺周次会报出来', () {
      final items = [item(classroom: '', weeks: '')];
      final issues = TimetableImportService.issuesOf(items, 0);
      expect(issues.contains('缺少教室'), isTrue);
      expect(issues.contains('周次待确认'), isTrue);
      expect(TimetableImportService.issueCount(items), 1);
    });

    test('同一门课同一时间段重叠会报「时间重叠」', () {
      final items = [
        item(name: 'A', weekday: 2, startSlot: 3, endSlot: 4),
        item(name: 'B', weekday: 2, startSlot: 4, endSlot: 5),
      ];
      expect(TimetableImportService.issuesOf(items, 0).contains('时间重叠'), isTrue);
      expect(TimetableImportService.issuesOf(items, 1).contains('时间重叠'), isTrue);
    });

    test('不同星期不重叠', () {
      final items = [
        item(name: 'A', weekday: 1, startSlot: 3, endSlot: 4),
        item(name: 'B', weekday: 2, startSlot: 3, endSlot: 4),
      ];
      expect(TimetableImportService.issuesOf(items, 0), isEmpty);
      expect(TimetableImportService.issuesOf(items, 1), isEmpty);
    });
  });

  group('在线课表 · 方案文件解析', () {
    Uint8List bytes(Map<String, dynamic> m) =>
        Uint8List.fromList(utf8.encode(jsonEncode(m)));

    test('读课表方案（xiyuan.course.tables）', () {
      final payload = {
        'schema': CourseTransferService.schema,
        'version': CourseTransferService.formatVersion,
        'activeId': 't2',
        'tables': [
          {
            'id': 't1',
            'name': '别的班',
            'createdAt': '2026-09-01T00:00:00.000',
            'courses': <dynamic>[],
          },
          {
            'id': 't2',
            'name': '25电气1班',
            'createdAt': '2026-09-01T00:00:00.000',
            'courses': [
              {
                'id': 'x',
                'name': '数字电子技术',
                'weekday': 1,
                'startSlot': 1,
                'endSlot': 2,
                'weeks': '1-16',
                'colorValue': 1,
              }
            ],
          },
        ],
      };
      final items = TimetableImportService.parseFileBytes(bytes(payload));
      expect(items.length, 1);
      expect(items.first.name, '数字电子技术');
    });

    test('读完整方案（xiyuan.full.bundle）', () {
      final payload = {
        'schema': CourseTransferService.bundleSchema,
        'version': CourseTransferService.formatVersion,
        'activeId': 't1',
        'tables': [
          {
            'id': 't1',
            'name': '25电气1班',
            'createdAt': '2026-09-01T00:00:00.000',
            'courses': [
              {
                'id': 'x',
                'name': '大学物理',
                'weekday': 3,
                'startSlot': 5,
                'endSlot': 6,
                'weeks': '1-8',
                'colorValue': 1,
              }
            ],
          },
        ],
      };
      final items = TimetableImportService.parseFileBytes(bytes(payload));
      expect(items.single.name, '大学物理');
    });

    test('仅外观方案要明确拒绝（它不含课表）', () {
      final payload = {
        'schema': CourseTransferService.appearanceSchema,
        'version': CourseTransferService.formatVersion,
      };
      expect(
        () => TimetableImportService.parseFileBytes(bytes(payload)),
        throwsA(isA<CourseTransferException>().having(
          (e) => e.message,
          'message',
          contains('外观'),
        )),
      );
    });

    test('不是掌上锡院的文件要说清楚', () {
      final payload = {'schema': 'something.else', 'version': 1};
      expect(
        () => TimetableImportService.parseFileBytes(bytes(payload)),
        throwsA(isA<CourseTransferException>()),
      );
    });

    test('空文件 / 非 JSON / 无课表都报错而不是返回空列表', () {
      expect(
        () => TimetableImportService.parseFileBytes(Uint8List(0)),
        throwsA(isA<CourseTransferException>()),
      );
      expect(
        () => TimetableImportService.parseFileBytes(
            Uint8List.fromList(utf8.encode('not json'))),
        throwsA(isA<CourseTransferException>()),
      );
      expect(
        () => TimetableImportService.parseFileBytes(bytes({
          'schema': CourseTransferService.schema,
          'version': CourseTransferService.formatVersion,
          'tables': <dynamic>[],
        })),
        throwsA(isA<CourseTransferException>()),
      );
    });
  });

  group('在线课表 · 请求体形状', () {
    test('toRequestJson 用 camelCase，与 _validate_body 对齐', () {
      final m = item().toRequestJson();
      expect(m['name'], '数字电子技术');
      expect(m['weekday'], 1);
      expect(m['startSlot'], 1);
      expect(m['endSlot'], 2);
      expect(m['weeks'], '1-16');
      expect(m.containsKey('start_slot'), isFalse, reason: '服务端收 camelCase');
    });
  });
}
