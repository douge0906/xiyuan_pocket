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

/// 旧版饱和色迁移到复刻 App A 的浅色调色板（按索引对应），其余颜色原样返回。
int migrateCourseColor(int value) {
  final idx = coursePaletteLegacy.indexOf(value);
  if (idx >= 0 && idx < coursePalette.length) return coursePalette[idx];
  return value;
}

// ---------------- 自动分色：暖色优先（v1.7.1）----------------
//
// 用户要求：「优化色彩的随机化，暖色优先」。
//
// 按色相把调色板劈成两组（各 12 色）：暖色 = 红/橙/黄/粉系（hue 落在 300°~60°），
// 其余为冷色 = 蓝/绿/紫系。**单独列出而不是复用调色板顺序** ——
// 调色板的顺序是给课程表单那 24 个色点看的，不该被分配策略绑住。

/// 暖色 12 色（粉 / 玫瑰 / 豆沙 / 樱粉 / 奶黄 / 浅黄 / 橄榄黄 / 奶白 / 蜜桃 / 杏色 / 卡其 / 浅棕）。
const List<int> courseWarmColors = <int>[
  0xFFF8D2D7, // 粉红
  0xFFF2C6D0, // 玫瑰
  0xFFEBBFC9, // 豆沙
  0xFFF6D9DF, // 樱粉
  0xFFF8F3D2, // 奶黄
  0xFFF2F0C6, // 浅黄
  0xFFEBE8BF, // 橄榄黄
  0xFFF6F4D9, // 奶白
  0xFFF8E5D2, // 蜜桃
  0xFFF2E0C6, // 杏色
  0xFFEBD8BF, // 卡其
  0xFFF6EAD9, // 浅棕
];

/// 冷色 12 色（浅蓝 / 天蓝 / 雾蓝 / 冰蓝 / 薄荷 / 青绿 / 湖绿 / 嫩绿 / 浅紫 / 藕紫 / 丁香 / 薰衣草）。
const List<int> courseCoolColors = <int>[
  0xFFD2E5F8, // 浅蓝
  0xFFC6E0F2, // 天蓝
  0xFFBFD8EB, // 雾蓝
  0xFFD9EAF6, // 冰蓝
  0xFFD2F0E5, // 薄荷
  0xFFC6F2E0, // 青绿
  0xFFBFEBDC, // 湖绿
  0xFFD9F6EC, // 嫩绿
  0xFFE5D2F8, // 浅紫
  0xFFE0C6F2, // 藕紫
  0xFFD8BFEB, // 丁香
  0xFFEAD9F6, // 薰衣草
];

/// 按课程名自动分色（v1.7.1：**暖色优先**）。
///
/// 做法：3 份里 2 份落到暖色组、1 份落到冷色组 ——
/// 整张课表偏暖但不至于清一色暖，同色组内仍靠哈希分散（不会全班一个色）。
///
/// ⚠️ 只影响**新分配**的颜色：已有课程的颜色是建档时写死在 `colorValue` 里的，
///    不迁移、不变色（老用户升级后课表不会突然换色）。
int colorForName(String name) {
  if (name.isEmpty) return coursePalette.first;
  final h = name.hashCode.abs();
  final pool = (h % 3 == 0) ? courseCoolColors : courseWarmColors;
  return pool[(h ~/ 3) % pool.length];
}


// ---------------- 课节色块「色彩方案」（v1.6.9，2026-10-13）----------------
//
// 用户需求：「课节色块提供不同色彩方案」。v1.7.1 起名字统一为
// **方案一 / 方案二 / 方案三**（不再叫「默认色彩 / 清淡 / 鲜明」）。
//
// 🔴 关键设计：方案只在**渲染期**转换，绝不写回 `course.colorValue`。
//    这样切方案立即全局生效、随时切回来，也完全不需要数据迁移；
//    而课程本身的「主题色」选择（课程表单词选的那 24 色）保持原样不动。
//
// ⚠️ 存储值仍是枚举的 `name`（standard/soft/vivid）——**改 label 不动 name**，
//    老用户已选的方案不会因为改名而丢失。
enum CourseColorScheme {
  standard('方案一'),
  soft('方案二'),
  vivid('方案三');

  const CourseColorScheme(this.label);

  /// 设置页展示用的名字。
  final String label;

  /// 从存储值解析（容错：未知/缺失一律回落「方案一」，老用户升级无感）。
  static CourseColorScheme parse(Object? v) {
    final s = '$v';
    for (final e in values) {
      if (e.name == s) return e;
    }
    return CourseColorScheme.standard;
  }
}

