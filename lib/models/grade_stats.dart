/// 课程性质（教务字段 `kcxzmc`）：必修 / 选修 / 未标注。
///
/// 各校字段值不统一（`必修` / `专业必修` / `公共必修` / `选修` / `专业选修` …），
/// 这里只做「含必修 → 必修、含选修 → 选修」的包含判断，其余归 unknown。
/// 宁可归到 unknown 也不瞎猜：unknown 会并进「全部」一行展示，
/// 而不是被静默塞进必修里把绩点算好看。
enum CourseKind { required, elective, unknown }

CourseKind kindOfCourse(Map<String, dynamic> course) {
  final raw = (course['kcxzmc'] ?? course['kcxz'] ?? '').toString().trim();
  if (raw.isEmpty) return CourseKind.unknown;
  if (raw.contains('必修')) return CourseKind.required;
  if (raw.contains('选修')) return CourseKind.elective;
  return CourseKind.unknown;
}

/// 一组课程的成绩统计结果（不可变）。
class CourseStats {
  const CourseStats({
    required this.count,
    required this.credits,
    required this.scoredCredits,
    required this.gpaCredits,
    required this.weightedSum,
    required this.gradePointSum,
  });

  /// 计算一组课程的成绩统计。
  ///
  /// 传入的每个元素是成绩接口里的课程行：
  /// `{kcmc, cj, xf, jd, kcxzmc, jsxm, color}`。字段类型在这些接口里不稳定
  /// （有时字符串有时数字），所以一律走 `tryParse`，缺字段按 0 处理。
  factory CourseStats.from(Iterable<Map<String, dynamic>> courses) {
    var count = 0;
    var credits = 0.0;
    var scoredCredits = 0.0;
    var gpaCredits = 0.0;
    var weightedSum = 0.0;
    var gradePointSum = 0.0;

    for (final c in courses) {
      final credit = _num(c['xf']);
      count++;
      credits += credit;

      final jd = _num(c['jd']);
      if (jd > 0) {
        gpaCredits += credit;
        gradePointSum += credit * jd;
      }

      final score = numericScore(c['cj'] ?? c['bfzcj']);
      if (score != null) {
        scoredCredits += credit;
        weightedSum += credit * score;
      }
    }

    return CourseStats(
      count: count,
      credits: credits,
      scoredCredits: scoredCredits,
      gpaCredits: gpaCredits,
      weightedSum: weightedSum,
      gradePointSum: gradePointSum,
    );
  }

  /// 课程门数。
  final int count;

  /// 总学分（含等级制课程）。
  final double credits;

  /// 参与加权平均的学分（只算有数字成绩的课）。
  final double scoredCredits;

  /// 参与绩点计算的学分（只算教务给了绩点的课）。
  final double gpaCredits;

  final double weightedSum;
  final double gradePointSum;

  bool get isEmpty => count == 0;

  /// 绩点，教务没给绩点时返回 0。
  double get gpa => gpaCredits > 0 ? gradePointSum / gpaCredits : 0;

  /// 加权平均分，没有数字成绩时返回 0。
  double get average => scoredCredits > 0 ? weightedSum / scoredCredits : 0;

  /// 加权平均的显示文本；没有可算的课程时给 `—`，
  /// **不显示 0.0** —— 0.0 会被当成「考了零分」。
  String get avgText => scoredCredits > 0 ? average.toStringAsFixed(1) : '—';
}

double _num(Object? v) {
  if (v is num) return v.toDouble();
  return double.tryParse('${v ?? ''}'.trim()) ?? 0;
}

/// 从成绩文本里取数字分数；等级制（优秀 / 良好 / 通过 / 合格…）返回 null。
double? numericScore(Object? raw) {
  final text = '${raw ?? ''}'.trim();
  if (text.isEmpty) return null;
  final m = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(text);
  if (m == null) return null;
  return double.tryParse(m.group(0)!);
}
