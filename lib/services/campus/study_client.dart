import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../models/study_models.dart';
import 'campus_session.dart';
import 'cas_client.dart';
import 'course_fetcher.dart';
import 'jwgl_client.dart';

/// 正方教务「学业情况查询」客户端 —— 纯 Dart 客户端直连。
///
/// 页面：`/jwglxt/xsxy/xsxyqk_cxXsxyqkIndex.html?gnmkdm=N105515&layout=default`
///
/// ## 抓取三步（2026-11-02 用 2025 级账号实测，10 板块 135 门课全通）
///
/// 1. GET 页面 → 有 `class="treeview"` 说明教务配了培养方案（Mode A），
///    否则页面会直接渲染「您所在年级专业没有教学计划」（Mode B）。
/// 2. 从页面 `<script>` 模板里正则抽节点：
///    `xfyqjd_id='<32位>' ... yxxf='已修学分' yqzdxf='要求学分' sftg='是否通过'`
/// 3. 逐节点 POST `/xsxy/xsxyqk_cxJxzxjhxfyqKcxx.html`，**表单只能三个字段**。
///
/// ## 🔴 三个已踩过的坑（别再试）
///
/// · 表单多传 `fromXh_id`、或把 `xh_id` 填成学号、或把完整 `csrftoken`
///   （含逗号后半段）传进去 → 教务返回 **HTML 错误页而不是 JSON**。
///   `xh_id` 必须是**空字符串**。
/// · `csrftoken` 页面里是 `<uuid>,<uuid去横线>` 69 字符，**只取逗号前那一段**。
/// · GPA 弹窗接口 `cxShowGpaView.html` / `cxShowJqPjfView.html` 一律返回
///   **HTTP 911**，GPA 只能从页面顶部汇总正则取，不要调这两个接口。
class StudyClient {
  static const String _base = CasClient.jwglBase;

  static const String _page =
      '$_base/jwglxt/xsxy/xsxyqk_cxXsxyqkIndex.html?gnmkdm=N105515&layout=default';

  static const String _courseApi =
      '$_base/jwglxt/xsxy/xsxyqk_cxJxzxjhxfyqKcxx.html';

  /// 节点属性正则。教务把树节点写成一段 JS 模板字符串，
  /// `xfyqjd_id` / `jdkcsx` / `leaf` / `sfmjd` 四个属性在同一行连续出现。
  ///
  /// ⚠️ 这里**只认这四个属性**，`yxxf` / `yqzdxf` / `sftg` / 名称在它后面几百字符内，
  /// 用窗口二次扫（见 [_parseNodes]）—— 一次性写死整段模板太脆，
  /// 教务换个换行就整页解析不出来（试过，见 MY_STUDY_PLAN.md 的踩坑记录）。
  static final RegExp _nodeHeadRx = RegExp(
    r"xfyqjd_id='([0-9A-F]{32})' jdkcsx='([^']*)' leaf='([^']*)' sfmjd='([^']*)'",
  );

  /// 页面顶部汇总（教务已算好，我们照抄，不自己算）。
  ///
  /// ⚠️ **不能在原始 HTML 上直接跑正则**（2026-11-02 用真实页面验证过）：
  /// 原文里每个字段都带一份 HTML 注释副本，例如
  /// `<a name="showGpa"> 平均学分绩点<!-- 平均学分绩点 --></a>（GPA）：`
  /// 而且「通过」全文出现 80 次（「未通过」「计划外：通过 11」都含它）。
  /// 正确做法是先 [\_plain] 把注释和标签剥掉，再在这段纯文本上取数。
  static final RegExp _gpaRx = RegExp(r'平均学分绩点[^0-9]{0,60}([\d.]+)');
  static final RegExp _totalRx = RegExp(r'计划总课程[^0-9]{0,40}(\d+)');
  static final RegExp _passedRx = RegExp(r'(?<!未)通过[^0-9]{0,10}(\d+)');
  static final RegExp _failedRx = RegExp(r'未通过[^0-9]{0,10}(\d+)');
  static final RegExp _notStartedRx = RegExp(r'未修[^0-9]{0,10}(\d+)');
  static final RegExp _studyingRx = RegExp(r'在读[^0-9]{0,10}(\d+)');
  static final RegExp _studentRx = RegExp(r'([^\s，,。；;：:]{2,20})\s*同学');