/// 按方案把课程「主题色」转换成最终底色（同色相调整饱和度 / 亮度）。
Color courseColorFor(int colorValue, CourseColorScheme scheme) {
  final base = Color(colorValue);
  switch (scheme) {
    case CourseColorScheme.standard:
      return base;
    case CourseColorScheme.soft:
      return _softColor(base);
    case CourseColorScheme.vivid:
      // 鲜明：提饱和 + 轻微压暗 → 课程之间更好区分
      return _shiftColor(base, satScale: 1.50, darken: 0.06);
  }
}

/// 柔彩（方案二）—— 用户原话：「柔彩，超级课程表那种色彩」。
///
/// 柔彩 != 「把颜色洗淡」：
///  · **色相完全不动**（粉还是粉、蓝还是蓝，靠色相认课不能丢）；
///  · 饱和度只温柔地下压一档（×0.72），并且**保底 0.40** ——
///    这一条是上一版最大的毛病所在：上一版压到 ×0.40 又提亮 12%，
///    结果色块变成「发白的灰粉 / 灰蓝」，跟「非本周课程」的那片淡灰几乎撞脸；
///  · 亮度统一往 0.90 轻轻归一（只走 35% 的差距），让整屏颜色看着更协调，
///    但**不给本来就浅的颜色再加白**。
///
/// 一句话：柔彩 = 饱和度略降 + 亮度归一 → 仍然是明确的彩色，只是不刺眼。
Color _softColor(Color c) {
  final hsl = HSLColor.fromColor(c);
  final s = (hsl.saturation * 0.72).clamp(0.40, 0.85);
  final l = (hsl.lightness + (0.90 - hsl.lightness) * 0.35).clamp(0.855, 0.925);
  return HSLColor.fromAHSL(1, hsl.hue, s, l).toColor();
}

/// 非本周课程的「淡灰」底色（v1.6.9）：
///  · 饱和度归零 → 灰；
///  · **保留原色明暗差异**（原色深的课灰得更深一点，看得出是哪门课，而不是一团灰）；
///  · [dim] =「非本周课程颜色」滑杆（0.45~0.85，越大越淡）控制整体灰的深浅。
Color otherWeekGrayFor(Color base, double dim, bool isDark) {
  final src = HSLColor.fromColor(base);
  // 原色亮度 → 灰度偏移：原色越深，灰也越深（浅色调色板亮度约 0.83~0.95）
  final tone = ((0.96 - src.lightness) / 0.22).clamp(0.0, 1.0);
  final fade = ((dim - 0.45) / 0.40).clamp(0.0, 1.0); // 0 = 最明显，1 = 最淡
  final l = isDark
      // 深色模式：目标灰在 #202020~#3A3A3A（比页面底色略亮，看得出有块）
      ? 0.235 - 0.075 * fade - tone * 0.05
      // 浅色模式：目标灰在 #C7C7C7~#E8E8E8（默认档 ≈ #D5~#E3）
      : 0.875 + 0.075 * fade - tone * 0.17;
  return HSLColor.fromAHSL(1, 0, 0, l.clamp(0.05, 0.98)).toColor();
}

/// 同色相下调整饱和度 / 亮度。[satScale] 1 = 原样；[lighten] / [darken] 二选一。
Color _shiftColor(
  Color c, {
  required double satScale,
  double lighten = 0,
  double darken = 0,
}) {
  final hsl = HSLColor.fromColor(c);
  final s = (hsl.saturation * satScale).clamp(0.0, 1.0);
  var l = hsl.lightness;
  if (lighten > 0) l = l + (1 - l) * lighten;
  if (darken > 0) l = l * (1 - darken);
  return HSLColor.fromAHSL(1, hsl.hue, s, l.clamp(0.0, 1.0)).toColor();
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


/// 一门「教务课」与一门「本地课」的时间冲突（2026-10-13，任务三）。
///
/// 场景：同步/手动刷新时，教务下来的课与课表里已有的课（通常是手动加的）
/// 在**同一时段**撞上 —— 现实里很常见（重修、跨专业选修、教务发布时间差）。
/// 冲突不自动决定谁去谁留，交给用户：见课表页的冲突弹窗。
class CourseConflict {
  const CourseConflict({required this.server, required this.local});

  /// 本次从教务抓到的课。
  final Course server;

  /// 课表里原本就有的课（非教务来源，通常是手动添加的）。
  final Course local;

  /// 「周三 第 3-4 节」——弹窗直接展示用。
  String get timeLabel {
    const days = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final d = (server.weekday >= 1 && server.weekday <= 7)
        ? days[server.weekday - 1]
        : '';
    return '$d 第 ${server.startSlot}-${server.endSlot} 节';
  }
}
