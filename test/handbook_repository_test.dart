import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/handbook_repository.dart';

/// 「锡院学生手册」数据层回归测试。
///
/// 重点验证设计方案里的三条硬要求：
/// 1. 原文完整 —— 619 块全部解析、100 张表行列不丢、字数与提取报告一致；
/// 2. 来源准确 —— 1×1 单格「来源」脚注原样保留成来源卡；
/// 3. 覆盖广 —— 19 章 + 8 附录（共 27 个 Heading 2），附录 E 内部清单
///    保留数据但不进目录/检索。
///
/// 另外验证附带的一键查：口语词能召回、命中携带回跳坐标、零结果兜底。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HandbookData data;

  setUpAll(() {
    final raw = File('assets/seed/handbook_2026.json').readAsStringSync();
    data = HandbookRepository.fromJson(
        jsonDecode(raw) as Map<String, dynamic>);
  });

  group('原文完整性', () {
    test('meta 统计与提取报告一致', () {
      final m = data.meta;
      expect(m['blocks'], 619);
      expect(m['paragraphs'], 518);
      expect(m['tables'], 100);
      expect(m['table_rows'], 610);
      expect(m['table_cells'], 1339);
      expect(m['paragraph_chars'], 14897);
      expect(m['table_chars'], 16756);
      expect(m['total_chars'], 31653);
    });

    test('章节骨架：27 个 Heading 2 = 19 章 + 8 附录', () {
      expect(data.chapters.length, 27);
      expect(data.chapterCount, 19);
      expect(data.appendixCount, 8);
      expect(data.visibleAppendixCount, 7); // 附录 E 隐藏
    });

    test('100 张原文表全部保留（含卷首使用说明表）', () {
      expect(data.tableCount, 100);
    });

    test('附录 E 是付印前内部核验清单，保留数据但不面向学生', () {
      final e = data.chapter('附录 E');
      expect(e, isNotNull);
      expect(e!.hidden, isTrue);
      expect(data.visibleChapters.any((c) => c.title.contains('附录 E')),
          isFalse);
    });

    test('来源脚注原样保留为来源卡', () {
      expect(data.sourceFootnoteCount, 28);
      // 12.3 学校奖学金的来源脚注是逐字照录的。
      final c12 = data.chapter('十二、');
      expect(c12, isNotNull);
      final allText = c12!.sections
          .expand((s) => s.blocks)
          .where((b) => b.isSource)
          .map((b) => b.text)
          .join('\n');
      expect(
        allText.contains('《无锡学院学校奖学金评定办法（试行）》'),
        isTrue,
      );
      expect(allText.contains('2021 年 8 月 3 日'), isTrue);
    });

    test('1.3 使用约定三条原文不改写', () {
      final ps = data.sectionParagraphs('一、', '1.3');
      expect(ps.length, 3);
      expect(ps[0], '本手册所有数据来自无锡学院官网及各部门网站，核验日期为 2026 年 11 月。');
      expect(ps[1].contains('以当年通知为准'), isTrue);
      expect(ps[2], '手册不替代学校正式文件；与正式文件不一致时，以正式文件为准。');
    });

    test('12.3 学校奖学金速查表 4 列 5 行不拆散', () {
      final c = data.chapter('十二、');
      final tbl = c!.sections
          .expand((s) => s.blocks)
          .firstWhere((b) =>
              b.kind == 'tbl' &&
              b.rows.isNotEmpty &&
              b.rows.first.length == 4 &&
              b.rows.length == 5);
      expect(tbl.rows.first.first, '等级');
      expect(tbl.rows[1][1], '6000');
      expect(tbl.rows[4][1], '300');
    });
  });

  group('附带一键查', () {
    test('空查询不返回结果', () {
      expect(data.search(''), isEmpty);
      expect(data.search('   '), isEmpty);
    });

    test('口语词「奖学金」能召回并带章节回跳坐标', () {
      final hits = data.search('奖学金');
      expect(hits, isNotEmpty);
      final top = hits.first;
      expect(top.chapterTitle, isNotEmpty);
      expect(top.text.contains('奖学金'), isTrue);
      // 命中必须能定位到具体章 / 节 / 块。
      expect(top.chapterIndex, greaterThanOrEqualTo(0));
      expect(top.chapterIndex, lessThan(data.chapters.length));
      expect(top.sectionIndex, greaterThanOrEqualTo(0));
    });

    test('纯数字（金额 / 分数 / 学分 / 电话）可检索', () {
      expect(data.search('6000'), isNotEmpty);
      expect(data.search('425'), isNotEmpty);
      expect(data.search('80560110'), isNotEmpty);
    });

    test('命中不改写原文，仅高亮用', () {
      final hits = data.search('奖学金评定办法');
      expect(hits, isNotEmpty);
      expect(hits.first.text, isNot(contains('\u0000')));
    });

    test('附录 E 的内容不出现在检索结果里', () {
      final hits = data.search('热水时段');
      // 若文档其它章也提到热水，仍不得出现来自附录 E 的命中。
      for (final h in hits) {
        expect(h.chapterTitle.contains('附录 E'), isFalse);
      }
    });
  });
}