  static final RegExp _commentRx = RegExp(r'<!--[\s\S]*?-->');
  static final RegExp _tagRx = RegExp(r'<[^>]*>');
  static final RegExp _spaceRx = RegExp(r'\s+');

  /// HTML → 单行纯文本（剥注释、剥标签、`&nbsp;` 归一、空白折叠）。
  ///
  /// 顶部汇总那段剥完长这样：
  /// `平均学分绩点 （GPA）： 3.62 计划总课程 135 门 通过 17 门 ， 未通过 0 门 ；未修 103 门 ； 在读 15 门`
  static String _plain(String html) {
    var s = html.replaceAll(_commentRx, ' ');
    s = s.replaceAll(_tagRx, ' ');
    s = s.replaceAll('&nbsp;', ' ');
    s = s.replaceAll('&amp;', '&');
    return s.replaceAll(_spaceRx, ' ').trim();
  }

  /// 截取「平均学分绩点」之后的一小段 —— 六个汇总数字全在这里面。
  ///
  /// 不用全文匹配：全文的「通过」有 80 次，会抓到「计划外：通过 11」。
  static String _summarySlice(String plain) {
    final i = plain.indexOf('平均学分绩点');
    if (i < 0) return plain.length > 600 ? plain.substring(0, 600) : plain;
    final j = i + 420;
    return plain.substring(i, j > plain.length ? plain.length : j);
  }

  /// 顶部汇总解析的测试入口。
  ///
  /// 这是**爬虫正则**：教务改一次页面它就静默失效，界面看不出异常
  /// （数字会变空而不是报错）。所以必须用真实页面锁一份回归测试。
  @visibleForTesting
  static Map<String, dynamic> debugParseSummary(String html) {
    final plain = _plain(html);
    final s = _summarySlice(plain);
    int? asInt(RegExp rx) => int.tryParse(rx.firstMatch(s)?.group(1) ?? '');
    return {
      'studentName': _studentRx.firstMatch(plain)?.group(1) ?? '',
      'gpa': double.tryParse(_gpaRx.firstMatch(s)?.group(1) ?? ''),
      'totalCourses': asInt(_totalRx),
      'passedCourses': asInt(_passedRx),
      'failedCourses': asInt(_failedRx),
      'notStartedCourses': asInt(_notStartedRx),
      'studyingCourses': asInt(_studyingRx),
    };
  }

  /// 节点解析的测试入口（真实页面 40 次命中 / 去重 10 个节点）。
  @visibleForTesting
  static List<Map<String, String>> debugParseNodes(String html) => _parseNodes(html)
      .map((n) => {
            'id': n.id,
            'name': n.name,
            'leaf': n.leaf ? '1' : '',
            'yxxf': n.yxxf,
            'yqzdxf': n.yqzdxf,
            'sftg': n.sftg,
          })
      .toList();

