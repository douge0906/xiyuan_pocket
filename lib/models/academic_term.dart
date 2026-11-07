/// 学年 / 学期码的唯一真源。
///
/// 教务的学期码是两个字：
/// - `xnm` 学年起始年，如 `2026` 表示 **2026-2027 学年**；
/// - `xqm` 学期，`3` = 第一学期（秋季），`12` = 第二学期（春季）。
///
/// 🔴 此前这段推导在 5 个地方各写一遍，而且**有一半是错的**：
/// `month >= 8 ? year : year - 1` 配 `month >= 8 ? '3' : '12'` 在 **1 月**会算成
/// 「上一学年第二学期」—— 但 1 月还在放寒假，属于**上一学年第一学期**，
/// 于是寒假里查成绩 / 考试 / 教材 / 学业全是空的，用户以为教务数据丢了。
///
/// 正确划界（与 `CourseStorage.defaultSemesterStart` 的秋季 9/7、春季 2/24 对齐）：
/// - **8 ~ 12 月**：本学年第一学期（`year`, `3`）
/// - **1 月**：仍属上一年开始的那一学年第一学期（`year - 1`, `3`）
/// - **2 ~ 7 月**：上一年开始的那一学年第二学期（`year - 1`, `12`）
library;

/// 一个学期码。
class AcademicTerm {
  const AcademicTerm(this.year, this.term);

  /// 学年起始年（`2026` 表示 2026-2027 学年）。
  final int year;

  /// `3` = 第一学期（秋），`12` = 第二学期（春）。
  final int term;

  String get xnm => '$year';
  String get xqm => '$term';

  /// 展示用，如 `2026-2027学年 第一学期`。
  String get label => '$year-${year + 1}学年 ${term == 3 ? '第一' : '第二'}学期';

  /// 往更早的学期倒退一步。
  AcademicTerm get previous =>
      term == 3 ? AcademicTerm(year - 1, 12) : AcademicTerm(year, 3);

  @override
  String toString() => '$xnm/$xqm';
}

/// 按当前时间推当前学期。**全项目唯一实现**，不要在别处再写 `month >= 8`。
AcademicTerm currentAcademicTerm([DateTime? at]) {
  final now = at ?? DateTime.now();
  if (now.month >= 8) return AcademicTerm(now.year, 3);
  if (now.month >= 2) return AcademicTerm(now.year - 1, 12);
  // 1 月：寒假，仍属上一年开始的秋季学期
  return AcademicTerm(now.year - 1, 3);
}

/// 当前学期往前共 [n] 个（含当前），越往前越旧。
List<AcademicTerm> recentAcademicTerms(int n, [DateTime? at]) {
  var t = currentAcademicTerm(at);
  final out = <AcademicTerm>[];
  for (var i = 0; i < n; i++) {
    out.add(t);
    t = t.previous;
  }
  return out;
}
