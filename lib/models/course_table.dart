import 'course_model.dart';

/// 一份课表（课表档案）。
///
/// 从本版起，本机可以存**多份**课表：自己的、别人的、上学期的……
/// 每份独立保存课程列表与开学日，随时切换。
///
/// 🔴 关键设计：`CourseStorage.loadCourses()` 永远返回「当前激活的那一份」，
/// 所以下游（课表页 / 首页今日课程 / 上课提醒 / 课表待办 / 桌面小组件 /
/// 推送快照）**不需要知道有多份这回事**，一行都不用改。
///
/// 不属于「一份课表」的东西（故意留在 `CourseStorage` 的全局键里）：
///   · 上课时间块 —— 同一个学校作息一样，切表后时间列不该变
///   · 显示设置（网格线 / 非本周课程 / 背景图 / 自动更新）—— 是「我怎么看」的
///     偏好，不是课表的内容
class CourseTable {
  const CourseTable({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.courses,
    this.semesterStart,
    this.semesterStartSource = srcAuto,
  });

  /// 稳定 id（创建时生成，改名不变）。
  final String id;

  /// 显示用名字，如「我的课表」「张同学的课表」。
  final String name;

  final DateTime createdAt;

  final List<Course> courses;

  /// 第 1 周的周一（教学周基准）。null = 还没定过。
  final DateTime? semesterStart;

  /// 开学日是谁写的：
  ///   · [srcUser] = 用户在界面上选的（顶部「第 N 周」下拉 / 首次确认对话框）
  ///   · [srcAuto] = 导入时按学期估的（秋季 9/7、春季 2/24）
  ///
  /// 这个区别决定要不要给用户弹「请确认第 1 周」——机器填的不算用户定过。
  final String semesterStartSource;

  static const String srcUser = 'user';
  static const String srcAuto = 'auto';

  /// 用户是否亲手定过第 1 周。没定过 → 该提醒一次。
  bool get semesterStartConfirmedByUser => semesterStartSource == srcUser;

  CourseTable copyWith({
    String? name,
    List<Course>? courses,
    DateTime? semesterStart,
    bool clearSemesterStart = false,
    String? semesterStartSource,
  }) {
    return CourseTable(
      id: id,
      name: name ?? this.name,
      createdAt: createdAt,
      courses: courses ?? this.courses,
      semesterStart:
          clearSemesterStart ? null : (semesterStart ?? this.semesterStart),
      semesterStartSource: semesterStartSource ?? this.semesterStartSource,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'courses': courses.map((c) => c.toJson()).toList(),
        'semesterStart': ymd(semesterStart),
        'semesterStartSource': semesterStartSource,
      };

  /// 容错解析：整条坏掉返回 null（调用方跳过这一份，不影响其它份）。
  static CourseTable? fromJson(Object? raw) {
    if (raw is! Map) return null;
    try {
      final m = Map<String, dynamic>.from(raw);
      final id = (m['id'] ?? '').toString();
      if (id.isEmpty) return null;

      final courses = <Course>[];
      final rawCourses = m['courses'];
      if (rawCourses is List) {
        for (final e in rawCourses) {
          try {
            if (e is Map<String, dynamic>) {
              courses.add(Course.fromJson(e));
            } else if (e is Map) {
              courses.add(Course.fromJson(Map<String, dynamic>.from(e)));
            }
          } catch (_) {
            // 单门课坏掉只跳过它 —— 与 CourseStorage._parseCourses 同一口径
          }
        }
      }

      final src = (m['semesterStartSource'] ?? '').toString();
      return CourseTable(
        id: id,
        name: (m['name'] ?? '').toString().isEmpty
            ? '未命名课表'
            : (m['name'] ?? '').toString(),
        createdAt: DateTime.tryParse((m['createdAt'] ?? '').toString()) ??
            DateTime.now(),
        courses: courses,
        semesterStart: parseYmd((m['semesterStart'] ?? '').toString()),
        semesterStartSource: src == srcUser ? srcUser : srcAuto,
      );
    } catch (_) {
      return null;
    }
  }

  /// `YYYY-MM-DD`（与老的 `course_semester_start` 键同一格式）。
  static String? ymd(DateTime? d) {
    if (d == null) return null;
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  static DateTime? parseYmd(String? s) {
    if (s == null || s.isEmpty) return null;
    final d = DateTime.tryParse(s);
    if (d == null) return null;
    return DateTime(d.year, d.month, d.day);
  }
}
