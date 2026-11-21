import '../../models/course_model.dart';

/// 图片识别（OCR）得到的一门**候选课程**。
///
/// 与 [Course] 的区别：这里的字段全部可变、允许留空，因为 OCR 结果只是
/// 「待用户确认」的草稿 —— 用户在勾选面板里可以改名、改节次/星期/周次/教室/
/// 教师，确认后才转成正式 [Course] 写入课表。
///
/// 一期定位：识别不追求一次到位，宁可把不确定的字段留空交给用户补，
/// 也不要把 OCR 猜出来的错误节次/周次直接写进课表。
class RecognizedCourse {
  String name;
  String teacher;
  String classroom;

  /// 图片里的「班级名称」列。一门合班课可能是
  /// `25电气1、25电气2、25电气3`，保留成一条字符串。
  String className;

  /// 从图片日期/服务端返回推导的学年，形如 `2026-2027`。
  String academicYear;

  /// `第一学期` / `第二学期`；识别不到时为空。
  String academicTerm;

  int weekday; // 1..7；0 表示未识别到星期
  int startSlot; // 1..12；0 表示未识别到起始节
  int endSlot; // 1..12；0 表示未识别到结束节
  String weeks;

  RecognizedCourse({
    this.name = '',
    this.teacher = '',
    this.classroom = '',
    this.className = '',
    this.academicYear = '',
    this.academicTerm = '',
    this.weekday = 0,
    this.startSlot = 0,
    this.endSlot = 0,
    this.weeks = '',
  });

  /// 课程名非空才算一条可用候选（其余字段允许为空，由用户补）。
  bool get isValid => name.trim().isNotEmpty;

  /// OCR 是否已经给出可直接排课的时间信息。
  ///
  /// 0 是「未识别」而不是默认周一/第 1 节；缺周次也不等于「全部周」。
  /// 这类候选默认不选中，用户必须先编辑补全再导入。
  bool get hasCompleteSchedule =>
      weekday >= 1 &&
      weekday <= 7 &&
      startSlot >= 1 &&
      startSlot <= 12 &&
      endSlot >= startSlot &&
      endSlot <= 12 &&
      weeks.trim().isNotEmpty;

  bool get isReadyToImport => isValid && hasCompleteSchedule;

  /// 转成正式课程；时间字段不完整时返回 null，避免把未知时间静默写成周一第 1 节。
  Course? toCourse() {
    if (!isReadyToImport) return null;
    final trimmedName = name.trim();
    return Course(
      // 班级/学年也进 id：否则同一门课不同班级、不同学年会撞成一个 id，
      // 导入时被按 id 去重悄悄吞掉。
      id: 'ocr_${_stableHash('$trimmedName|${className.trim()}|'
          '${academicYear.trim()}|${academicTerm.trim()}|'
          '$weekday-$startSlot-$endSlot|${weeks.trim()}')}',
      name: trimmedName,
      teacher: teacher.trim(),
      classroom: classroom.trim(),
      className: className.trim(),
      academicYear: academicYear.trim(),
      academicTerm: academicTerm.trim(),
      weekday: weekday,
      startSlot: startSlot,
      endSlot: endSlot,
      weeks: weeks.trim(),
      colorValue: colorForName(trimmedName),
      source: CourseSource.imported,
      weekType: CourseWeekTypeX.fromOldText(weeks),
      pattern: CoursePattern.fixed,
    );
  }

  /// 编辑弹窗需要一个可展示的 Course；未知字段先用占位值，保存时由表单校验。
  Course toDraftCourse() {
    final trimmedName = name.trim();
    final wd = weekday >= 1 && weekday <= 7 ? weekday : 1;
    final start = startSlot.clamp(1, 12);
    var end = endSlot.clamp(start, 12);
    if (end < start) end = start;
    return Course(
      id: 'ocr_draft_${identityHashCode(this)}',
      name: trimmedName,
      teacher: teacher.trim(),
      classroom: classroom.trim(),
      className: className.trim(),
      academicYear: academicYear.trim(),
      academicTerm: academicTerm.trim(),
      weekday: wd,
      startSlot: start,
      endSlot: end,
      weeks: weeks.trim(),
      colorValue: colorForName(trimmedName),
      source: CourseSource.imported,
      weekType: CourseWeekTypeX.fromOldText(weeks),
      pattern: CoursePattern.fixed,
    );
  }

  RecognizedCourse copy() => RecognizedCourse(
        name: name,
        teacher: teacher,
        classroom: classroom,
        className: className,
        academicYear: academicYear,
        academicTerm: academicTerm,
        weekday: weekday,
        startSlot: startSlot,
        endSlot: endSlot,
        weeks: weeks,
      );
}

/// FNV-1a 32 位稳定哈希：OCR 课程 id 不能依赖 `String.hashCode`
/// （Dart 不承诺跨进程/跨版本稳定），否则重启后会重复导入同一门课。
String _stableHash(String source) {
  var hash = 0x811c9dc5;
  for (final unit in source.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
