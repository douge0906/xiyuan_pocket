import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/services/course_sync_service.dart';

/// 「抓取器一行 JSON → Course」的解析回归（2026-10-16）。
///
/// 起因：用户报告「**账密导入他人课表，全部导入到第一节**」——
/// 账密导入那条链路自己抄了一份只读 `start_slot` 的解析，而**个人课表**返回的
/// 是区间串 `slots: "1-2"`、并没有 `start_slot`，于是每门课都吃到兜底值 1。
/// 现在两条链路共用 [CourseSyncService.courseFromRaw]，这里把两种形状都钉住。
void main() {
  group('courseFromRaw：抓取器两种形状都要吃下', () {
    test('个人课表形状（只有 slots 区间串）不能被塞进第一节', () {
      final c = CourseSyncService.courseFromRaw(<String, dynamic>{
        'name': '高等数学',
        'teacher': '张老师',
        'classroom': 'C1勤学楼112',
        'weekday': 3,
        'slots': '5-6',
        'weeks': '1-16',
      })!;
      expect(c.weekday, 3);
      expect(c.startSlot, 5, reason: '必须从 slots 区间串解析，不能兜底成 1');
      expect(c.endSlot, 6);
      expect(c.name, '高等数学');
      expect(c.classroom, 'C1勤学楼112');
    });

    test('班级课表形状（start_slot / end_slot 是 int）照旧能解析', () {
      final c = CourseSyncService.courseFromRaw(<String, dynamic>{
        'name': '大学英语',
        'weekday': 2,
        'start_slot': 3,
        'end_slot': 4,
        'weeks': '1-8',
      })!;
      expect(c.weekday, 2);
      expect(c.startSlot, 3);
      expect(c.endSlot, 4);
    });

    test('weekday / slots 是字符串也认（教务有时给 "3" / "1-2"）', () {
      final c = CourseSyncService.courseFromRaw(<String, dynamic>{
        'name': '体育',
        'weekday': '7',
        'slots': '7-8',
      })!;
      expect(c.weekday, 7);
      expect(c.startSlot, 7);
      expect(c.endSlot, 8);
    });

    test('单个节次（slots = "5"）→ 起止都是 5', () {
      final c = CourseSyncService.courseFromRaw(<String, dynamic>{
        'name': '形势与政策',
        'weekday': 4,
        'slots': '5',
      })!;
      expect(c.startSlot, 5);
      expect(c.endSlot, 5);
    });

    test('认不出星期 → 返回 null（绝不生成"第一节"的假课）', () {
      expect(
        CourseSyncService.courseFromRaw(<String, dynamic>{
          'name': '某课',
          'weekday': '乱码',
          'slots': '1-2',
        }),
        isNull,
      );
      expect(CourseSyncService.courseFromRaw(<String, dynamic>{
        'name': '某课',
      }), isNull);
    });

    test('id 前缀可区分同步（srv）与导入（imp），且默认是 srv', () {
      final a = CourseSyncService.courseFromRaw(<String, dynamic>{
        'name': 'X', 'weekday': 1, 'slots': '1-2',
      })!;
      final b = CourseSyncService.courseFromRaw(
          <String, dynamic>{'name': 'X', 'weekday': 1, 'slots': '1-2'},
          prefix: 'imp')!;
      expect(a.id.startsWith('srv_'), isTrue);
      expect(b.id.startsWith('imp_'), isTrue);
      expect(a.id, isNot(b.id));
    });
  });
}
