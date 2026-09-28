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

  const Todo({
    required this.id,
    required this.title,
    this.description,
    required this.date,
    this.reminderTime,
    this.completed = false,
  });

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
  }) {
    return Todo(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      date: date ?? this.date,
      reminderTime: clearReminder ? null : (reminderTime ?? this.reminderTime),
      completed: completed ?? this.completed,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'date': date.toIso8601String(),
        'reminderTime': reminderTime?.toIso8601String(),
        'completed': completed,
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
    return Todo(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      description: json['description']?.toString(),
      date: parsedDate ?? DateTime.now(),
      reminderTime: parsedReminder,
      completed: json['completed'] == true || json['completed'] == 1,
    );
  }
}
