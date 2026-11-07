import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/models/grade_stats.dart';

/// 成绩统计口径回归（用户 m19892 #3）。
///
/// 用户原话：「我校评奖评优等只看必修课成绩，选修课成绩是不计入的，
/// 即『60=100』，建议右上角的绩点优先显示『必修课绩点』和
/// 『必修课加权平均成绩』」。
///
/// 这里钉三件事：必修/选修能分开、等级制成绩不污染平均分、空集合不显示 0。
void main() {
  Map<String, dynamic> row(String name, String score, num credit, num jd,
      [String nature = '必修']) {
    return {
      'kcmc': name,
      'cj': score,
      'xf': credit,
      'jd': jd,
      'kcxzmc': nature,
    };
  }

  group('课程性质识别', () {
    test('含「必修」归必修，含「选修」归选修', () {
      expect(kindOfCourse({'kcxzmc': '必修'}), CourseKind.required);
      expect(kindOfCourse({'kcxzmc': '专业必修'}), CourseKind.required);
      expect(kindOfCourse({'kcxzmc': '公共必修课'}), CourseKind.required);
      expect(kindOfCourse({'kcxzmc': '选修'}), CourseKind.elective);
      expect(kindOfCourse({'kcxzmc': '专业选修'}), CourseKind.elective);
    });

    test('没给性质 / 认不出的性质归 unknown，不瞎猜成必修', () {
      // 猜成必修会让绩点虚高，这是评奖场景最不能犯的错。
      expect(kindOfCourse({'kcxzmc': ''}), CourseKind.unknown);
      expect(kindOfCourse({}), CourseKind.unknown);
      expect(kindOfCourse({'kcxzmc': '通识'}), CourseKind.unknown);
    });
  });

  group('绩点与加权', () {
    test('绩点 = Σ(学分×绩点)/Σ学分', () {
      final s = CourseStats.from([
        row('高数', '92', 5, 4.5),
        row('英语', '85', 3, 3.5),
      ]);
      // (5*4.5 + 3*3.5) / 8 = (22.5 + 10.5) / 8 = 4.125
      expect(s.gpa, closeTo(4.125, 1e-9));
      expect(s.credits, 8);
      expect(s.count, 2);
    });

    test('加权 = Σ(学分×分数)/Σ学分', () {
      final s = CourseStats.from([
        row('高数', '92', 5, 4.5),
        row('英语', '85', 3, 3.5),
      ]);
      // (5*92 + 3*85) / 8 = (460 + 255) / 8 = 89.375
      expect(s.average, closeTo(89.375, 1e-9));
      expect(s.avgText, '89.4');
    });

    test('🔴 等级制成绩不计入加权，但学分照样算', () {
      final s = CourseStats.from([
        row('高数', '90', 4, 4.0),
        row('军训', '优秀', 2, 4.0),
        row('形势与政策', '通过', 1, 3.0),
      ]);
      expect(s.credits, 7); // 学分含等级制
      expect(s.scoredCredits, 4); // 只有高数参与平均
      expect(s.average, closeTo(90.0, 1e-9)); // 不能变成 30
      expect(s.count, 3);
    });

    test('没有任何数字成绩时加权显示 —，不显示 0.0', () {
      final s = CourseStats.from([
        row('军训', '优秀', 2, 4.0),
      ]);
      expect(s.scoredCredits, 0);
      expect(s.avgText, '—');
    });

    test('空集合不会算出 NaN', () {
      final s = CourseStats.from(const []);
      expect(s.isEmpty, isTrue);
      expect(s.gpa, 0);
      expect(s.average, 0);
      expect(s.avgText, '—');
    });

    test('字段是字符串也能解析（教务字段类型不稳定）', () {
      final s = CourseStats.from([
        {'kcmc': '物理', 'cj': '88', 'xf': '3.5', 'jd': '3.8', 'kcxzmc': '必修'},
      ]);
      expect(s.credits, 3.5);
      expect(s.average, closeTo(88.0, 1e-9));
      expect(s.gpa, closeTo(3.8, 1e-9));
    });
  });

  group('numericScore', () {
    test('取出分数', () {
      expect(numericScore('92'), 92);
      expect(numericScore(' 85.5 '), 85.5);
      expect(numericScore('92分'), 92);
    });

    test('等级制返回 null 而不是 0', () {
      // 返回 0 会把「优秀」算成不及格，是最严重的静默错误。
      for (final t in ['优秀', '良好', '中等', '及格', '合格', '通过', '免修']) {
        expect(numericScore(t), isNull, reason: t);
      }
      expect(numericScore(''), isNull);
      expect(numericScore(null), isNull);
    });
  });
}
