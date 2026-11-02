import 'dart:convert';

/// 「我的学业」数据模型 + 状态推导（纯 Dart，无 IO，便于单测）。
///
/// 数据来源：正方教务 `xsxyqk_cxXsxyqkIndex.html`（学业情况查询，gnmkdm=N105515）。
///
/// ## 两种模式
///
/// 教务是否返回培养方案树，取决于**学校有没有给这一届配培养方案**：
///
/// · **Mode A（有树）**：2025 级及更早。板块 = 培养方案节点，课程带权威 `XDZT`。
/// · **Mode B（无树）**：2026 级新生。教务页直接返回「您所在年级专业没有教学计划」，
///   此时只能按本学期课表的 `kclb` 分组，状态由客户端推导，**必须在 UI 上标注来源**。
///
/// 用户要求（2026-11-02）：「查不到就显示暂未配置」——Mode B 不再伪装成完整学业档案，
/// 而是明确告知「教务暂未配置培养方案」，只用课表数据提供有限信息。

/// 修读状态（对外展示的唯一口径）。
///
/// 与教务 `XDZT` 的对应关系见 [StudyCourse.fromXdfz]。
/// ⚠️ 教务页面把「已修」和「校内被替代」算在一起计入「通过门数」
/// （实测：通识（必）27 门中 XDZT 4/5 共 14 门，与教务显示的「通过 14 门」一致），
/// 所以 [StudyState.passed] 在排序与统计里也被视为「已通过」。
enum StudyState {
  /// 在读（`XDZT=1`）—— 当前学期正在修。
  studying('在读'),

  /// 未过（`XDZT=2`）—— 修过但没通过，需要重修。**优先级最高**。
  failed('未过'),

  /// 未修（`XDZT=3`）—— 培养方案要求但还没开始修。
  notStarted('未修'),

  /// 已修（`XDZT=4` / `21`）—— 正常通过。
  passed('已修'),

  /// 替代 / 认定（`XDZT=5`~`8`）—— 校内课程替代、校外课程认定等，
  /// 教务页面视同「已通过」，但要在详情里说明来源。
  replaced('已修·替代');

  const StudyState(this.label);

  /// 展示用中文。与教务页面用词保持一致，用户对照学校系统时不会错位。
  final String label;

  /// 是否计入「已通过」（**照抄教务口径**：4/5/6/7/8/21 都算）。
  bool get isCountedPassed =>
      this == StudyState.passed || this == StudyState.replaced;

  /// 排序权重：越紧急越靠前。用户要求「在读等状态优先排」。
  ///
  /// 未过(0) → 在读(1) → 未修(2) → 已修(3) → 替代(4)
  int get sortWeight => switch (this) {
        StudyState.failed => 0,
        StudyState.studying => 1,
        StudyState.notStarted => 2,
        StudyState.passed => 3,
        StudyState.replaced => 4,
      };

  /// 从教务 `XDZT` 码还原状态。未知码一律按 [StudyState.passed] 兜底 ——
  /// 宁可少标一个「未过」，也不要把已有成绩的课误判成没修过。
  ///
  /// | XDZT | 含义 | 本文 |
  /// |---|---|---|
  /// | 1 | 在修 | studying |
  /// | 2 | 未过 | failed |
  /// | 3 | 未修 | notStarted |
  /// | 4 / 21 | 已修 | passed |
  /// | 5 / 6 | 校内替代 / 被替代 | replaced |
  /// | 7 / 8 | 节点替代 / 校外认定 | replaced |
  static StudyState fromXdzt(String? raw) {
    switch (raw?.trim()) {
      case '1':
        return StudyState.studying;
      case '2':
        return StudyState.failed;
      case '3':
        return StudyState.notStarted;
      case '4':
      case '21':
        return StudyState.passed;
      case '5':
      case '6':
      case '7':
      case '8':
        return StudyState.replaced;
      default:
        return StudyState.passed;
    }
  }
}

/// 一门课（学业档案视角）。
class StudyCourse {
  const StudyCourse({
    required this.courseNo,
    required this.name,
    required this.credits,
    required this.hours,
    required this.nature,
    required this.category,
    required this.state,
    this.score = '',
    this.maxScore = '',
    this.gpa = '',
    this.studyYear = '',
    this.studyTerm = '',
    this.suggestYear = '',
    this.suggestTerm = '',
    this.stateFromServer = true,
  });

