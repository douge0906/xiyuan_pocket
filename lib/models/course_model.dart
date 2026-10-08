import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 课程来源：manual（自主添加）/ server（教务系统导入）
enum CourseSource { manual, server }

/// 周次类型（v2.0.7）：解决"1-16周(单)"写法繁琐的问题，改为选项式。
enum CourseWeekType {
  /// 每周都上（不限制单双）
  every,
  /// 单周上
  odd,
  /// 双周上
  even,
}

/// 上课规律（v2.0.7）：
/// - fixed：固定某天某节（用 weekday 指定周几）
/// - daily：每天的同一节都上（weekday 忽略）
/// - workday：工作日（周一~周五）同一节都上（weekday 忽略）
enum CoursePattern { fixed, daily, workday }

extension CourseWeekTypeX on CourseWeekType {
  String get label => switch (this) {
        CourseWeekType.every => '每周',
        CourseWeekType.odd => '单周',
        CourseWeekType.even => '双周',
      };

  /// 与旧文本格式互转："1-16周(单)" 里的 (单)/(双)
  static CourseWeekType fromOldText(String? raw) {
    final text = (raw ?? '').toLowerCase();
    if (text.contains('单')) return CourseWeekType.odd;
    if (text.contains('双')) return CourseWeekType.even;
    return CourseWeekType.every;
  }
}

extension CoursePatternX on CoursePattern {
  String get label => switch (this) {
        CoursePattern.fixed => '固定',
        CoursePattern.daily => '每天',
        CoursePattern.workday => '工作日',
      };
}

/// 解析周次描述，返回该课程在哪些「周数」上课。
/// 支持格式：
///   - "1-16周" / "1-16" => 1,2,3,...,16
///   - "2-17周(单)" / "2-17(单)" => 2,4,6,...,16（单周）
///   - "8-11周(双)" / "8-11(双)" => 8,10（双周）
///   - "13周" => 13
///   - 多个区间用逗号/分号/空格分隔："1-8周,10-16周"
/// 解析失败返回 null，表示"不限制周次"（每周都显示）。
Set<int>? parseWeeks(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return null;

  final result = <int>{};
  final parts = text.split(RegExp(r'[,，;；\s]+'));
  final rangeRe = RegExp(r'^(\d+)(?:\s*-\s*(\d+))?\s*(?:周|)\s*(?:\((单|双)\))?$');

  for (final part in parts) {
    final t = part.trim();
    if (t.isEmpty) continue;
    final m = rangeRe.firstMatch(t);
    if (m == null) continue;
    final start = int.parse(m.group(1)!);
    final endStr = m.group(2);
    final end = endStr == null ? start : int.parse(endStr);
    final parity = m.group(3); // 单 / 双 / null

    for (int w = start; w <= end; w++) {
      if (parity == '单' && w.isEven) continue;
      if (parity == '双' && w.isOdd) continue;
      result.add(w);
    }
  }

  return result.isEmpty ? null : result;
}

/// 将一组「周数」格式化为标准文本（与 [parseWeeks] 互转）。
/// 例如 {1..16} → "1-16周"；{1,2,3,5,6,7} → "1-3周,5-7周"。
String formatWeeks(Set<int> weeks) {
  if (weeks.isEmpty) return '';
  final sorted = weeks.toList()..sort();
  final ranges = <String>[];
  int start = sorted.first;
  int prev = sorted.first;
  for (int i = 1; i < sorted.length; i++) {
    final w = sorted[i];
    if (w == prev + 1) {
      prev = w;
      continue;
    }
    ranges.add(start == prev ? '$start周' : '$start-$prev周');
    start = w;
    prev = w;
  }
  ranges.add(start == prev ? '$start周' : '$start-$prev周');
  return ranges.join(',');
}

