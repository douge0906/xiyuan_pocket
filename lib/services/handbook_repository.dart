import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 《无锡学院学生手册（2026 版）》内置数据的解析、索引与检索。
///
/// 数据来自 `assets/seed/handbook_2026.json`：按 `word/document.xml` body
/// 顺序逐块提取，段落不改写、表格行列不拆散、来源脚注原样保留。
/// 这里是纯 Dart 的离线检索，不联网、不需要登录、不上传任何输入。
///
/// 服务名「锡院学生手册」：**主体是手册原文 + 规则来源 + 覆盖广度**，
/// 关键词一键查只是附带的定位手段，命中后一律回跳到原文章节。

// ---------------------------------------------------------------------------
// 数据模型
// ---------------------------------------------------------------------------

/// 一个块：段落 `p` 或表格 `tbl`。
///
/// [isSource] 为 true 表示这是单格的「来源 / 说明」脚注表，须按来源卡展示，
/// 与正文区分但不删除、不改写。
class HandbookBlock {
  HandbookBlock({
    required this.kind,
    required this.text,
    required this.rows,
    required this.isSource,
    required this.index,
  });

  /// `'p'`（段落）/ `'tbl'`（表格）。
  final String kind;
  final String text;
  final List<List<String>> rows;
  final bool isSource;

  /// 原始 block 下标，便于与提取报告逐块核对完整性。
  final int index;
}

/// 一个三级小节（Heading 3）。
///
/// 章内没有 Heading 3 的正文（章导语、附录整表）会落进 `title == ''`
/// 的隐式小节，保证不丢任何块。
class HandbookSection {
  HandbookSection({required this.title, required this.index});

  final String title;
  final int index;
  final List<HandbookBlock> blocks = [];
}

/// 一个章或附录（Heading 2）。
///
/// [hidden] 的章不进入目录与检索，但内容仍保留在数据里 ——
/// 附录 E 是付印前的内部核验清单，不面向学生展示。
class HandbookChapter {
  HandbookChapter({
    required this.title,
    required this.index,
    required this.isAppendix,
    required this.hidden,
  });

  final String title;
  final int index;
  final bool isAppendix;
  final bool hidden;
  final List<HandbookSection> sections = [];

  int get sectionCount => sections.where((s) => s.title.isNotEmpty).length;

  int get tableCount => sections.fold(
      0, (n, s) => n + s.blocks.where((b) => b.kind == 'tbl').length);
}

/// 一条检索命中，携带回跳原文章节所需的全部坐标。
class HandbookHit {
  const HandbookHit({
    required this.chapterIndex,
    required this.sectionIndex,
    required this.blockIndex,
    required this.chapterTitle,
    required this.sectionTitle,
    required this.text,
    required this.terms,
    required this.score,
    required this.isTable,
    required this.isSource,
  });

  final int chapterIndex;
  final int sectionIndex;
  final int blockIndex;
  final String chapterTitle;
  final String sectionTitle;
  final String text;
  final List<String> terms;
  final double score;
  final bool isTable;
  final bool isSource;
}

/// 解析后的整本手册。
class HandbookData {
  HandbookData({
    required this.meta,
    required this.cover,
    required this.frontMatter,
    required this.chapters,
  });

  final Map<String, dynamic> meta;
  final List<String> cover;
  final List<HandbookBlock> frontMatter;
  final List<HandbookChapter> chapters;

  List<HandbookChapter> get visibleChapters =>
      chapters.where((c) => !c.hidden).toList();

  int get chapterCount => chapters.where((c) => !c.isAppendix).length;
  int get appendixCount => chapters.where((c) => c.isAppendix).length;
  int get visibleAppendixCount =>
      chapters.where((c) => c.isAppendix && !c.hidden).length;
  int get sectionCount => chapters.fold(0, (n, c) => n + c.sectionCount);

  /// 全部原文表格（含卷首「使用说明」表）。用于完整性自检，应等于 meta.tables。
  int get tableCount =>
      chapters.fold(0, (n, c) => n + c.tableCount) +
      frontMatter.where((b) => b.kind == 'tbl').length;

  int get sourceFootnoteCount => chapters.fold(
      0,
      (n, c) => n +
          c.sections.fold(
              0,
              (m, s) => m +
                  s.blocks
                      .where((b) => b.isSource && b.text.contains('来源'))
                      .length));

  /// 按标题前缀找章（含被隐藏的附录，供「来源与覆盖」页引用原文）。
  HandbookChapter? chapter(String prefix) {
    for (final c in chapters) {
      if (c.title.startsWith(prefix)) return c;
    }
    return null;
  }

