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

  /// 优先级：0=普通，1=重要，2=紧急。
  final int priority;

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

  /// **这条「已完成」归属于哪一天**（`yyyy-MM-dd`）。
  ///
  /// 🔴 为什么需要（2026-10-31）：
  ///    课程待办的 id 是**派生**出来的（`course_<课程id>_<yyyyMMdd>`），
  ///    历史版本没补零时 `2026-01-12` 与 `2026-11-02` 会撞成同一个 id
  ///    `course_5_2026112`。库里一旦存在**同 id 不同日期**的两行，
  ///    仓库里那些「按 id 首个匹配」的写路径就会把 A 天的完成态写到 B 天上
  ///    —— 表现为「查看明日待办时，课程因为时间原因被默认完成，状态延续到今日」。
  ///
  ///    把「完成态属于哪一天」显式记下来之后，完成态天然按天隔离：
  ///    即使 id 撞号，两行的 [completedDay] 不同，互不影响。
  ///
  /// 为空 = 沿用旧的 [completed] 布尔（历史数据兼容）。
  final String? completedDay;

  /// **提前提醒分钟数**（0 = 准点提醒）。
  ///
  /// [dueAt] 是事项本身的时间（"15:30 交作业"），
  /// [reminderTime] 是**实际响铃的时刻** = dueAt − 本字段。
  ///
  /// 2026-10-31：原来待办只能准点提醒（课程提醒才有提前量），
  /// 这里给待办也加上提前档位（提前 5 / 10 / 30 分钟等）。
  final int remindLeadMinutes;

  const Todo({
    required this.id,
    required this.title,
    this.description,
    required this.date,
    this.reminderTime,
    this.completed = false,
    this.priority = 0,
    this.type,
    this.dueAt,
    this.repeatType,
    this.repeatDays = const <int>[],
    this.completedDates = const <String>[],
    this.completedDay,
    this.remindLeadMinutes = 0,
  });

  /// 统一的一天标识（本地时区），用于 [completedDates] / [completedDay]。
  ///
  /// ⚠️ 叫 `dayKeyOf` 而不是 `dayKey`：实例 getter [dayKey] 才是「本条待办
  ///    自己那天的标识」，静态方法要显式传日期 —— 同名会让人误用。
  static String dayKeyOf(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 本条待办**自身日期**的一天标识。
  String get dayKey => Todo.dayKeyOf(date);

  /// **复合身份键**：`id@日期`。
  ///
  /// 🔴 这才是待办真正的身份 —— 不是 `id`。
  ///    课程待办的 id 是派生的，历史撞号会让「同 id 不同日期」的两行共存；
  ///    仓库里所有按 id 单键匹配的写路径（add/addMany/update/delete/
  ///    toggleComplete*）都会因此改错行。
  ///    改用这个键后，跨天串写从根上消失。
  String get compositeKey => '$id@$dayKey';

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

  /// 这一天是否已完成。
  ///
  /// - 重复任务：看 [completedDates] 里有没有这一天；
  /// - 非重复任务且填了 [completedDay]：看它是否等于这一天
  ///   （**按天隔离**，即使 id 撞号也不会串）；
  /// - 非重复任务且没填 [completedDay]（历史数据）：退回 [completed]。
  bool isDoneOn(DateTime day) {
    if (isRepeating) return completedDates.contains(Todo.dayKeyOf(day));
    final cd = completedDay;
    if (cd != null) return cd == Todo.dayKeyOf(day);
    return completed;
  }

  /// 通知 ID：由 [id] 确定性推导，非负、稳定、无随机。
  /// Android 通知 id 为 32 位 int，这里折叠到 31 位正整数区间。
  int get notifyId => stableNotifyId(id);

  /// FNV-1a 哈希 + 固定高位偏移，把任意 id 字符串映射为稳定的通知 id。
  ///
  /// 🔴 为什么要加 `0x40000000` 偏移（2026-11-01 修）：
  ///    「上课提醒」占用 `CourseReminderService` 的
  ///    `_idBase(100000) + dayIndex(0..6)*_dayStride(20) + startSlot(1..12)`
  ///    = 100000..100152 这一整段。而这里原来只把哈希折到 31 位，
  ///    结果可能落进 100000..100152（概率 ≈153/2³¹），一旦撞上就是
  ///    「取消上课提醒时把某条待办提醒一起取消」。
  ///    抬高到 2³⁰ 以上后两段**物理不相交**，不会再撞。
  ///
  /// ⚠️ 改这里会让升级后重新计算的 id 与旧版不同：旧通知靠
  ///    [TodoRepository.rescheduleAll] 里 cancel 掉 tracked 集合来清理，
  ///    正常情况下不会留幽灵通知。
  static int stableNotifyId(String source) {
    var hash = 0x811c9dc5;
    for (final unit in source.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return 0x40000000 + (hash & 0x3FFFFFFF);
  }

  Todo copyWith({
    String? id,
    String? title,
    String? description,
    DateTime? date,
    DateTime? reminderTime,
    bool clearReminder = false,
    bool? completed,
    int? priority,
    String? type,
    DateTime? dueAt,
    bool clearDueAt = false,
    String? repeatType,
    bool clearRepeat = false,
    List<int>? repeatDays,
    List<String>? completedDates,
    String? completedDay,
    bool clearCompletedDay = false,
    int? remindLeadMinutes,
  }) {
    return Todo(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      date: date ?? this.date,
      reminderTime: clearReminder ? null : (reminderTime ?? this.reminderTime),
      completed: completed ?? this.completed,
      priority: priority ?? this.priority,
      type: type ?? this.type,
      dueAt: clearDueAt ? null : (dueAt ?? this.dueAt),
      repeatType: clearRepeat ? null : (repeatType ?? this.repeatType),
      repeatDays: repeatDays ?? this.repeatDays,
      completedDates: completedDates ?? this.completedDates,
      completedDay:
          clearCompletedDay ? null : (completedDay ?? this.completedDay),
      remindLeadMinutes: remindLeadMinutes ?? this.remindLeadMinutes,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'date': date.toIso8601String(),
        'reminderTime': reminderTime?.toIso8601String(),
        'completed': completed,
        'priority': priority,
        'type': type,
        'dueAt': dueAt?.toIso8601String(),
        'repeatType': repeatType,
        'repeatDays': repeatDays,
        'completedDates': completedDates,
        'completedDay': completedDay,
        'remindLeadMinutes': remindLeadMinutes,
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
    // 2026-10-31：完成态归属日。脏数据（非字符串）一律当没有。
    final completedDayRaw = json['completedDay'];
    final completedDay = completedDayRaw is String &&
            completedDayRaw.trim().isNotEmpty
        ? completedDayRaw.trim()
        : null;
    // 2026-10-31：提前提醒分钟数（脏数据 → 0 = 准点）。
    final leadRaw = json['remindLeadMinutes'];
    final remindLeadMinutes =
        leadRaw is num ? leadRaw.toInt().clamp(0, 24 * 60) : 0;
    return Todo(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      description: json['description']?.toString(),
      date: parsedDate ?? DateTime.now(),
      reminderTime: parsedReminder,
      completed: json['completed'] == true || json['completed'] == 1,
      priority: (json['priority'] is num
              ? (json['priority'] as num).toInt()
              : 0)
          .clamp(0, 2),
      type: (typeRaw is String && typeRaw.trim().isNotEmpty)
          ? typeRaw.trim()
          : null,
      dueAt: parsedDue,
      repeatType: repeatType,
      repeatDays: repeatDays,
      completedDates: completedDates,
      completedDay: completedDay,
      remindLeadMinutes: remindLeadMinutes,
    );
  }
}