  /// 抓取整份学业档案。
  ///
  /// [fallbackXnm] / [fallbackXqm] 仅在 Mode B 需要查课表时使用
  /// （传当前学年与学期码，`xqm` 用教务的 `3`=第1学期 / `12`=第2学期）。
  static Future<StudyArchive> fetch(
    CampusSession session, {
    String fallbackXnm = '',
    String fallbackXqm = '',
  }) async {
    final r = await session.get(_page, headers: {
      'Referer': '$_base/jwglxt/xtgl/index_initMenu.html',
    });
    if (r.looksLikeLogin) {
      throw CampusException('登录已过期，请重新登录', needRelogin: true);
    }

    final html = r.body;
    // 顶部汇总必须先剥注释和标签才能取数（见 _plain 的注释）
    final plain = _plain(html);
    final studentName = _studentRx.firstMatch(plain)?.group(1) ?? '';
    final summary = _summarySlice(plain);

    // 教务没有给这一届配培养方案 → 走 Mode B（仅课表）
    if (!html.contains('treeview')) {
      return _buildDegraded(session, fallbackXnm, fallbackXqm,
          studentName: studentName);
    }

    final nodes = _parseNodes(html);
    if (nodes.isEmpty) {
      // 有 treeview 却解析不出节点：教务页面结构变了。
      // 不硬凑，直接报错，让人知道是抓取失效而不是「没有学业数据」。
      throw CampusException('教务学业页面结构已变化，暂时无法读取');
    }

    final csrf = _csrf(html);
    // 🔴 csrf 不清空就报错是错的：2026-11-02 抓的真实页面（581,116 字符，
    // 见 test/fixtures/jwgl_study_page_2025.html）里 `csrftoken` 命中为 0，
    // 连 <input>/<form> 都没有。若线上同构，这里必然抛 needRelogin，
    // 而用户明明刚登录成功 —— 错误信息还指错方向（说"请重新登录"）。
    // 改成：空令牌也先真发一次请求，被拒了再报错。
    if (csrf.isEmpty) {
      var probed = false;
      try {
        await _fetchCourses(session, '', nodes.first.id);
        probed = true;
      } catch (_) {
        probed = false;
      }
      if (!probed) {
        throw CampusException('未能获取教务校验令牌，请重新登录后重试',
            needRelogin: true);
      }
    }

    final blocks = <StudyBlock>[];
    String major = '';
    double? requiredCredits;
    double? earnedCredits;
    var failedAny = 0;

    for (final node in nodes) {
      List<Map<String, dynamic>> courses;
      try {
        courses = await _fetchCourses(session, csrf, node.id);
      } catch (e) {
        if (e is CampusException && e.needRelogin) rethrow;
        failedAny++;
        continue;
      }

      if (courses.isEmpty) {
        // 根节点 / 无课板块：记下总学分要求就够了
        if (major.isEmpty && node.id == nodes.first.id) {
          major = node.name;
          requiredCredits = double.tryParse(node.yqzdxf);
          earnedCredits = double.tryParse(node.yxxf);
        }
        continue;
      }

      blocks.add(StudyBlock(
        id: node.id,
        name: node.name,
        courses: StudyArchive.sortCourses(
            courses.map(StudyCourse.fromJwgl).toList()),
        earnedCredits: double.tryParse(node.yxxf),
        passedByServer: node.passedByServer,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }

    if (blocks.isEmpty) {
      if (failedAny > 0) {
        throw CampusException('读取学业数据失败，请稍后重试');
      }
      // 有树但一个板块都没有课：按「暂未配置」展示，不假装有数据
      return StudyArchive.unconfigured();
    }

    return StudyArchive(
      mode: StudyMode.full,
      blocks: StudyArchive.sortBlocks(blocks),
      studentName: studentName,
      major: major.isNotEmpty ? major : nodes.first.name,
      gradeYear: _gradeYear(major.isNotEmpty ? major : nodes.first.name),
      gpa: double.tryParse(_gpaRx.firstMatch(summary)?.group(1) ?? ''),
      totalCourses:
          int.tryParse(_totalRx.firstMatch(summary)?.group(1) ?? ''),
      passedCourses:
          int.tryParse(_passedRx.firstMatch(summary)?.group(1) ?? ''),
      failedCourses:
          int.tryParse(_failedRx.firstMatch(summary)?.group(1) ?? ''),
      notStartedCourses:
          int.tryParse(_notStartedRx.firstMatch(summary)?.group(1) ?? ''),
      studyingCourses:
          int.tryParse(_studyingRx.firstMatch(summary)?.group(1) ?? ''),
      requiredCredits: requiredCredits,
      earnedCredits: earnedCredits,
      fetchedAt: DateTime.now(),
    );
  }

  /// 逐节点拉课程。**表单只能这三个字段**，多一个就返回 HTML 错误页。
  static Future<List<Map<String, dynamic>>> _fetchCourses(
    CampusSession session,
    String csrf,
    String nodeId,
  ) async {
    final r = await session.postForm(
      _courseApi,
      {
        'xfyqjd_id': nodeId,
        'xh_id': '', // 🔴 必须空串，填学号会返回错误页
        'csrftoken': csrf, // 🔴 只取逗号前那一段
      },
      headers: {
        'Referer': _page,
        'X-Requested-With': 'XMLHttpRequest',
        'Accept': 'application/json, text/javascript, */*; q=0.01',
      },
    );
    if (r.looksLikeLogin) {
      throw CampusException('登录已过期，请重新登录', needRelogin: true);
    }
    final j = CampusSession.tryJsonAny(r.body);
    if (j is List) {
      return j.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    // 非 JSON（HTML 错误页）：该节点算失败，由调用方累计
    throw CampusException('教务返回了非预期内容');
  }

  /// 解析页面里的树节点。
  ///
  /// 分两步：先按 [\_nodeHeadRx] 定位每个节点的头部，再在它后面 900 字符的窗口里
  /// 捞 `yxxf`（已修学分）/ `yqzdxf`（要求学分）/ `sftg`（是否通过）/ 板块名。
  /// 两步走是因为这四项与头部之间隔着一段 JS 模板字符串，位置不稳定。
  ///
  /// 同名节点只保留第一个 —— 教务会把同一个节点渲染两遍（树 + 模板）。
  static List<_Node> _parseNodes(String html) {
    final out = <_Node>[];
    final seenId = <String>{};
    final seenName = <String>{};

    for (final m in _nodeHeadRx.allMatches(html)) {
      final id = m.group(1)!;
      if (!seenId.add(id)) continue;

      final end = m.start + 900;
      final seg = html.substring(
          m.start, end > html.length ? html.length : end);

      String attr(String name) {
        final r = RegExp("$name='([^']*)'").firstMatch(seg);
        return (r?.group(1) ?? '').trim();
      }

      // 名称：`sftg='1'>` 之后是 `" + "` + `XXX&nbsp;` 这种拼接
      final name = _nodeName(seg);
      if (name.isEmpty || !seenName.add(name)) continue;

      out.add(_Node(
        id: id,
        name: name,
        leaf: m.group(3)!.trim().isNotEmpty,
        yxxf: attr('yxxf'),
        yqzdxf: attr('yqzdxf'),
        sftg: attr('sftg'),
      ));
    }
    return out;
  }

  /// 从节点窗口里抠板块名。教务原文形如：
  /// `sftg='1'>" + "\n  "通识（必）&nbsp;...`
  /// 也兼容没有拼接、直接内联的情况。
  static String _nodeName(String seg) {
    final patterns = <RegExp>[
      // `" + "` 拼接（实测就是这个形态）
      RegExp(r'''sftg='\d+'>\s*"\s*\+\s*"\s*([^"<&]{2,40})'''),
      // 只有一层引号
      RegExp(r'''sftg='\d+'>\s*"\s*([^"<&]{2,40})'''),
      // 完全内联
      RegExp(r'''sftg='\d+'>([^"<&]{2,40})'''),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(seg);
      if (m == null) continue;
      final v = m.group(1)!.replaceAll('&nbsp;', '').trim();
      if (v.isNotEmpty && !v.startsWith('+')) return v;
    }
    return '';
  }

  static String _csrf(String html) => extractCsrfToken(html);

  /// Mode B：没有培养方案，只能拿本学期课表按 `kclb` 分组。
  ///
  /// **不伪造「未修」课程** —— 课表里没有的课我们根本不知道存不存在。
  /// 状态只能按「有成绩且≥60 → 已修 / <60 → 未过 / 无成绩 → 在读」推，
  /// 且 `stateFromServer = false`，UI 会据此标注「客户端推导」。
  static Future<StudyArchive> _buildDegraded(
    CampusSession session,
    String xnm,
    String xqm, {
    String studentName = '',
  }) async {
    if (xnm.isEmpty || xqm.isEmpty) {
      return StudyArchive.unconfigured(
        notice: '教务暂未配置培养方案，且当前学期信息未知，暂时无法读取学业数据',
      );
    }

    Map<String, dynamic> schedule;
    try {
      schedule = await CourseFetcher.fetch(session, xnm, xqm);
    } catch (e) {
      if (e is CampusException && e.needRelogin) rethrow;
      return StudyArchive.unconfigured(
        notice: '教务暂未配置培养方案，且本学期课表读取失败，暂时无法显示学业数据',
      );
    }

    final raw = (schedule['courses'] as List?) ?? const [];
    if (raw.isEmpty) return StudyArchive.unconfigured();

    // 🔴 按成绩推导状态（函数上方注释承诺过，此前写死 studying 从未兑现）。
    // 整届没配培养方案的学生，课程门数从课表来、状态从成绩来 —— 否则他们会看到
    // 「在读 135 / 已修 0 / 完成 0%」，而其实已经修完一大半。
    //
    // 📐 2026-11-04 审查 P1：这里原来只 `num.tryParse`，非数字成绩一律
    //    `continue` —— 于是**等级制成绩全被当成没成绩**，`stateFor` 落到
    //    `studying`。后果有两个，第二个更严重：
    //      ① 「优秀 / 良好 / 中等 / 及格 / 合格 / 通过 / 免修 / 免听」这些
    //         **已经通过**的课显示成「在读」，通过门数偏少；
    //      ② 「不合格 / 不及格 / 不通过 / 取消资格」**挂科被抹平成「在读」**，
    //         学生看不到自己挂了什么，而这正是最需要看见的信息。
    //    修法：先把文本映射成三态（passed / failed / unknown），只有 unknown
    //    才继续留在「在读」；纯数字仍走原来的 >= 60 判据。
    final gradeByNo = <String, bool>{};
    final gradeByName = <String, bool>{};
    var gradesOk = false;
    try {
      final g = await JwglClient.fetchGrades(session);
      final sems = (g['semesters'] as List?) ?? const [];
      for (final s in sems) {
        if (s is! Map) continue;
        for (final c in (s['courses'] as List?) ?? const []) {
          if (c is! Map) continue;
          // cj 是成绩，bfzcj 是「百分制成绩」兜底（部分课程 cj 只给等级）。
          final passed = _passedFromGrade(
            '${c['cj'] ?? ''}'.trim(),
            '${c['bfzcj'] ?? ''}'.trim(),
          );
          if (passed == null) continue; // 真的判不出来，留在「在读」
          final no = '${c['kch'] ?? ''}'.trim();
          final nm = '${c['kcmc'] ?? ''}'.trim();
          if (no.isNotEmpty) gradeByNo.putIfAbsent(no, () => passed);
          if (nm.isNotEmpty) gradeByName.putIfAbsent(nm, () => passed);
        }
      }
      gradesOk = true;
    } catch (e) {
      // 成绩拉不到不能让整个学业页失败（课表已经有内容了），只是状态退回「在读」。
      if (e is CampusException && e.needRelogin) rethrow;
    }

    StudyState stateFor(String courseNo, String name) {
      if (!gradesOk) return StudyState.studying;
      final passed = gradeByNo[courseNo] ?? gradeByName[name];
      if (passed == null) return StudyState.studying;
      return passed ? StudyState.passed : StudyState.failed;
    }

    // 课表按「课程号 + 课程名」去重（同一门课一周上多次）
    final byKey = <String, Map<String, dynamic>>{};
    for (final e in raw) {
      if (e is! Map) continue;
      final c = Map<String, dynamic>.from(e);
      final r = (c['raw'] is Map) ? Map<String, dynamic>.from(c['raw'] as Map) : c;
      final kch = '${r['kch'] ?? ''}'.trim();
      final name = '${r['kcmc'] ?? c['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      byKey.putIfAbsent(kch.isNotEmpty ? kch : name, () => r);
    }

    final groups = <String, List<StudyCourse>>{};
    for (final r in byKey.values) {
      String pick(List<String> keys) {
        for (final k in keys) {
          final v = r[k];
          if (v != null && v.toString().trim().isNotEmpty) {
            return v.toString().trim();
          }
        }
        return '';
      }

      final category = pick(['kclb', 'KCLB', 'kclbmc', 'KCLBMC']);
      final groupName = category.isEmpty ? '其他课程' : category;
      final credits = double.tryParse(pick(['xf', 'XF'])) ?? 0;
      final courseNo = pick(['kch', 'KCH']);
      final courseName = pick(['kcmc', 'KCMC']);

      groups.putIfAbsent(groupName, () => []).add(StudyCourse(
            courseNo: courseNo,
            name: courseName,
            credits: credits,
            hours: pick(['kczxs', 'XSXXXX', 'zhxs']),
            nature: pick(['kcxz', 'KCXZMC']),
            category: groupName,
            state: stateFor(courseNo, courseName),
            studyYear: _yearLabel(xnm),
            studyTerm: xqm == '3' ? '1' : (xqm == '12' ? '2' : ''),
            stateFromServer: false,
          ));
    }

    if (groups.isEmpty) return StudyArchive.unconfigured();

    final blocks = groups.entries
        .map((e) => StudyBlock(
              id: e.key,
              name: e.key,
              courses: StudyArchive.sortCourses(e.value),
            ))
        .toList();

    return StudyArchive(
      mode: StudyMode.degraded,
      blocks: StudyArchive.sortBlocks(blocks),
      studentName: studentName,
      gradeYear: _yearLabel(xnm),
      fetchedAt: DateTime.now(),
      notice: kDegradedNotice,
    );
  }

  static String _yearLabel(String xnm) {
    final y = int.tryParse(xnm);
    return y == null ? xnm : '$xnm-${y + 1}';
  }

  /// `2025电气工程及其自动化` → `2025`。
  static String _gradeYear(String major) {
    final m = RegExp(r'^(\d{4})').firstMatch(major.trim());
    return m?.group(1) ?? '';
  }
  /// 把一条成绩判成「过 / 不过 / 判不出来」。
  ///
  /// 2026-11-04 审查 P1：教务给的成绩**不一定是数字**。五级制给「优秀 /
  /// 良好 / 中等 / 及格 / 不及格」，二级制给「合格 / 不合格」，还有一些课直接
  /// 给「通过 / 不通过 / 免修 / 免听 / 取消资格 / 缓考 / 缺考」。
  ///
  /// 这里只回答一件事：**这门算不算过了**。
  /// - 数字（含 `bfzcj` 百分制兜底）→ `>= 60`；
  /// - 明确的通过类字样 → true；
  /// - 明确的未通过类字样 → false；
  /// - 「缓考 / 缺考 / 未出分 / 空」这类**没有结论**的 → null（调用方留在「在读」）。
  ///
  /// 注意判定顺序：`不合格` 里含 `合格`，`不通过` 里含 `通过`，必须先判否定。
  static bool? _passedFromGrade(String cj, String bfzcj) {
    final text = cj.trim();
    final score = num.tryParse(text) ?? num.tryParse(bfzcj.trim());
    if (score != null) return score >= 60;
    if (text.isEmpty) return null;

    // 否定在前：「不合格」不能因为含「合格」被判过。
    const failedMarkers = <String>[
      '不合格', '不及格', '不通过', '未通过', '取消资格', '取消考试资格', '禁考',
    ];
    for (final m in failedMarkers) {
      if (text.contains(m)) return false;
    }
    const passedMarkers = <String>[
      '优秀', '良好', '中等', '及格', '合格', '通过',
      '免修', '免听', '免考',
    ];
    for (final m in passedMarkers) {
      if (text.contains(m)) return true;
    }
    // 缓考 / 缺考 / 未出分 / - / / 等：没有结论，别瞎猜。
    return null;
  }
}

class _Node {
  _Node({
    required this.id,
    required this.name,
    required this.leaf,
    required this.yxxf,
    required this.yqzdxf,
    required this.sftg,
  });

  final String id;
  final String name;
  final bool leaf;
  final String yxxf;
  final String yqzdxf;
  final String sftg;

  /// 通过门数：教务 `thzt` 实测恒为 `0,0,0`（不可用），
  /// 因此返回 null 让 [StudyBlock] 用课程 `XDZT` 实时统计。
  int? get passedByServer => null;
}
