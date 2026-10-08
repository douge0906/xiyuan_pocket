import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/services/course_storage.dart';
import 'package:xiyuan_pocket/services/course_sync_service.dart';

/// 课表同步测试（v1.2.0）。
///
/// 背景：开源版把课表页那个「教务系统一键导入」按钮**去掉了**（点开只有一个
/// 选项，白多一次点击），同步改由三个时机自动/半自动完成：
///   · 登录成功后（静默）
///   · 进入 App 时（静默，可在课表设置页关掉，默认开）
///   · 用户点课表页右上角的刷新键（有提示）
///
/// 手动变自动以后，「谁来保证抓的是对的学期」就没人看着了 —— 这个文件主要
/// 就是钉住这一点，以及那次搬迁（`_parseWeekday` / `_parseSlots` 从页面搬到
/// 服务）没有改变行为。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('开学日基准 = 9/7（不是 9/1）', () {
    test('🔴 秋季估算：第 1 周从 9/7 那一周的周一开始', () {
      expect(CourseStorage.defaultSemesterStart(DateTime(2026, 10, 8)),
          DateTime(2026, 9, 7));
      // 9/1 落在周二，mondayOf 之后更靠前 → 整整多算一周
      expect(CourseStorage.defaultSemesterStart(DateTime(2026, 10, 8)),
          isNot(DateTime(2026, 8, 31)));
    });

    test('🔴 自动导入（xqm=3）也必须用 9/7，不能还用 9/1', () {
      expect(CourseStorage.autoSemesterStart('2026', '3'), DateTime(2026, 9, 7));
    });

    test('春季仍是 2/24 那一周的周一', () {
      expect(CourseStorage.autoSemesterStart('2026', '12'), DateTime(2027, 2, 22));
      expect(CourseStorage.defaultSemesterStart(DateTime(2027, 3, 15)),
          DateTime(2027, 2, 22));
    });

    test('🔴 教学周后果：同一个日期，旧基准会多报一周', () {
      final day = DateTime(2026, 10, 8);
      expect(CourseStorage.teachingWeek(day, DateTime(2026, 9, 7)), 5); // 正确
      expect(CourseStorage.teachingWeek(day, DateTime(2026, 8, 31)), 6); // 旧的 9/1 基准
    });
  });

  group('第 1 周的「首次提醒」标记', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('本机没定过 → 需要提醒', () async {
      expect(await CourseStorage.loadSemesterStartConfirmed(), isFalse);
    });

    test('用户跳过（关掉对话框）之后不再提醒', () async {
      await CourseStorage.markSemesterStartConfirmed();
      expect(await CourseStorage.loadSemesterStartConfirmed(), isTrue);
    });

    test('🔴 自动导入写开学日 ≠ 用户定过（否则提醒永远不会出现）', () async {
      await CourseStorage.saveSemesterStart(DateTime(2026, 9, 7));
      expect(await CourseStorage.loadSemesterStartConfirmed(), isFalse,
          reason: '自动同步写的是估算值，是机器填的，不能算「用户已确认」');
    });

    test('用户亲手选的（byUser）→ 已确认', () async {
      await CourseStorage.saveSemesterStart(DateTime(2026, 9, 7), byUser: true);
      expect(await CourseStorage.loadSemesterStartConfirmed(), isTrue);
    });

    test('🔴 老用户不打扰：有日期、没来源标记 → 当成已确认', () async {
      // 当年能写进这个键的只有「导入后提示」和顶部下拉，两条都是用户亲手选的
      SharedPreferences.setMockInitialValues(<String, Object>{
        'course_semester_start': '2026-09-07',
      });
      expect(await CourseStorage.loadSemesterStartConfirmed(), isTrue,
          reason: '只看新标记的话，老用户升级后会被莫名弹一次，'
              '对话框的默认值还可能把本来正确的日期改掉');
    });
  });

  group('学期参数反查（自动同步的地基）', () {
    test('🔴 反函数性质：推出来的学期，其开学日必须与默认估算完全相同', () {
      // 12 个月 × 每个月几个日子，逐一对拍。
      // 这条性质一破，自动同步就会在某个季节悄悄抓错学期的课，
      // 然后把用户正确的课表覆盖掉 —— 而且没人会点按钮，用户根本发现不了。
      for (var month = 1; month <= 12; month++) {
        for (final day in [1, 15, 28]) {
          final now = DateTime(2026, month, day);
          final (xnm, xqm) = CourseStorage.semesterArgsFor(now);
          expect(
            CourseStorage.autoSemesterStart(xnm, xqm),
            CourseStorage.defaultSemesterStart(now),
            reason: '$now 推出来的 ($xnm, $xqm) 开学日对不上',
          );
        }
      }
    });

    test('10 月 → 当年 + 第1学期（秋）', () {
      expect(CourseStorage.semesterArgsFor(DateTime(2026, 10, 8)), ('2026', '3'));
    });

    test('🔴 3 月 → 去年 + 第2学期（春）——写死「当年+第1学期」在这里就抓错', () {
      expect(CourseStorage.semesterArgsFor(DateTime(2027, 3, 15)), ('2026', '12'));
    });

    test('7 月（暑假）仍算春季学期', () {
      expect(CourseStorage.semesterArgsFor(DateTime(2027, 7, 20)), ('2026', '12'));
    });

    test('1 月（寒假）归去年秋季学期，不能算成今年', () {
      expect(CourseStorage.semesterArgsFor(DateTime(2027, 1, 20)), ('2026', '3'));
    });

    test('8 月（暑假尾）已归入秋季学期 —— 与 defaultSemesterStart 的口径一致', () {
      expect(CourseStorage.semesterArgsFor(DateTime(2026, 8, 20)), ('2026', '3'));
    });
  });

  group('开学日该不该被同步覆盖', () {
    final computed = DateTime(2026, 9, 1);

    test('本机没存过 → 写', () {
      expect(CourseSyncService.shouldAdoptSemesterStart(null, computed), isTrue);
    });

    test('用户手动微调过（±7 天）→ 不许写，否则等于白调', () {
      expect(
          CourseSyncService.shouldAdoptSemesterStart(DateTime(2026, 9, 8), computed),
          isFalse);
      expect(
          CourseSyncService.shouldAdoptSemesterStart(DateTime(2026, 8, 25), computed),
          isFalse);
    });

    test('差 30 天以内不写、超过 30 天才写（30 是分界线本身不写）', () {
      expect(
          CourseSyncService.shouldAdoptSemesterStart(DateTime(2026, 10, 1), computed),
          isFalse);
      expect(
          CourseSyncService.shouldAdoptSemesterStart(DateTime(2026, 10, 2), computed),
          isTrue);
    });

    test('明显换学期了（相差约半年）→ 写', () {
      // 春学期开学日 2027-02-24 与秋学期 2026-09-01 相差 176 天
      expect(
          CourseSyncService.shouldAdoptSemesterStart(DateTime(2027, 2, 24), computed),
          isTrue);
    });
  });

  group('教务字段解析（从页面搬到服务，行为必须一模一样）', () {
    test('weekday：数字 / 字符串 / 中文都能认', () {
      expect(CourseSyncService.parseWeekday(3), 3);
      expect(CourseSyncService.parseWeekday('3'), 3);
      expect(CourseSyncService.parseWeekday('周三'), 3);
      expect(CourseSyncService.parseWeekday('周日'), 7);
      expect(CourseSyncService.parseWeekday('周天'), 7);
    });

    test('weekday：认不出来就返回 null（调用方据此跳过该条，而不是当成周一）', () {
      expect(CourseSyncService.parseWeekday(null), isNull);
      expect(CourseSyncService.parseWeekday(''), isNull);
      expect(CourseSyncService.parseWeekday('abc'), isNull);
      expect(CourseSyncService.parseWeekday(0), isNull);
      expect(CourseSyncService.parseWeekday(8), isNull);
      expect(CourseSyncService.parseWeekday('9'), isNull);
    });

    test('slots：区间串（含 ~ 分隔）', () {
      expect(CourseSyncService.parseSlots('1-2', null, null), (1, 2));
      expect(CourseSyncService.parseSlots('3~4', null, null), (3, 4));
    });

    test('slots：多段只取第一段（"1-2,3-4" → 1~2）', () {
      expect(CourseSyncService.parseSlots('1-2,3-4', null, null), (1, 2));
    });

    test('slots：没有区间串时回落到 start_slot / end_slot', () {
      expect(CourseSyncService.parseSlots(null, 5, 7), (5, 7));
      expect(CourseSyncService.parseSlots('', '5', '7'), (5, 7));
      // end 缺失 → 退化成单节
      expect(CourseSyncService.parseSlots(null, 5, null), (5, 5));
    });

    test('slots：全空兜底成第 1 节（不能返回 0 —— 0 在网格里什么都不画）', () {
      expect(CourseSyncService.parseSlots(null, null, null), (1, 1));
    });
  });
}
