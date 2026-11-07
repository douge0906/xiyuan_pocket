import 'dart:typed_data';

import '../../models/course_model.dart';
import 'mini_pdf.dart';

/// 从教务「导出课表」PDF 里解析出课程列表。
///
/// 版面（无锡学院教务系统导出，2026-2027 版实测）：
/// ```
/// 2026-2027学年第1学期        车雷课表        学号：25350103
/// 时间段 | 节次 | 星期一 | 星期二 | … | 星期日      ← 表头行
///        1     | 模拟电子技术基础Ⅱ（平台课）▲
///              | (1-2节)1-15周(单)/场地:C5科教中心124/教师:闫纪源/…
/// ```
/// 关键点：
///   · 每个课程格子的**文字是逐行 wrap 的**，必须先把同一格的所有行拼起来
///     再按 `/` 拆字段，否则「场地」会被拦腰截断。
///   · 课程名以 `▲` 结尾，紧跟一行 `(起-止节)周次/场地:…` —— 后者是格子锚点。
///   · 页面上方 `/Rotate 90` + 内容流里的 `0 1 -1 0 595 0 cm`，但 Tm 的
///     **x 轴仍是「星期」方向**、y 轴是「节次」方向（y 越大节次越靠前），
///     所以直接用 x 判定星期、用 `(N-M节)` 判定节次最稳。
class CoursePdfParser {
  CoursePdfParser._();

  /// 解析结果。
  static CoursePdfResult parse(Uint8List bytes) {
    final pages = MiniPdf.parse(bytes).extractText();

    // ── 第一步：找出带表头的那一页，拿到「星期列中心 x」与表头 y ──
    //
    // 🔴 教务导出会把一张课表竖着切成 3 页：**只有第 1 页有表头**，后面两页
    //    是纯续页（一上来就是课程格子的下半截）。早期版本逐页都要求有表头，
    //    结果只解析出第 1 页（19 门），漏掉后两页。
    const weekDays = [
      '星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日',
    ];
    Map<int, double> centers = {};
    double headerY = double.nan;
    var headerPage = -1;
    for (var pi = 0; pi < pages.length; pi++) {
      final hit = pages[pi].items.where((it) => it.text.trim() == '星期一').toList();
      if (hit.isEmpty) continue;
      headerY = hit.first.y;
      headerPage = pi;
      for (var i = 0; i < weekDays.length; i++) {
        final d = pages[pi].items.firstWhere(
          (it) => it.text.trim() == weekDays[i],
          orElse: () => const PdfTextItem(text: '', x: double.nan, y: double.nan),
        );
        if (d.x.isFinite) centers[i + 1] = d.x;
      }
      break;
    }
    if (centers.length < 5) {
      throw const PdfParseException(
        '这份 PDF 里找不到「星期一…星期日」的课表表头。\n'
        '请到教务系统 → 课表 → 导出/打印 → 选 PDF，再上传。',
      );
    }

    // 列宽 = 相邻星期中心的最大间隔；半个列宽作为吸附半径
    final xs = centers.values.toList()..sort();
    var colWidth = 100.0;
    for (var i = 1; i < xs.length; i++) {
      final d = xs[i] - xs[i - 1];
      if (d > colWidth) colWidth = d;
    }
    final half = colWidth / 2;
    final minColX = xs.first - half;

    // ── 第二步：把所有页的文字按「星期列」分桶，并保持页面先后顺序 ──
    //
    // 一张表被切成多页后，同一门课的「标题在上一页、详情在下一页」是常态，
    // 所以按列把各页的行首尾相接，再统一扫描。
    final columns = <int, List<PdfTextItem>>{};
    String? title;
    for (var pi = 0; pi < pages.length; pi++) {
      final page = pages[pi];
      // 表头以上的页眉（学期 / 姓名 / 学号）只用来取标题
      if (title == null && headerY.isFinite) {
        final headText = page.items
            .where((it) => it.y > headerY)
            .map((it) => it.text.trim())
            .join(' ');
        final m = RegExp(r'(\S+课表)').firstMatch(headText);
        if (m != null) title = m.group(1);
      }

      // 🔴 表头 y 只对本页（含表头那页）成立。续页没有表头行，
      //    直接套用第 1 页的 headerY 会把续页顶部（y 更大）的课程整段丢掉 ——
      //    实测这样会漏 5 门课（33 → 28）。
      final isHeaderPage = pi == headerPage;
      final body = page.items
          .where((it) => it.text.trim().isNotEmpty)
          .where((it) => !isHeaderPage || !headerY.isFinite || it.y < headerY - 2)
          .where((it) => it.x > minColX) // 丢掉左侧「节次 / 上午下午」标签列
          .toList()
        ..sort((a, b) => b.y.compareTo(a.y));

      for (final it in body) {
        var bestCol = 0;
        var bestDist = double.infinity;
        for (final e in centers.entries) {
          final d = (it.x - e.value).abs();
          if (d < bestDist) {
            bestDist = d;
            bestCol = e.key;
          }
        }
        if (bestDist > half) continue;
        columns.putIfAbsent(bestCol, () => []).add(it);
      }
    }

    // ── 第三步：逐列扫描，切出课程 ──
    final courses = <Course>[];
    final seen = <String>{};
    for (final entry in columns.entries) {
      final weekday = entry.key;
      final lines = entry.value;

      var i = 0;
      while (i < lines.length) {
        final anchor = _anchorOf(lines[i].text);
        if (anchor == null) {
          i++;
          continue;
        }
        // 向上回溯课程名：课程名会折成 1~3 行，**最后一行带 `▲`**。
        // 判据：遇到 `/`（详情行）或另一个锚点就停。
        // 🔴 还要丢掉上一格详情的**尾巴**（`学分:1.0` 折行后只剩 `:1.0`）——
        //    这类行一定以 `:` 或 `：` 开头，判定成课程名会污染标题。
        final titleParts = <String>[];
        for (var k = i - 1; k >= 0 && titleParts.length < 4; k--) {
          final t = lines[k].text.trim();
          if (t.isEmpty) break;
          if (t.contains('/') || _anchorOf(t) != null) break;
          if (t.startsWith(':') || t.startsWith('：')) break;
          titleParts.insert(0, t);
        }
        // 向下累积详情，直到下一个锚点
        final detail = StringBuffer(anchor.rest);
        var j = i + 1;
        while (j < lines.length && _anchorOf(lines[j].text) == null) {
          detail.write(lines[j].text.trim());
          j++;
        }

        final name = titleParts
            .join()
            .replaceAll('▲', '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        final course = _buildCourse(
          name: name,
          startSlot: anchor.startSlot,
          endSlot: anchor.endSlot,
          weeks: anchor.weeks,
          weekday: weekday,
          detail: detail.toString(),
        );
        if (course != null) {
          final key = '${course.name}|${course.weekday}|'
              '${course.startSlot}-${course.endSlot}|${course.weeks}';
          if (seen.add(key)) courses.add(course);
        }
        i = j;
      }
    }

    if (courses.isEmpty) {
      throw const PdfParseException(
        '没识别出课程。这份 PDF 的版面可能不是教务「导出课表」生成的。\n'
        '请到教务系统 → 课表 → 导出/打印 → 选 PDF，再上传。',
      );
    }
    courses.sort((a, b) {
      final w = a.weekday.compareTo(b.weekday);
      if (w != 0) return w;
      return a.startSlot.compareTo(b.startSlot);
    });
    return CoursePdfResult(courses: courses, title: title);
  }

