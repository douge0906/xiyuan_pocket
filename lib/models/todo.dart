/// 待办事项数据模型。
///
/// 设计要点：
/// 1. [notifyId] 由 [id] **确定性推导**（FNV-1a → 31 位正整数），严禁随机生成。
///    这样 `schedule(notifyId)` 与 `cancel(notifyId)` 永远命中同一条通知，
///    即「一个 Todo ↔ 一个固定 Notification id」的 1:1 映射。
/// 2. [copyWith] 支持通过 [clearReminder] 显式清空提醒时间（`??` 语义无法置空）。
/// 3. [fromJson] 兼容历史数据：旧版本存过 `notifyId` 字段，读取时忽略并按 id 重算，
///    保证升级后同一条待办的通知 id 保持稳定。
class Todo {
  final String id;
  final String title;
  final String? description;
  final DateTime date;
  final DateTime? reminderTime;
  final bool completed;

  /// 2026-10-17（新版首页）：类型标签（作业 / 复习 / 其他）。可空 = 未分类。
  final String? type;

  /// 2026-10-17（新版首页）：这一天的**具体时刻**（含时分），用于「接下来」排序与显示。
  ///
  /// 与 [date] 的分工：[date] 决定它属于哪一天，[dueAt] 决定这一天的什么时候。
  /// 两者都为空时按「全天」处理。
  final DateTime? dueAt;

  /// 重复规则（2026-10-18）：`null` = 不重复；`daily` = 每天；`weekly` = 每周几。
  ///
  /// **存规则而不是展开成多条实体**：否则「每天」一条就要生成几十行，
  /// 首页「之后」列表会被同一件事刷屏。展示时用 [occursOn] 按天展开。
  final String? repeatType;

  /// [repeatType] == `weekly` 时的星期集合（`DateTime.weekday`：1=周一 … 7=周日）。
  final List<int> repeatDays;

  /// 重复任务的「按天完成」记录（`yyyy-MM-dd`）。
  ///
  /// 非重复任务仍用 [completed]；重复任务每条实例各自独立，不能只用一个 bool。
  final List<String> completedDates;

  const Todo({
    required this.id,
    required this.title,
    this.description,
    required this.date,
    this.reminderTime,
    this.completed = false,
    this.type,
    this.dueAt,
    this.repeatType,
    this.repeatDays = const <int>[],
    this.completedDates = const <String>[],
  });

  /// 统一的一天标识（本地时区），用于 [completedDates]。
  static String dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 是否为重复任务。
  bool get isRepeating => repeatType == 'daily' || repeatType == 'weekly';

  /// 这一天要不要显示这条待办（重复任务按规则展开）。
  bool occursOn(DateTime day) {
    final start =
        DateTime(date.year, date.month, date.day);
    final d = DateTime(day.year, day.month, day.day);
    if (d.isBefore(start)) return false;
    switch (repeatType) {
      case 'daily':
        return true;
      case 'weekly':
        return repeatDays.contains(d.weekday);
      default:
        return d == start;
    }
  }

  /// 这一天是否已完成（重复任务按日期记，非重复按 [completed]）。
  bool isDoneOn(DateTime day) =>
      isRepeating ? completedDates.contains(dayKey(day)) : completed;

  /// 通知 ID：由 [id] 确定性推导，非负、稳定、无随机。
  /// Android 通知 id 为 32 位 int，这里折叠到 31 位正整数区间。
  int get notifyId => stableNotifyId(id);

  /// FNV-1a 哈希，把任意 id 字符串映射为稳定的 31 位正整数。
  static int stableNotifyId(String source) {
    var hash = 0x811c9dc5;
    for (final unit in source.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    // 避免 0（部分平台把 0 当作特殊值），落到 0 时偏移为 1。
    return hash == 0 ? 1 : hash;
  }

  Todo copyWith({
    String? id,
    String? title,
    String? description,
    DateTime? date,
    DateTime? reminderTime,
    bool clearReminder = false,
    bool? completed,
    String? type,
    DateTime? dueAt,
    bool clearDueAt = false,
    String? repeatType,
    bool clearRepeat = false,
    List<int>? repeatDays,
    List<String>? completedDates,
  }) {
    return Todo(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      date: date ?? this.date,
      reminderTime: clearReminder ? null : (reminderTime ?? this.reminderTime),
      completed: completed ?? this.completed,
      type: type ?? this.type,
      dueAt: clearDueAt ? null : (dueAt ?? this.dueAt),
      repeatType: clearRepeat ? null : (repeatType ?? this.repeatType),
      repeatDays: repeatDays ?? this.repeatDays,
      completedDates: completedDates ?? this.completedDates,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'date': date.toIso8601String(),
        'reminderTime': reminderTime?.toIso8601String(),
        'completed': completed,
        'type': type,
        'dueAt': dueAt?.toIso8601String(),
        'repeatType': repeatType,
        'repeatDays': repeatDays,
        'completedDates': completedDates,
      };

  /// 从 JSON 还原。**宽松解析**（v2.4.0）：
  /// 字段缺失/类型不符时给默认值而不是抛异常——历史上 `as String` 强转会在
  /// 一条脏数据上抛出，被上层 `catch (_) { return []; }` 吞掉后整份待办被清空。
  factory Todo.fromJson(Map<String, dynamic> json) {
    final rawDate = json['date'];
    final parsedDate =
        rawDate is String ? DateTime.tryParse(rawDate) : null;
    final reminderRaw = json['reminderTime'];
    final parsedReminder = reminderRaw is String && reminderRaw.isNotEmpty
        ? DateTime.tryParse(reminderRaw)
        : null;
    // 2026-10-17：新字段一律宽松解析（缺字段/脏数据都不能把整份待办带崩）
    final typeRaw = json['type'];
    final dueRaw = json['dueAt'];
    final parsedDue =
        dueRaw is String && dueRaw.isNotEmpty ? DateTime.tryParse(dueRaw) : null;
    // 2026-10-18：重复规则三个字段，同样宽松解析（旧数据没有这些字段 → 不重复）。
    final repeatRaw = json['repeatType'];
    final repeatType = (repeatRaw is String && repeatRaw.trim().isNotEmpty)
        ? repeatRaw.trim()
        : null;
    final daysRaw = json['repeatDays'];
    final repeatDays = daysRaw is List
        ? daysRaw
            .whereType<num>()
            .map((e) => e.toInt())
            .where((d) => d >= 1 && d <= 7)
            .toList()
        : <int>[];
    final doneRaw = json['completedDates'];
    final completedDates =
        doneRaw is List ? doneRaw.whereType<String>().toList() : <String>[];
    return Todo(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      description: json['description']?.toString(),
      date: parsedDate ?? DateTime.now(),
      reminderTime: parsedReminder,
      completed: json['completed'] == true || json['completed'] == 1,
      type: (typeRaw is String && typeRaw.trim().isNotEmpty)
          ? typeRaw.trim()
          : null,
      dueAt: parsedDue,
      repeatType: repeatType,
      repeatDays: repeatDays,
      completedDates: completedDates,
    );
  }
}