  /// 取某章某小节的正文段落原文（供「使用约定」等卡片照录，不硬编码）。
  List<String> sectionParagraphs(String chapterPrefix, String sectionPrefix) {
    final c = chapter(chapterPrefix);
    if (c == null) return const [];
    for (final s in c.sections) {
      if (s.title.startsWith(sectionPrefix)) {
        return s.blocks
            .where((b) => b.kind == 'p' && b.text.trim().isNotEmpty)
            .map((b) => b.text.trim())
            .toList();
      }
    }
    return const [];
  }

  // -------------------------------------------------------------------------
  // 关键词检索（附带功能）
  // -------------------------------------------------------------------------

  static final RegExp _numeric = RegExp(r'^[0-9]+$');

  /// 口语词 → 书面标题词的意图映射。
  ///
  /// 手册标题多为名词（「课程考核与成绩」「学士学位授予」），学生输入多为
  /// 口语（「奖学金多少钱」「宿舍几点熄灯」「校园卡丢了」）。这层轻量扩展
  /// 只用于召回，**不改动任何原文**；命中后仍回跳到原文逐字展示。
  static const Map<String, List<String>> _synonyms = {
    '奖学金': ['奖助', '资助', '评定'],
    '熄灯': ['作息', '门禁', '宿舍'],
    '校园卡': ['一卡通', '校园卡'],
    '四级': ['cet', '425', '英语'],
    '六级': ['cet', '425', '英语'],
    '学位': ['学士学位', '授予', '70'],
    '转专业': ['专业调整', '转出', '转入'],
    '申诉': ['复查', '投诉', '10'],
    '补考': ['缓考', '重修'],
    '重修': ['学分', '15'],
    '加权': ['加权平均', '成绩'],
    '报修': ['物业', '维修'],
    '知网': ['电子资源', 'vpn', '馆藏'],
    '快递': ['邮寄', '地址'],
    '访客': ['入校', '家长进校'],
    '报警': ['紧急电话', '保卫', '110'],
    '学费': ['缴费', '收费'],
    '医保': ['医疗', '校医院'],
    '心理': ['咨询', '预约'],
    '图书馆': ['借阅', '开放时间'],
    '休学': ['复学', '学籍'],
    '退学': ['离校'],
    '入伍': ['征兵', '应征'],
    '档案': ['户口', '去向'],
    '就业': ['招聘', '协议'],
    '诈骗': ['反诈', '96110'],
    '绩点': ['gpa', '加权平均', '学分绩点'],
    'gpa': ['绩点', '加权平均'],
    '平均学分绩点': ['绩点', 'gpa', '加权平均'],
  };

  List<String> _expand(String query) {
    final tokens = query
        .toLowerCase()
        .trim()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    final out = <String>{};
    for (final t in tokens) {
      out.add(t);
      if (_numeric.hasMatch(t)) continue;
      for (final e in _synonyms.entries) {
        if (t.length >= 2 && (e.key.contains(t) || t.contains(e.key))) {
          out.addAll(e.value);
        }
      }
    }
    return out.toList();
  }

  /// 多路召回 + 加权排序。
  ///
  /// 召回范围：章节标题 / 小节标题 / 正文段落 / 表格单元格 / 来源脚注。
  /// 权重：标题 ×3、问答与快速索引 ×1.3、纯数字（金额 / 分数 / 学分 /
  /// 电话 / 章节号）×额外 2、命中词数加成。零结果交给 UI 兜底。
  List<HandbookHit> search(String query) {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final terms = _expand(q);
    if (terms.isEmpty) return const [];
    final tokens = q
        .toLowerCase()
        .trim()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();

    final hits = <HandbookHit>[];
    for (var ci = 0; ci < chapters.length; ci++) {
      final chapter = chapters[ci];
      if (chapter.hidden) continue;
      for (var si = 0; si < chapter.sections.length; si++) {
        final section = chapter.sections[si];
        for (var bi = 0; bi < section.blocks.length; bi++) {
          final block = section.blocks[bi];
          final raw = block.kind == 'tbl'
              ? block.rows.expand((r) => r).join(' ')
              : block.text;
          final flat = raw.trim();
          if (flat.isEmpty) continue;
          final lowerText = flat.toLowerCase();
          final lowerTitle =
              '${section.title} ${chapter.title}'.toLowerCase();
          final isQa = chapter.title.contains('常见问题') ||
              section.title.contains('快速索引');

          double score = 0;
          for (final t in terms) {
            if (lowerTitle.contains(t)) score += 3;
            if (lowerText.contains(t)) {
              score += (block.kind == 'tbl' ? 1 : 1.5) * (isQa ? 1.3 : 1);
              if (_numeric.hasMatch(t)) score += 2;
            }
          }
          if (score <= 0) continue;
          final matched = tokens
              .where((t) => lowerTitle.contains(t) || lowerText.contains(t))
              .length;
          if (matched > 0) score += matched * 0.5;

          hits.add(HandbookHit(
            chapterIndex: ci,
            sectionIndex: si,
            blockIndex: bi,
            chapterTitle: chapter.title,
            sectionTitle: section.title,
            text: flat,
            terms: terms,
            score: score,
            isTable: block.kind == 'tbl',
            isSource: block.isSource,
          ));
        }
      }
    }
    hits.sort((a, b) {
      final d = b.score.compareTo(a.score);
      if (d != 0) return d;
      final c = a.chapterIndex.compareTo(b.chapterIndex);
      if (c != 0) return c;
      return a.sectionIndex.compareTo(b.sectionIndex);
    });
    return hits;
  }
}

