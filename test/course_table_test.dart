import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/models/course_table.dart';

/// 课表档案模型测试（多课表功能 · 步骤 1）。
///
/// 这份模型最要紧的两件事：
///   ① **能原样往返** —— 一份课表存进去再读出来必须一模一样，否则切换一次
///      就丢数据；
///   ② **坏数据不连坐** —— 某一份课表坏了只能坏它自己，不能把整份存储带崩。
Course _c({String id = 'c1', String name = '高等数学'}) => Course(
      id: id,
      name: name,
      weekday: 1,
      startSlot: 1,
      endSlot: 2,
      colorValue: 0xFFD2E5F8,
      source: CourseSource.server,
    );

void main() {
  group('CourseTable 往返', () {
    test('toJson → fromJson 字段全部原样回来', () {
      final t = CourseTable(
        id: 't_1',
        name: '张同学的课表',
        createdAt: DateTime(2026, 10, 8, 23, 30),
        courses: [_c(), _c(id: 'c2', name: '线性代数')],
        semesterStart: DateTime(2026, 9, 7),
        semesterStartSource: CourseTable.srcUser,
      );
      final back = CourseTable.fromJson(t.toJson())!;

      expect(back.id, 't_1');
      expect(back.name, '张同学的课表');
      expect(back.createdAt, DateTime(2026, 10, 8, 23, 30));
      expect(back.courses.length, 2);
      expect(back.courses.first.name, '高等数学');
      expect(back.courses[1].name, '线性代数');
      expect(back.semesterStart, DateTime(2026, 9, 7));
      expect(back.semesterStartSource, CourseTable.srcUser);
    });

    test('🔴 课程的门数与内容一门都不能少（切换一次丢一门就完了）', () {
      final courses = List.generate(30, (i) => _c(id: 'c$i', name: '课$i'));
      final back = CourseTable.fromJson(
          CourseTable(id: 't', name: 'n', createdAt: DateTime(2026), courses: courses)
              .toJson())!;
      expect(back.courses.length, 30);
      for (var i = 0; i < 30; i++) {
        expect(back.courses[i].id, 'c$i');
        expect(back.courses[i].name, '课$i');
      }
    });

    test('开学日按 YYYY-MM-DD 存（与老的 course_semester_start 键同格式）', () {
      final json = CourseTable(
        id: 't',
        name: 'n',
        createdAt: DateTime(2026),
        courses: const [],
        semesterStart: DateTime(2026, 9, 7),
      ).toJson();
      expect(json['semesterStart'], '2026-09-07');
    });

    test('没定过开学日 → null，读回来还是 null', () {
      final back = CourseTable.fromJson(CourseTable(
        id: 't',
        name: 'n',
        createdAt: DateTime(2026),
        courses: const [],
      ).toJson())!;
      expect(back.semesterStart, isNull);
    });
  });

  group('CourseTable 容错', () {
    test('没有 id → 整份丢弃（返回 null，调用方跳过）', () {
      expect(CourseTable.fromJson({'name': 'x'}), isNull);
      expect(CourseTable.fromJson({'id': '', 'name': 'x'}), isNull);
    });

    test('🔴 单门课坏掉只跳过它，其余照常读出来', () {
      final back = CourseTable.fromJson({
        'id': 't',
        'name': 'n',
        'courses': [
          _c().toJson(),
          {'id': 'bad', 'weekday': '不是数字', 'startSlot': {}},
          _c(id: 'c2', name: '线性代数').toJson(),
        ],
      })!;
      expect(back.courses.length, 2);
      expect(back.courses.map((c) => c.id), ['c1', 'c2']);
    });

    test('courses 不是列表 / 缺失 → 当成空表，不炸', () {
      expect(CourseTable.fromJson({'id': 't', 'courses': 'oops'})!.courses, isEmpty);
      expect(CourseTable.fromJson({'id': 't'})!.courses, isEmpty);
    });

    test('名字为空 → 兜底「未命名课表」', () {
      expect(CourseTable.fromJson({'id': 't', 'name': ''})!.name, '未命名课表');
      expect(CourseTable.fromJson({'id': 't'})!.name, '未命名课表');
    });

    test('开学日来源不认识的值 → 一律归一成 auto（宁可不打扰也不能漏提醒）', () {
      expect(CourseTable.fromJson({'id': 't', 'semesterStartSource': '???s'})!
          .semesterStartSource, CourseTable.srcAuto);
      expect(CourseTable.fromJson({'id': 't'})!.semesterStartSource,
          CourseTable.srcAuto);
    });

    test('不是 Map 的输入 → null', () {
      expect(CourseTable.fromJson(null), isNull);
      expect(CourseTable.fromJson('字符串'), isNull);
      expect(CourseTable.fromJson(42), isNull);
    });
  });

  group('CourseTable.copyWith', () {
    final base = CourseTable(
      id: 't',
      name: '我的课表',
      createdAt: DateTime(2026, 1, 1),
      courses: [_c()],
      semesterStart: DateTime(2026, 9, 7),
      semesterStartSource: CourseTable.srcUser,
    );

    test('只改名字时，id / 创建时间 / 课程 / 开学日都不动', () {
      final r = base.copyWith(name: '新名字');
      expect(r.name, '新名字');
      expect(r.id, 't');
      expect(r.createdAt, DateTime(2026, 1, 1));
      expect(r.courses.length, 1);
      expect(r.semesterStart, DateTime(2026, 9, 7));
      expect(r.semesterStartSource, CourseTable.srcUser);
    });

    test('clearSemesterStart 能把开学日清空（导入新课表时要用）', () {
      expect(base.copyWith(clearSemesterStart: true).semesterStart, isNull);
    });
  });
}