  /// 课程号（`KCH`）。同一门课不同教学班共用课号。
  final String courseNo;

  /// 课程名称（`KCMC`）。
  final String name;

  /// 学分（`XF`）。
  final double credits;

  /// 学时组成原文（`XSXXXX`），如「讲课(6.0)」「讲课(3.0)-实验(1.0)」。
  final String hours;

  /// 课程性质（`KCXZMC`）：必修 / 选修。
  final String nature;

  /// 课程类别（`KCLBMC`）：通识必修课 / 专业基础课 / …
  /// **Mode B 下它就是板块名。**
  final String category;

  final StudyState state;

  /// 成绩（`CJ`）。未出分时为空串。
  final String score;

  /// 最高成绩（`MAXCJ`）。
  final String maxScore;

  /// 绩点（`JD`）。
  final String gpa;

  /// 实际修读学年（`XNM` → 「2025-2026」）。
  final String studyYear;

  /// 实际修读学期（`XQMMC`）。
  final String studyTerm;

  /// 建议修读学年（`JYXDXNM`）。
  final String suggestYear;

  /// 建议修读学期（`JYXDXQMC`）。
  final String suggestTerm;

  /// 状态是否来自教务权威 `XDZT`。
  ///
  /// `false` 表示是客户端按课表/成绩推导出来的 —— UI 必须据此在页脚标注
  /// 「状态为客户端推导」，不能让人以为和学校系统完全一致。
  final bool stateFromServer;

  /// 已出分？（有成绩或绩点任一非空）
  bool get hasScore => score.trim().isNotEmpty || gpa.trim().isNotEmpty;

  /// 单行副标题：`必修 · 6.0学分 · 讲课(6.0)`
  ///
  /// 用户要求「课程只标注重要信息」，所以只给这三项，多余的不放。
  String get subtitleLine {
    final parts = <String>[];
    if (nature.isNotEmpty) parts.add(nature);
    parts.add('${_trimZero(credits)}学分');
    if (hours.isNotEmpty) parts.add(hours);
    return parts.join(' · ');
  }

  /// 从教务 JSON 建对象。字段名全大写（与实测一致）。
  ///
  /// 实测 25 个字段里只取展示必需的 12 个，其余不落地 —— 省内存也省缓存体积。
  factory StudyCourse.fromJwgl(Map<String, dynamic> m) {
    String pick(List<String> keys) {
      for (final k in keys) {
        final v = m[k];
        if (v != null && v.toString().trim().isNotEmpty) {
          return v.toString().trim();
        }
      }
      return '';
    }

    final rawYear = pick(['XNM', 'JYXDXNM']);
    final studyYear = pick(['XNMC']).isNotEmpty
        ? pick(['XNMC'])
        : _academicYear(rawYear);

    return StudyCourse(
      courseNo: pick(['KCH', 'KCH_ID']),
      name: pick(['KCMC']),
      credits: double.tryParse(pick(['XF'])) ?? 0,
      hours: pick(['XSXXXX']),
      nature: pick(['KCXZMC']),
      category: pick(['KCLBMC']),
      state: StudyState.fromXdzt(pick(['XDZT'])),
      score: pick(['CJ']),
      maxScore: pick(['MAXCJ']),
      gpa: pick(['JD']),
      studyYear: studyYear,
      studyTerm: pick(['XQMMC']),
      suggestYear: _academicYear(pick(['JYXDXNM'])),
      suggestTerm: pick(['JYXDXQMC']),
      stateFromServer: pick(['XDZT']).isNotEmpty,
    );
  }

  Map<String, dynamic> toJson() => {
        'courseNo': courseNo,
        'name': name,
        'credits': credits,
        'hours': hours,
        'nature': nature,
        'category': category,
        'state': state.name,
        'score': score,
        'maxScore': maxScore,
        'gpa': gpa,
        'studyYear': studyYear,
        'studyTerm': studyTerm,
        'suggestYear': suggestYear,
        'suggestTerm': suggestTerm,
        'stateFromServer': stateFromServer,
      };