// ---------------------------------------------------------------------------
// 仓库：加载 + 解析（纯函数，便于单测）
// ---------------------------------------------------------------------------

class HandbookRepository {
  HandbookRepository._();

  static final HandbookRepository instance = HandbookRepository._();

  static const String asset = 'assets/seed/handbook_2026.json';

  HandbookData? _cache;
  Future<HandbookData>? _loading;

  Future<HandbookData> load() {
    final cached = _cache;
    if (cached != null) return Future.value(cached);
    return _loading ??= _read().then((d) {
      _cache = d;
      return d;
    });
  }

  static Future<HandbookData> _read() async {
    final raw = await rootBundle.loadString(asset);
    return fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// 纯函数解析，单测可直接喂 JSON，不依赖 Flutter asset bundle。
  @visibleForTesting
  static HandbookData fromJson(Map<String, dynamic> j) {
    final rawBlocks = (j['blocks'] as List).cast<Map<String, dynamic>>();
    final cover = <String>[];
    final frontMatter = <HandbookBlock>[];
    final chapters = <HandbookChapter>[];

    for (var i = 0; i < rawBlocks.length; i++) {
      final rb = rawBlocks[i];
      final kind = rb['kind'] as String? ?? '';
      final style = rb['style'] as String?;
      final text = rb['text'] as String? ?? '';

      // 目录行的页码全是占位「1」，整段剔除；导航改用正文 Heading 重建。
      if (kind == 'other') continue;
      if (style == 'toc 1' || style == 'toc 2') continue;

      if (style == 'Heading 2') {
        chapters.add(HandbookChapter(
          title: text,
          index: i,
          isAppendix: text.startsWith('附录'),
          hidden: text.contains('附录 E'),
        ));
        continue;
      }

      final cur = chapters.isEmpty ? null : chapters.last;
      if (cur == null) {
        // 封面 / 卷首（第一个 Heading 2 之前）。
        if (kind == 'p') {
          final t = text.trim();
          if (t.isEmpty || t == '目录') continue;
          cover.add(text);
        } else if (kind == 'tbl') {
          frontMatter.add(_block(rb, i));
        }
        continue;
      }

      if (style == 'Heading 3') {
        cur.sections.add(HandbookSection(title: text, index: i));
        continue;
      }
      // 章导语 / 整表附录：没有 Heading 3 时落到隐式小节，保证不丢块。
      if (cur.sections.isEmpty) {
        cur.sections.add(HandbookSection(title: '', index: i));
      }
      cur.sections.last.blocks.add(_block(rb, i));
    }

    return HandbookData(
      meta: (j['meta'] as Map<String, dynamic>?) ?? const {},
      cover: cover,
      frontMatter: frontMatter,
      chapters: chapters,
    );
  }

  static HandbookBlock _block(Map<String, dynamic> rb, int index) {
    final kind = rb['kind'] as String? ?? '';
    if (kind == 'tbl') {
      final rows = <List<String>>[];
      final rawRows = (rb['rows'] as List?) ?? const [];
      for (final r in rawRows) {
        rows.add((r as List).map((c) => c.toString()).toList());
      }
      final single =
          rows.length == 1 && rows.isNotEmpty && rows.first.length == 1;
      return HandbookBlock(
        kind: 'tbl',
        text: single ? rows.first.first : '',
        rows: rows,
        isSource: single,
        index: index,
      );
    }
    return HandbookBlock(
      kind: 'p',
      text: rb['text'] as String? ?? '',
      rows: const [],
      isSource: false,
      index: index,
    );
  }
}
