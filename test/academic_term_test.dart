import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/models/academic_term.dart';

/// 学期码推导的回归测试。
///
/// 背景：`month >= 8 ? year : year - 1` 配 `month >= 8 ? '3' : '12'` 这套写法
/// 曾散落在 5 个文件里，**1 月会把寒假算成「上一学年第二学期」** ——
/// 寒假里查成绩 / 考试 / 教材 / 学业全是空的，用户以为教务数据丢了。
/// 现在统一走 [currentAcademicTerm]，这份测试钉住一年的每个月份。
void main() {
  group('currentAcademicTerm', () {
    test('8 月 ~ 12 月 = 本学年第一学期', () {
      for (final m in [8, 9, 10, 11, 12]) {
        final t = currentAcademicTerm(DateTime(2026, m, 15));
        expect(t.year, 2026, reason: '$m 月的学年起始年');
        expect(t.term, 3, reason: '$m 月的学期码');
      }
    });

    test('2 月 ~ 7 月 = 上一年开始的第二学期', () {
      for (final m in [2, 3, 4, 5, 6, 7]) {
        final t = currentAcademicTerm(DateTime(2026, m, 15));
        expect(t.year, 2025, reason: '$m 月属 2025-2026 学年');
        expect(t.term, 12, reason: '$m 月的学期码');
      }
    });

    test('🔴 1 月是寒假，仍属上一年开始的**第一**学期（此前算成第二学期）', () {
      final t = currentAcademicTerm(DateTime(2026, 1, 15));
      expect(t.year, 2025);
      expect(t.term, 3);
      expect(t.xnm, '2025');
      expect(t.xqm, '3');
    });

    test('边界：8 月 1 日已经算新学期', () {
      expect(currentAcademicTerm(DateTime(2026, 8, 1)).xqm, '3');
      expect(currentAcademicTerm(DateTime(2026, 7, 31)).xqm, '12');
    });

    test('边界：2 月 1 日已经算第二学期', () {
      expect(currentAcademicTerm(DateTime(2026, 2, 1)).xqm, '12');
      expect(currentAcademicTerm(DateTime(2026, 1, 31)).xqm, '3');
    });
  });

  group('AcademicTerm', () {
    test('previous 在第一学期时跳回上一学年第二学期', () {
      const t = AcademicTerm(2026, 3);
      expect(t.previous.year, 2025);
      expect(t.previous.term, 12);
    });

    test('previous 在第二学期时跳回同一年第一学期（学年起始年不变）', () {
      const t = AcademicTerm(2025, 12);
      expect(t.previous.year, 2025);
      expect(t.previous.term, 3);
    });

    test('label 格式', () {
      expect(const AcademicTerm(2026, 3).label, '2026-2027学年 第一学期');
      expect(const AcademicTerm(2025, 12).label, '2025-2026学年 第二学期');
    });
  });

  group('recentAcademicTerms', () {
    test('返回条数正确，且从当前学期严格往前倒退', () {
      final list = recentAcademicTerms(8, DateTime(2026, 10, 20));
      expect(list.length, 8);
      expect(list.first.toString(), '2026/3');
      // 逐年逐学期倒退，不能跳、不能重复
      expect(list.map((t) => t.toString()).toList(), [
        '2026/3', // 2026-2027 秋
        '2025/12', // 2025-2026 春
        '2025/3', // 2025-2026 秋
        '2024/12',
        '2024/3',
        '2023/12',
        '2023/3',
        '2022/12',
      ]);
    });

    test('1 月往回推也是对的（不会多出一个不存在的第二学期）', () {
      final list = recentAcademicTerms(4, DateTime(2026, 1, 10));
      expect(list.map((t) => t.toString()).toList(), [
        '2025/3',
        '2024/12',
        '2024/3',
        '2023/12',
      ]);
    });
  });
}