  /// 识别格子锚点 `(1-2节)1-15周(单)/场地:…`。
  static _Anchor? _anchorOf(String raw) {
    final text = raw.trim();
    final m = RegExp(r'^\((\d+)-(\d+)节\)([^/]*)').firstMatch(text);
    if (m == null) return null;
    return _Anchor(
      startSlot: int.parse(m.group(1)!),
      endSlot: int.parse(m.group(2)!),
      weeks: m.group(3)!.trim(),
      rest: text.substring(m.end - 0),
    );
  }

  static Course? _buildCourse({
    required String name,
    required int startSlot,
    required int endSlot,
    required String weeks,
    required int weekday,
    required String detail,
  }) {
    if (name.isEmpty) return null;
    if (startSlot < 1 || startSlot > 12 || endSlot < startSlot || endSlot > 12) {
      return null;
    }

    // 详情里按 `/` 拆字段；同一个字段可能被换行截断，拼接后天然复原。
    var classroom = '';
    var teacher = '';
    for (final seg in detail.split('/')) {
      final s = seg.trim();
      if (s.startsWith('场地:')) {
        classroom = s.substring('场地:'.length).trim();
      } else if (s.startsWith('教师:')) {
        teacher = s.substring('教师:'.length).trim();
      } else if (s.startsWith('场地：')) {
        classroom = s.substring('场地：'.length).trim();
      } else if (s.startsWith('教师：')) {
        teacher = s.substring('教师：'.length).trim();
      }
    }
    // 「场地」偶尔会被后面的内容黏住（如 `C5科教中心124/教师:` 正常，
    // 但 `D4思泉楼110` 后面如果没跟 `/` 就会带上说明），保守截到第一个 `/`。
    classroom = classroom.split('/').first.trim();
    teacher = teacher.split('/').first.trim();

    return Course(
      id: 'pdf_${name.hashCode}_${weekday}_${startSlot}_${weeks.hashCode}',
      name: name,
      teacher: teacher,
      classroom: classroom,
      weekday: weekday,
      startSlot: startSlot,
      endSlot: endSlot,
      weeks: weeks,
      colorValue: 0xFF3B82F6,
      source: CourseSource.imported,
      weekType: CourseWeekTypeX.fromOldText(weeks),
    );
  }
}

class _Anchor {
  const _Anchor({
    required this.startSlot,
    required this.endSlot,
    required this.weeks,
    required this.rest,
  });

  final int startSlot;
  final int endSlot;
  final String weeks;
  final String rest;
}

/// 解析结果。
class CoursePdfResult {
  const CoursePdfResult({required this.courses, this.title});

  final List<Course> courses;

  /// 页面上的「XXX课表」，用于确认这是谁的课表（可为空）。
  final String? title;
}

/// PDF 课表解析失败（版面不认识 / 没有文字层 / 文件损坏）。
class PdfParseException implements Exception {
  const PdfParseException(this.message);
  final String message;

  @override
  String toString() => message;
}