/// 单门课程模型
class Course {
  final String id;
  final String name;
  final String teacher;
  final String classroom;
  final int weekday; // 1=周一 ... 7=周日（pattern=fixed 时有效）
  final int startSlot; // 起始节次 1..12
  final int endSlot; // 结束节次 1..12
  final String weeks; // 周次描述，如 "1-16周" / "1-16周(单)"（旧格式，兼容保留）
  final int colorValue; // 卡片主题色（Color.value）
  final CourseSource source;
  /// v2.0.7：单/双周选项（默认每周）
  final CourseWeekType weekType;
  /// v2.0.7：固定某天 / 每天 / 工作日
  final CoursePattern pattern;

  const Course({
    required this.id,
    required this.name,
    this.teacher = '',
    this.classroom = '',
    required this.weekday,
    required this.startSlot,
    required this.endSlot,
    this.weeks = '',
    required this.colorValue,
    this.source = CourseSource.manual,
    this.weekType = CourseWeekType.every,
    this.pattern = CoursePattern.fixed,
  });

  Course copyWith({
    String? id,
    String? name,
    String? teacher,
    String? classroom,
    int? weekday,
    int? startSlot,
    int? endSlot,
    String? weeks,
    int? colorValue,
    CourseSource? source,
    CourseWeekType? weekType,
    CoursePattern? pattern,
  }) {
    return Course(
      id: id ?? this.id,
      name: name ?? this.name,
      teacher: teacher ?? this.teacher,
      classroom: classroom ?? this.classroom,
      weekday: weekday ?? this.weekday,
      startSlot: startSlot ?? this.startSlot,
      endSlot: endSlot ?? this.endSlot,
      weeks: weeks ?? this.weeks,
      colorValue: colorValue ?? this.colorValue,
      source: source ?? this.source,
      weekType: weekType ?? this.weekType,
      pattern: pattern ?? this.pattern,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'teacher': teacher,
        'classroom': classroom,
        'weekday': pattern == CoursePattern.fixed ? weekday : (pattern == CoursePattern.daily ? 0 : -1),
        'startSlot': startSlot,
        'endSlot': endSlot,
        'weeks': weeks,
        'colorValue': colorValue,
        'source': source == CourseSource.server ? 'server' : 'manual',
        'weekType': weekType.name,
        'pattern': pattern.name,
      };

  factory Course.fromJson(Map<String, dynamic> json) {
    final weekTypeRaw = (json['weekType'] as String?) ?? '';
    final patternRaw = (json['pattern'] as String?) ?? '';
    final weekday = (json['weekday'] as num?)?.toInt() ?? 1;
    // v2.4.0：id 宽松解析——历史上 `json['id'] as String` 会在脏数据上抛异常，
    // 被上层 catch 吞掉后整份课表被清空。缺失/非字符串时用字段指纹生成稳定 id。
    var id = (json['id'] ?? '').toString().trim();
    if (id.isEmpty) {
      id = 'legacy_${_stableHash('${json['name']}|$weekday|${json['startSlot']}|${json['weeks']}')}';
    }
    return Course(
      id: id,
      name: (json['name'] as String?) ?? '',
      teacher: (json['teacher'] as String?) ?? '',
      classroom: (json['classroom'] as String?) ?? '',
      weekday: weekday,
      startSlot: (json['startSlot'] as num?)?.toInt() ?? 1,
      endSlot: (json['endSlot'] as num?)?.toInt() ?? 1,
      weeks: (json['weeks'] as String?) ?? '',
      colorValue: (json['colorValue'] as num?)?.toInt() ?? 0xFF667EEA,
      source: (json['source'] as String? ?? 'manual') == 'server'
          ? CourseSource.server
          : CourseSource.manual,
      weekType: CourseWeekType.values.firstWhere(
        (e) => e.name == weekTypeRaw,
        orElse: () => CourseWeekTypeX.fromOldText((json['weeks'] as String?) ?? ''),
      ),
      pattern: CoursePattern.values.firstWhere(
        (e) => e.name == patternRaw,
        orElse: () {
          // 旧数据兼容：weekday=0 每天 / -1 工作日 / 其余固定
          if (weekday == 0) return CoursePattern.daily;
          if (weekday == -1) return CoursePattern.workday;
          return CoursePattern.fixed;
        },
      ),
    );
  }

  /// 当前课程在指定周是否上课（v2.0.7：单/双周选项与旧文本格式都支持）。
  bool isActiveOnWeek(int week) {
    if (weekType == CourseWeekType.odd && week.isEven) return false;
    if (weekType == CourseWeekType.even && week.isOdd) return false;
    final set = parseWeeks(weeks);
    if (set == null) return true;
    return set.contains(week);
  }

  /// 该课程是否在 [weekday]（1=周一..7=周日）的教学周 [week] 当天上课。
  /// v2.3.1：唯一真相源——课表页/上课提醒/桌面小组件共用，
  /// 此前同一段 switch 判定在三个文件各有一份拷贝。
  bool occursOn(int weekday, int week) {
    if (!isActiveOnWeek(week)) return false;
    return switch (pattern) {
      CoursePattern.fixed => this.weekday == weekday,
      CoursePattern.daily => true,
      CoursePattern.workday => weekday >= 1 && weekday <= 5,
    };
  }
}

/// 课程表调色板：复刻参考 App A（掌上徐工）的 24 色浅色调色板。
const List<int> coursePalette = [
  0xFFF8D2D7, // 粉红
  0xFFD2E5F8, // 浅蓝
  0xFFD2F0E5, // 薄荷
  0xFFF8F3D2, // 奶黄
  0xFFE5D2F8, // 浅紫
  0xFFF8E5D2, // 蜜桃
  0xFFF2C6D0, // 玫瑰
  0xFFC6E0F2, // 天蓝
  0xFFC6F2E0, // 青绿
  0xFFF2F0C6, // 浅黄
  0xFFE0C6F2, // 藕紫
  0xFFF2E0C6, // 杏色
  0xFFEBBFC9, // 豆沙
  0xFFBFD8EB, // 雾蓝
  0xFFBFEBDC, // 湖绿
  0xFFEBE8BF, // 橄榄黄
  0xFFD8BFEB, // 丁香
  0xFFEBD8BF, // 卡其
  0xFFF6D9DF, // 樱粉
  0xFFD9EAF6, // 冰蓝
  0xFFD9F6EC, // 嫩绿
  0xFFF6F4D9, // 奶白
  0xFFEAD9F6, // 薰衣草
  0xFFF6EAD9, // 浅棕
];

/// 旧版饱和调色板：仅用于一次性迁移到浅色调色板。
const List<int> coursePaletteLegacy = [
  0xFF667EEA,
  0xFF764BA2,
  0xFF10B981,
  0xFF3B82F6,
  0xFFEC4899,
  0xFF14B8A6,
  0xFF8B5CF6,
  0xFFF97316,
  0xFF0EA5E9,
  0xFFEF4444,
  0xFF22C55E,
  0xFFA855F7,
];

/// 将旧版饱和色迁移到复刻 App A 的浅色调色板（按索引对应），其余颜色原样返回。
int migrateCourseColor(int value) {
  final idx = coursePaletteLegacy.indexOf(value);
  if (idx >= 0 && idx < coursePalette.length) return coursePalette[idx];
  return value;
}

int colorForName(String name) {
  if (name.isEmpty) return coursePalette.first;
  return coursePalette[name.hashCode.abs() % coursePalette.length];
}

/// 根据背景色亮度返回合适的文字颜色
Color textOnColor(Color bg) {
  // 相对亮度（Rec. 601）
  final luminance =
      (0.299 * bg.red + 0.587 * bg.green + 0.114 * bg.blue) / 255;
  return luminance > 0.62 ? AppTheme.textPrimaryLight : Colors.white;
}

/// FNV-1a 稳定哈希（非负）：为缺失 id 的历史课程生成**跨运行稳定**的 id。
/// 不能直接用 [Object.hashCode]——Map/String 的 hashCode 在部分实现下不稳定，
/// 会导致同一门课每次启动换 id，进而重复导入。
int _stableHash(String source) {
  var hash = 0x811c9dc5;
  for (final unit in source.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash;
}