  factory StudyCourse.fromJson(Map<String, dynamic> m) => StudyCourse(
        courseNo: (m['courseNo'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
        credits: (m['credits'] as num?)?.toDouble() ?? 0,
        hours: (m['hours'] ?? '').toString(),
        nature: (m['nature'] ?? '').toString(),
        category: (m['category'] ?? '').toString(),
        state: StudyState.values.firstWhere(
          (s) => s.name == m['state'],
          orElse: () => StudyState.passed,
        ),
        score: (m['score'] ?? '').toString(),
        maxScore: (m['maxScore'] ?? '').toString(),
        gpa: (m['gpa'] ?? '').toString(),
        studyYear: (m['studyYear'] ?? '').toString(),
        studyTerm: (m['studyTerm'] ?? '').toString(),
        suggestYear: (m['suggestYear'] ?? '').toString(),
        suggestTerm: (m['suggestTerm'] ?? '').toString(),
        stateFromServer: m['stateFromServer'] == true,
      );
}

/// 一个板块（Mode A = 培养方案节点，Mode B = 课表课程类别）。
class StudyBlock {
  const StudyBlock({
    required this.id,
    required this.name,
    required this.courses,
    this.requiredCredits,
    this.earnedCredits,
    this.requiredDoors,
    this.passedDoors,
    this.passedByServer,
  });

  /// 节点 id（Mode A 是 32 位 `xfyqjd_id`；Mode B 用类别名）。
  final String id;

  /// 板块名。**保持教务原文**（通识（必）/ 专基（必）…），不改短 ——
  /// 用户对照学校系统是同一个词，改短反而对不上（2026-11-02 决策）。
  final String name;

  final List<StudyCourse> courses;

  /// 要求学分。**只有根节点有意义**：教务给子节点一律渲染 `1.0`（实测 10 个
  /// 子节点全是这个怪值），所以子节点这里保持 null，改由 [courseCredits] 展示。
  final double? requiredCredits;

  /// 已获得学分（`yxxf`，教务算好的，不自己加）。
  final double? earnedCredits;

  /// 要求门次（`thzt`）。教务页面显示但实测恒为 0，故保留字段暂不用。
  final int? requiredDoors;

  /// 通过门数。优先后端 `thzt`，取不到则由课程 `XDZT` 实时统计。
  final int? passedDoors;

  /// 通过门数是否来自教务（`thzt` 实测恒为 `0,0,0` 不可用，因此通常为 null）。
  final int? passedByServer;

  /// 板块内课程总门数。
  int get courseCount => courses.length;

  /// 板块内课程学分合计 —— 子节点「要求学分 1.0」的替代口径。
  double get courseCredits =>
      courses.fold<double>(0, (sum, c) => sum + c.credits);

  /// 已通过门数（照抄教务口径：4/5/6/7/8/21 都算通过）。
  int get passedCount =>
      passedDoors ?? courses.where((c) => c.state.isCountedPassed).length;

  /// 未达标门数 —— 决定板块右上角的状态点颜色。
  ///
  /// 教务规则：`未达到要求 = 要求门次 - 到达要求`，实测要求门次恒为 1、
  /// 到达要求 0 或 N，因此简化为「有未通过项即为未达标」。
  bool get hasUnmet => passedCount < courseCount;

  /// 是否全部完成（有课且全部通过）。
  bool get isComplete => courses.isNotEmpty && passedCount == courseCount;

  /// 完成度 0..1（用于细进度条）。板块内无课时返回 0。
  double get progress {
    if (courses.isEmpty) return 0;
    return (passedCount / courseCount).clamp(0.0, 1.0);
  }

  StudyBlock copyWith({List<StudyCourse>? courses}) => StudyBlock(
        id: id,
        name: name,
        courses: courses ?? this.courses,
        requiredCredits: requiredCredits,
        earnedCredits: earnedCredits,
        requiredDoors: requiredDoors,
        passedDoors: passedDoors,
        passedByServer: passedByServer,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'courses': courses.map((c) => c.toJson()).toList(),
        'requiredCredits': requiredCredits,
        'earnedCredits': earnedCredits,
        'requiredDoors': requiredDoors,
        'passedDoors': passedDoors,
        'passedByServer': passedByServer,
      };

  factory StudyBlock.fromJson(Map<String, dynamic> m) => StudyBlock(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
        courses: ((m['courses'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => StudyCourse.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        requiredCredits: (m['requiredCredits'] as num?)?.toDouble(),
        earnedCredits: (m['earnedCredits'] as num?)?.toDouble(),
        requiredDoors: (m['requiredDoors'] as num?)?.toInt(),
        passedDoors: (m['passedDoors'] as num?)?.toInt(),
        passedByServer: (m['passedByServer'] as num?)?.toInt(),
      );
}

/// 「我的学业」整页数据。
class StudyArchive {
  const StudyArchive({
    required this.mode,
    required this.blocks,
    this.studentName = '',
    this.major = '',
    this.gradeYear = '',
    this.gpa,
    this.totalCourses,
    this.passedCourses,
    this.failedCourses,
    this.notStartedCourses,
    this.studyingCourses,
    this.requiredCredits,
    this.earnedCredits,
    this.fetchedAt,
    this.notice = '',
  });

  /// 数据完整性模式。
  final StudyMode mode;

  final List<StudyBlock> blocks;

  /// 学生姓名（教务页顶部「XX 同学」）。
  final String studentName;

  /// 专业名（根节点名，如「2025电气工程及其自动化」）。
  final String major;

  /// 年级（从专业名或学生信息推导，如「2025」）。
  final String gradeYear;

  /// 平均学分绩点。**Mode B 下通常为 null**（那要成绩接口，学期初常拿不到）。
  final double? gpa;

  /// 下列五个数字**全部照抄教务页顶部汇总**，不自己算 ——
  /// 自己算的口径必然和学校页面不一致，用户一看就发现对不上。
  final int? totalCourses;
  final int? passedCourses;
  final int? failedCourses;
  final int? notStartedCourses;
  final int? studyingCourses;

  /// 总要求学分 / 总已获学分（Mode A 取自根节点 `yqzdxf` / `yxxf`）。
  final double? requiredCredits;
  final double? earnedCredits;

  final DateTime? fetchedAt;

  /// 页脚提示（Mode B 为「教务暂未配置培养方案」；Mode A 为空）。
  final String notice;

  /// 是否为「教务暂未配置」的降级态。
  bool get isUnconfigured => mode == StudyMode.unconfigured;

  /// 是否有培养方案树。
  bool get isFull => mode == StudyMode.full;

  /// 全部课程（跨板块扁平化）。
  List<StudyCourse> get allCourses =>
      blocks.expand((b) => b.courses).toList();

  /// 按状态筛选后的板块（空板块自动剔除）。
  List<StudyBlock> filtered(Set<StudyState> states) {
    if (states.isEmpty) return blocks;
    final out = <StudyBlock>[];
    for (final b in blocks) {
      final kept = b.courses.where((c) => states.contains(c.state)).toList();
      if (kept.isNotEmpty) out.add(b.copyWith(courses: kept));
    }
    return _sortBlocks(out);
  }

  /// 各状态课程数（筛选 chip 上的角标）。
  Map<StudyState, int> get stateCounts {
    final out = <StudyState, int>{for (final s in StudyState.values) s: 0};
    for (final c in allCourses) {
      out[c.state] = (out[c.state] ?? 0) + 1;
    }
    return out;
  }

  /// 板块默认排序：**未过 > 在读 > 未修 > 已修 > 替代**。
  ///
  /// 与课程排序同一套权重，用户要求「在读等状态优先排」。
  static List<StudyBlock> _sortBlocks(List<StudyBlock> blocks) {
    int blockWeight(StudyBlock b) {
      if (b.courses.isEmpty) return 99;
      return b.courses
          .map((c) => c.state.sortWeight)
          .reduce((a, c) => a < c ? a : c);
    }

    final out = List<StudyBlock>.from(blocks);
    out.sort((a, b) {
      final d = blockWeight(a).compareTo(blockWeight(b));
      if (d != 0) return d;
      return a.name.compareTo(b.name);
    });
    return out;
  }

  /// 对外暴露的板块排序（与 [filtered] 内部用的是同一套规则）。
  ///
  /// 抓取层拿到板块后直接调它，避免排序逻辑在 client 里再写一份。
  static List<StudyBlock> sortBlocks(List<StudyBlock> blocks) =>
      _sortBlocks(blocks);

  /// 板块内课程排序：同一套权重，同权重按课程名。
  static List<StudyCourse> sortCourses(List<StudyCourse> courses) {
    final out = List<StudyCourse>.from(courses);
    out.sort((a, b) {
      final d = a.state.sortWeight.compareTo(b.state.sortWeight);
      if (d != 0) return d;
      return a.name.compareTo(b.name);
    });
    return out;
  }

  StudyArchive copyWith({List<StudyBlock>? blocks}) => StudyArchive(
        mode: mode,
        blocks: blocks ?? this.blocks,
        studentName: studentName,
        major: major,
        gradeYear: gradeYear,
        gpa: gpa,
        totalCourses: totalCourses,
        passedCourses: passedCourses,
        failedCourses: failedCourses,
        notStartedCourses: notStartedCourses,
        studyingCourses: studyingCourses,
        requiredCredits: requiredCredits,
        earnedCredits: earnedCredits,
        fetchedAt: fetchedAt,
        notice: notice,
      );

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'blocks': blocks.map((b) => b.toJson()).toList(),
        'studentName': studentName,
        'major': major,
        'gradeYear': gradeYear,
        'gpa': gpa,
        'totalCourses': totalCourses,
        'passedCourses': passedCourses,
        'failedCourses': failedCourses,
        'notStartedCourses': notStartedCourses,
        'studyingCourses': studyingCourses,
        'requiredCredits': requiredCredits,
        'earnedCredits': earnedCredits,
        'fetchedAt': fetchedAt?.toIso8601String(),
        'notice': notice,
      };

  factory StudyArchive.fromJson(Map<String, dynamic> m) => StudyArchive(
        mode: StudyMode.values.firstWhere(
          (e) => e.name == m['mode'],
          orElse: () => StudyMode.unconfigured,
        ),
        blocks: ((m['blocks'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => StudyBlock.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        studentName: (m['studentName'] ?? '').toString(),
        major: (m['major'] ?? '').toString(),
        gradeYear: (m['gradeYear'] ?? '').toString(),
        gpa: (m['gpa'] as num?)?.toDouble(),
        totalCourses: (m['totalCourses'] as num?)?.toInt(),
        passedCourses: (m['passedCourses'] as num?)?.toInt(),
        failedCourses: (m['failedCourses'] as num?)?.toInt(),
        notStartedCourses: (m['notStartedCourses'] as num?)?.toInt(),
        studyingCourses: (m['studyingCourses'] as num?)?.toInt(),
        requiredCredits: (m['requiredCredits'] as num?)?.toDouble(),
        earnedCredits: (m['earnedCredits'] as num?)?.toDouble(),
        fetchedAt: DateTime.tryParse((m['fetchedAt'] ?? '').toString()),
        notice: (m['notice'] ?? '').toString(),
      );

  /// 空档案（拿不到任何数据时兜底，UI 展示「暂未配置」）。
  static StudyArchive unconfigured({String notice = ''}) => StudyArchive(
        mode: StudyMode.unconfigured,
        blocks: const [],
        notice: notice.isEmpty ? kUnconfiguredNotice : notice,
      );
}

/// 数据完整性模式。
enum StudyMode {
  /// 教务返回了完整培养方案树（2025 级及更早）。
  full('培养方案'),

  /// 教务没有给这一届配培养方案（2026 级新生），只有课表可用。
  degraded('仅课表'),

  /// 什么都拿不到 —— 按用户要求显示「教务暂未配置」，不硬凑数据。
  unconfigured('暂未配置');

  const StudyMode(this.label);
  final String label;
}

/// Mode B / 拿不到树时的统一文案。
///
/// 用户 2026-11-02 明确要求：「查不到就显示暂未配置」。
/// 所以这里不给「加载中」「暂无数据」这类含糊话，直接说清楚是谁没配。
const String kUnconfiguredNotice = '教务暂未配置培养方案，暂时只能读取本学期课表';

/// Mode B 的说明后缀（有课表但没培养方案时用）。
const String kDegradedNotice = '教务暂未配置培养方案，当前按课程类别分组，状态为客户端推导';

/// `2025` → `2025-2026`。
String _academicYear(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return '';
  final y = int.tryParse(v);
  if (y == null) return v;
  return '$v-${y + 1}';
}

/// `6.0` → `6`，`2.5` → `2.5`。学分展示不拖 `.0` 尾巴。
String _trimZero(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toStringAsFixed(1);
}

/// 板块 JSON 顶层（缓存文件结构）。
String encodeArchive(StudyArchive a) => jsonEncode(a.toJson());

StudyArchive? decodeArchive(String raw) {
  try {
    final v = jsonDecode(raw);
    if (v is! Map) return null;
    return StudyArchive.fromJson(Map<String, dynamic>.from(v));
  } catch (_) {
    return null;
  }
}
