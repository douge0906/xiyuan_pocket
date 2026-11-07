import 'dart:async';

import '../../models/academic_term.dart';
import 'campus_session.dart';
import 'cas_client.dart';

/// 正方教务（jwgl.cwxu.edu.cn）客户端 —— 纯 Dart，客户端直连。
///
/// 与「解析网页表格」无关：教务本身就提供 JSON 接口（`doType=query`），
/// 这里做的只是「先拿 csrftoken，再 POST 拿 JSON」。
/// 唯一的门票是登录后的会话 cookie（由 [CasClient] 建立）。
///
/// 输出结构**刻意与原实现保持一致**，这样界面层可以原样复用：
///   成绩 → {semesters:[{name, courses, total_xf, gpa}], summary, student}
///   考试 → {semester, exams:[...]}
class JwglClient {
  static const String _base = CasClient.jwglBase;

  // ---------------- 成绩 ----------------

  static const String _gradePage =
      '$_base/jwglxt/cjcx/cjcx_cxDgXscj.html?gnmkdm=N305005&layout=default';
  static const String _gradeApi =
      '$_base/jwglxt/cjcx/cjcx_cxXsgrcj.html?doType=query';

  /// 抓取全部学期成绩。失败抛 [CampusException]。
  ///
  /// 2026-10-29：不再固定只查 3 个学期，也不只看第一页。
  /// 先查「全部学期」，再补查最近 10 个学期；每个查询按 500/页翻页，
  /// 防止成绩行数超过 500 时后面的学期被截断。
  static Future<Map<String, dynamic>> fetchGrades(
    CampusSession session, {
    int rows = 500,
  }) async {
    final csrf = await _openPage(session, _gradePage);

    final all = <Map<String, dynamic>>[];
    Object? lastError;
    var failed = 0;

    Future<void> addTerm(List<String> t) async {
      try {
        final items = await _queryGrade(
          session,
          {
            'xnm': t[0],
            'xqm': t[1],
            '_search': 'false',
            'nd': '${DateTime.now().millisecondsSinceEpoch}',
            'page': '1',
            'rows': '$rows',
            'queryModel.showCount': '$rows',
            'queryModel.currentPage': '1',
            'queryModel.sortName': '',
            'queryModel.sortOrder': 'asc',
            'sidx': '',
            'sord': 'asc',
            if (csrf.isNotEmpty) 'csrftoken': csrf,
          },
          pageSize: rows,
        );
        all.addAll(items);
      } catch (e) {
        if (e is CampusException && e.needRelogin) rethrow;
        lastError = e;
        failed++;
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }

    // 先查「全部学期」，再补查最近 10 个学期。即使某个学期已出现，
    // 也仍然查询补漏：全部学期接口可能只返回该学期的一部分行。
    await addTerm(['', '']);
    for (final t in _recentTerms(10)) {
      await addTerm(t);
    }

    if (all.isEmpty && lastError != null) {
      throw lastError!;
    }

    // 去重：课程号/课程名 + 学期 + 教师 + 成绩。
    // 加教师和成绩，避免同名课的不同教学班/补考成绩被误删。
    final seen = <String>{};
    final unique = <Map<String, dynamic>>[];
    for (final g in all) {
      final key = '${g['kch'] ?? g['kcmc']}_${g['kcmc']}_'
          '${_gradeTermKey(g)}_${g['jsxm'] ?? ''}_'
          '${g['cj'] ?? g['bfzcj'] ?? ''}';
      if (seen.add(key)) unique.add(g);
    }
    if (unique.isEmpty) {
      // 🔴 不能抛错。另外三个查询（考试 / 教材 / 课表）的空结果都是
      //    `success: true` + 「暂无…」，只有这里 throw → 成绩页会把
      //    「本学期还没出成绩」渲染成红色错误卡片，还附带重试按钮。
      //    真正失败（登录过期 / 非 JSON）已在上游抛 CampusException。
      return <String, dynamic>{
        'success': true,
        'message': '暂无成绩数据',
        'semesters': <Map<String, dynamic>>[],
        'summary': <String, dynamic>{
          'gpa': 0,
          'totalCredits': 0,
          'passedCredits': 0,
          'courseCount': 0,
        },
        'student': <String, dynamic>{},
      };
    }
    final result = _buildGradeResult(unique);
    // 任一学期请求失败时明确告知界面，避免把不完整结果当成完整结果。
    if (failed > 0) result['partial'] = true;
    return result;
  }

  /// 成绩查询有两个常见入口，按顺序尝试；任一入口有数据即返回。
  static Future<List<Map<String, dynamic>>> _queryGrade(
    CampusSession session,
    Map<String, String> form, {
    required int pageSize,
  }) async {
    Object? lastError;
    var responded = false;
    for (final url in [
      _gradeApi,
      '$_gradePage?doType=query&gnmkdm=N305005',
    ]) {
      try {
        final items =
            await _queryAll(session, url, form, pageSize: pageSize);
        responded = true;
        if (items.isNotEmpty) return items;
      } catch (e) {
        if (e is CampusException && e.needRelogin) rethrow;
        lastError = e;
      }
    }
    if (responded) return const [];
    if (lastError != null) throw lastError;
    return const [];
  }

  /// 逐页拉取某个学期；服务端不认 page 时通过「没有新增行」停止。
  static Future<List<Map<String, dynamic>>> _queryAll(
    CampusSession session,
    String apiUrl,
    Map<String, String> form, {
    required int pageSize,
  }) async {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (var page = 1; page <= 10; page++) {
      final pageForm = <String, String>{
        ...form,
        'page': '$page',
        'rows': '$pageSize',
        'queryModel.currentPage': '$page',
        'queryModel.showCount': '$pageSize',
      };
      final items = await _query(session, apiUrl, pageForm);
      var added = 0;
      for (final item in items) {
        final key = '${item['kch'] ?? item['kcmc']}_'
            '${item['kcmc']}_${_gradeTermKey(item)}_'
            '${item['jsxm']}_${item['cj'] ?? item['bfzcj'] ?? ''}';
        if (seen.add(key)) {
          out.add(item);
          added++;
        }
      }
      if (items.isEmpty || added == 0) break;
    }
    return out;
  }

  /// 最近 n 个学年/学期码（含当前与前 2 个），用于兜底覆盖「全部学期」查询。
  ///
  /// 学期码唯一真源见 `models/academic_term.dart` —— 原来这里 `month >= 8` 的
  /// 写法在 1 月会把寒假算成「第二学期」，多查一个不存在的学期。
  static List<List<String>> _recentTerms(int n) {
    return [
      for (final t in recentAcademicTerms(n)) [t.xnm, t.xqm],
    ];
  }

  /// 学年/学期去重键：优先中文名，空串时才用代码兜底。
  static String _gradeTermKey(Map<String, dynamic> g) {
    String pick(String nameKey, String codeKey) {
      final name = (g[nameKey] ?? '').toString().trim();
      if (name.isNotEmpty) return name;
      return (g[codeKey] ?? '').toString().trim();
    }

    return '${pick('xnmmc', 'xnm')}|${pick('xqmmc', 'xqm')}';
  }

  /// 学期显示名。优先用教务给的中文名；缺失时用学年/学期码兜底，
  /// 避免所有课程被塞进「 第学期」一个空分组。
  static String _gradeSemesterLabel(Map<String, dynamic> g) {
    var year = (g['xnmmc'] ?? '').toString().trim();
    var term = (g['xqmmc'] ?? '').toString().trim();
    if (year.isEmpty) {
      final raw = (g['xnm'] ?? '').toString().trim();
      final y = int.tryParse(raw);
      year = y == null ? raw : '$y-${y + 1}';
    }
    if (term.isEmpty) {
      final qm = (g['xqm'] ?? '').toString().trim();
      term = switch (qm) {
        '3' => '1',
        '12' => '2',
        _ => qm,
      };
    }
    if (year.isEmpty) year = '未知学年';
    if (term.isEmpty) term = '?';
    if (term.startsWith('第')) {
      return '$year $term';
    }
    return '$year 第$term学期';
  }

  /// 把原始成绩行整理为「按学期分组」的结构（字段与原实现一致）
  static Map<String, dynamic> _buildGradeResult(List<Map<String, dynamic>> grades) {
    final bySem = <String, List<Map<String, dynamic>>>{};
    for (final g in grades) {
      final key = _gradeSemesterLabel(g);
      bySem.putIfAbsent(key, () => []).add(g);
    }

    final names = bySem.keys.toList()..sort((a, b) => b.compareTo(a));
    final semesters = <Map<String, dynamic>>[];
    for (final name in names) {
      final courses = bySem[name]!;
      var xf = 0.0;
      var xfjd = 0.0;
      final rows = <Map<String, dynamic>>[];
      for (final c in courses) {
        final cxf = double.tryParse('${c['xf'] ?? 0}') ?? 0.0;
        final jd = double.tryParse('${c['jd'] ?? 0}') ?? 0.0;
        xf += cxf;
        xfjd += cxf * jd;
        final score = '${c['cj'] ?? c['bfzcj'] ?? ''}';
        rows.add({
          'kcmc': c['kcmc'] ?? '',
          'cj': score,
          'xf': cxf,
          'jd': jd,
          'kcxzmc': c['kcxzmc'] ?? '',
          'jsxm': c['jsxm'] ?? '',
          'color': gradeColor(score),
        });
      }
      semesters.add({
        'name': name,
        'courses': rows,
        'total_xf': double.parse(xf.toStringAsFixed(2)),
        'gpa': xf > 0 ? double.parse((xfjd / xf).toStringAsFixed(3)) : 0.0,
      });
    }

    // 总览（全部学期加权）
    var allXf = 0.0;
    var allXfjd = 0.0;
    for (final s in semesters) {
      for (final c in (s['courses'] as List)) {
        if (c is! Map) continue;
        // 🔴 用 tryParse 而不是裸 `as num`：教务不同版本的字段类型不稳定，
        //    值为字符串时裸转会抛 TypeError → 整个成绩查询失败。
        final cxf = double.tryParse('${c['xf'] ?? 0}') ?? 0.0;
        final cjd = double.tryParse('${c['jd'] ?? 0}') ?? 0.0;
        allXf += cxf;
        allXfjd += cxf * cjd;
      }
    }
    final first = grades.isNotEmpty
        ? (grades.firstWhere(
            (g) =>
                '${g['xm'] ?? ''}'.trim().isNotEmpty ||
                '${g['xh'] ?? g['xh_id'] ?? ''}'.trim().isNotEmpty,
            orElse: () => grades.first,
          ))
        : const <String, dynamic>{};

    return {
      'success': true,
      'message': '成绩查询成功',
      'semesters': semesters,
      'summary': {
        'count': grades.length,
        'total_xf': double.parse(allXf.toStringAsFixed(2)),
        'gpa': allXf > 0 ? double.parse((allXfjd / allXf).toStringAsFixed(3)) : 0.0,
      },
      'student': {
        'xm': first['xm'] ?? '',
        'xh': first['xh'] ?? first['xh_id'] ?? '',
        'zymc': first['zymc'] ?? '',
        'jgmc': first['jgmc'] ?? '',
        'njmc': first['njmc'] ?? '',
      },
    };
  }

  /// 成绩分数 → 配色（与原实现一致）
  static String gradeColor(String? cj) {
    final s = int.tryParse((cj ?? '').replaceAll(RegExp(r'[^0-9]'), ''));
    if (s == null) return '#333333';
    if (s >= 90) return '#e74c3c';
    if (s >= 80) return '#e67e22';
    if (s >= 70) return '#f39c12';
    if (s >= 60) return '#27ae60';
    return '#95a5a6';
  }

  // ---------------- 考试安排 ----------------

  static const String _examPage =
      '$_base/jwglxt/kwgl/kscx_cxXsksxxIndex.html?gnmkdm=N3580&layout=default';
  static const String _examApi =
      '$_base/jwglxt/kwgl/kscx_cxXsksxxIndex.html?doType=query';

  /// 查询某学期考试安排。**该学期没有考试时返回空列表**（不是失败）。
  static Future<Map<String, dynamic>> queryExams(
    CampusSession session,
    String xnm,
    String xqm,
  ) async {
    final csrf = await _openPage(session, _examPage);
    final items = await _query(
      session,
      _examApi,
      {
        'xnm': xnm,
        'xqm': xqm,
        '_search': 'false',
        'nd': '${DateTime.now().millisecondsSinceEpoch}',
        'queryModel.showCount': '100',
        if (csrf.isNotEmpty) 'csrftoken': csrf,
      },
      // 空 items 视为「本学期暂无考试安排」（合法响应），不抛错
      emptyMeansEmpty: true,
    );

    final exams = items.map(_mapExam).toList();
    return {
      'success': true,
      'message': exams.isEmpty ? '本学期暂无考试安排' : '考试安排查询成功',
      'semester': '${_academicYear(xnm)} 第${xqm == '3' ? 1 : 2}学期',
      'exams': exams,
      'count': exams.length,
    };
  }

  static Map<String, dynamic> _mapExam(Map<String, dynamic> e) {
    final raw = '${e['kssj'] ?? ''}';
    // kssj 形如 "2026-07-08(09:00-11:00)"
    final date = raw.contains('(') ? raw.substring(0, raw.indexOf('(')) : raw;
    String start = '', end = '';
    final m = RegExp(r'\((\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})\)').firstMatch(raw);
    if (m != null) {
      start = m.group(1)!;
      end = m.group(2)!;
    }
    return {
      'name': e['kcmc'] ?? '',
      'teacher': e['jsxx'] ?? '',
      'classroom': e['cdmc'] ?? '',
      'date': date,
      'start_time': start,
      'end_time': end,
      'raw_time': raw,
    };
  }

  // ---------------- 教材预订 ----------------

  /// 教材预订页目录（用户实测地址：
  /// `…/jwglxt/xsxk/tjxkyzb_cxXkResultTjxkYzb.html?gnmkdm=N253520&layout=default`）。
  ///
  /// ⚠️ 这不是「教材」自己的模块，而是**选课（xsxk）→ 教材预订**的推荐结果页，
  /// 目录与文件名与「教材」二字毫无关系 —— 早期按 `xtgl/xkjcjyb` 猜的路径是错的，
  /// 所以一条数据都拿不到。这里保留少量变体做兼容，实测地址放第一位。
  static const List<String> _bookDirs = [
    'xsxk',
    'xtgl/xsxk',
  ];
  static const String _bookGnmkdm = 'N253520';
  /// 页面与接口同名（正方这个模块用的是同一个 html 文件）。
  static const String _bookPage = 'tjxkyzb_cxXkResultTjxkYzb.html';

  /// 查某学期教材预订信息（页面上是「教材预订」菜单）。
  ///
  /// 返回 `{success, message, semester, books:[...], count}`。
  /// **该学期没有教材时返回空列表**（合法响应），不算失败。
  static Future<Map<String, dynamic>> queryTextbooks(
    CampusSession session,
    String xnm,
    String xqm,
  ) async {
    Object? lastError;
    List<Map<String, dynamic>> books = const [];

    for (final dir in _bookDirs) {
      final page =
          '$_base/jwglxt/$dir/$_bookPage?gnmkdm=$_bookGnmkdm&layout=default';
      // 查询走正方的标准 JSON 接口：同一个 html 加 doType=query
      final api =
          '$_base/jwglxt/$dir/$_bookPage?gnmkdm=$_bookGnmkdm&doType=query';
      try {
        final csrf = await _openPage(session, page);
        // 🔴 每成功打开一个目录就把 lastError 清掉。
        //    `_bookDirs` 有多个候选目录，正常情况下靠「空 → 继续试下一个」
        //    跳过失效目录；但那些失效目录会各自留下 lastError，等到最后一个
        //    目录也返回空时，`books.isEmpty && lastError != null` 成立 →
        //    真正「本学期没有教材」被报成「网络异常，请检查网络后重试」。
        lastError = null;
        final items = await _query(
          session,
          api,
          {
            'xnm': xnm,
            'xqm': xqm,
            '_search': 'false',
            'nd': '${DateTime.now().millisecondsSinceEpoch}',
            'page': '1',
            'rows': '200',
            'sidx': '',
            'sord': 'asc',
            if (csrf.isNotEmpty) 'csrftoken': csrf,
          },
          emptyMeansEmpty: true,
          referer: page,
        );
        if (items.isNotEmpty) {
          books = items.map(_mapTextbook).toList();
          break;
        }
        // JSON 没拿到 → 该模块也可能是**服务端渲染的 HTML 表格**，再试一次解析页面。
        final htmlBooks = await _queryBooksFromHtml(session, page);
        if (htmlBooks.isNotEmpty) {
          books = htmlBooks;
          break;
        }
        // 仍为空：可能这个目录不是本版本的路径 → 继续试下一个
      } catch (e) {
        lastError = e;
        if (e is CampusException && e.needRelogin) rethrow;
      }
    }

    if (books.isEmpty && lastError is CampusException) throw lastError;
    // 2026-10-13：**网络类异常也必须抛出去**。原来只重抛
    // CampusException，断网/超时被吞掉后返回 success:true 且文案
    // 「本学期暂无教材信息」—— 用户以为教务真的没教材（代码审查报告：断网误报空）。
    if (books.isEmpty && lastError != null) {
      throw CampusException('网络异常，请检查网络后重试');
    }

    return {
      'success': true,
      'message': books.isEmpty ? '本学期暂无教材信息' : '教材查询成功',
      'semester': _semesterLabel(xnm, xqm),
      'books': books,
      'count': books.length,
    };
  }

  /// 从**服务端渲染的 HTML 表格**里取教材行（JSON 接口拿不到时的兜底）。
  ///
  /// 列的固定顺序（与实际页面表头一致）：
  /// 教材预订单 | 学年 | 学期 | 课程名称 | 上课教师 | 课程性质 |
  /// 教材信息 | 上课地点 | 选课时间 | 征订状态 | 预订时间
  static Future<List<Map<String, dynamic>>> _queryBooksFromHtml(
    CampusSession session,
    String pageUrl,
  ) async {
    final r = await session.get(pageUrl, headers: {
      'Referer': '$_base/jwglxt/xtgl/index_initMenu.html',
    });
    if (r.looksLikeLogin) {
      throw CampusException('登录已过期，请重新登录', needRelogin: true);
    }
    final rows = _parseTableRows(r.body);
    if (rows.isEmpty) return const [];

    // 表头行用来定位「课程名称」等列的下标 —— 不同版本列序可能不同，
    // 因此优先按表头名称映射；找不到表头（无 thead）时退回固定顺序。
    final header = rows.first;
    int idxOf(List<String> names, int fallback) {
      for (var i = 0; i < header.length; i++) {
        final h = header[i].replaceAll(RegExp(r'\s+'), '');
        for (final n in names) {
          if (h.contains(n)) return i;
        }
      }
      return fallback;
    }

    final cName = idxOf(['课程名称', '课程'], 3);
    final cTeacher = idxOf(['上课教师', '教师'], 4);
    final cNature = idxOf(['课程性质', '性质'], 5);
    final cBook = idxOf(['教材信息', '教材'], 6);
    final cRoom = idxOf(['上课地点', '地点'], 7);
    final cStatus = idxOf(['征订状态', '状态'], 9);

    String at(List<String> row, int i) =>
        (i >= 0 && i < row.length) ? row[i].trim() : '';

    final out = <Map<String, dynamic>>[];
    for (final row in rows.skip(1)) {
      final name = at(row, cName);
      if (name.isEmpty) continue;
      // 跳过「暂无数据」这类占位行
      if (name.contains('暂无') || name.contains('无数据')) continue;
      out.add({
        'name': name,
        'teacher': at(row, cTeacher),
        'nature': at(row, cNature),
        'book': at(row, cBook),
        'classroom': at(row, cRoom),
        'status': at(row, cStatus),
        'raw': {'row': row},
      });
    }
    return out;
  }

  /// 把 HTML 里的 `<tr>/<td>` 拆成二维文本表（去标签、反转义）。
  static List<List<String>> _parseTableRows(String html) {
    final body = html.replaceAll(RegExp(r'<(script|style)[^>]*>.*?</\1>',
        dotAll: true, caseSensitive: false), '');
    final trRe = RegExp(r'<tr[^>]*>(.*?)</tr>', dotAll: true, caseSensitive: false);
    final cellRe =
        RegExp(r'<t[dh][^>]*>(.*?)</t[dh]>', dotAll: true, caseSensitive: false);
    final out = <List<String>>[];
    for (final m in trRe.allMatches(body)) {
      final cells = <String>[];
      for (final c in cellRe.allMatches(m.group(1)!)) {
        cells.add(_cellText(c.group(1)!));
      }
      if (cells.any((e) => e.isNotEmpty)) out.add(cells);
    }
    return out;
  }

  static String _cellText(String cell) {
    final t = cell
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll(RegExp(r'\s+'), ' ');
    return t.trim();
  }

  static String _semesterLabel(String xnm, String xqm) {
    final y = int.tryParse(xnm);
    final term = xqm == '3' ? 1 : (xqm == '12' ? 2 : 0);
    if (y == null) return xnm;
    return term == 0 ? '$y 学年' : '$y-${y + 1} 第$term学期';
  }

  /// 教材条目的字段别名兼容（正方各版本键名不一）。
  static Map<String, dynamic> _mapTextbook(Map<String, dynamic> e) {
    String pick(List<String> names) {
      for (final n in names) {
        final v = e[n];
        if (v != null && v.toString().trim().isNotEmpty) {
          return v.toString().trim();
        }
      }
      return '';
    }

    return {
      // 页面列：教材预订单 | 学年 | 学期 | 课程名称 | 上课教师 | 课程性质 |
      //         教材信息 | 上课地点 | 选课时间 | 征订状态 | 预订时间
      'name': pick(['kcmc', 'courseName', 'KCMC']),
      'teacher': pick(['skjs', 'jsxm', 'jsxx', 'teacher', 'xm', 'JSXM', 'SKJS']),
      'nature': pick(['kcxzmc', 'kcxz', 'courseNature', 'KCXZMC', 'KCXZ']),
      // 教材信息：书名 / 作者 / 出版社 合成的一串（如「测绘工程CAD/吕翠华/武汉大学出版社/3」）
      'book': pick(['jcxx', 'jcmc', 'textbook', 'JCXX', 'jcsj', 'jcbh']),
      'classroom': pick(['skdd', 'cdmc', 'classroom', 'CDMC', 'kkdd', 'SKDD']),
      // 征订状态：已订 / 未订 / 不在预订时间内（注意：含「不在预订时间内」也算有效值）
      'status': pick(['zdztmc', 'zdzt', 'zxzt', 'status', 'dinggouzt', 'ZDZTMC']),
      'semester': pick(['xnm', 'xnmmc', 'semester']),
      'term': pick(['xqm', 'xqmmc', 'term']),
      'select_time': pick(['xksj', 'xksjmc', 'selectTime']),
      'order_time': pick(['ydsj', 'ydsjmc', 'orderTime']),
      'raw': e,
    };
  }

  // ---------------- 通用 ----------------

  /// 打开业务页：拿 csrftoken，并判断会话是否失效
  static Future<String> _openPage(CampusSession session, String pageUrl) async {
    final r = await session.get(pageUrl, headers: {
      'Referer': '$_base/jwglxt/xtgl/index_initMenu.html',
    });
    if (r.looksLikeLogin) {
      throw CampusException('登录已过期，请重新登录', needRelogin: true);
    }
    return extractCsrfToken(r.body);
  }

  static Future<List<Map<String, dynamic>>> _query(
    CampusSession session,
    String apiUrl,
    Map<String, String> form, {
    bool emptyMeansEmpty = false,
    String? referer,
  }) async {
    final r = await session.postForm(apiUrl, form, headers: {
      'Referer': referer ?? '$_base/jwglxt/xtgl/index_initMenu.html',
      'X-Requested-With': 'XMLHttpRequest',
    });
    if (r.looksLikeLogin) {
      throw CampusException('登录已过期，请重新登录', needRelogin: true);
    }
    final j = CampusSession.tryJsonAny(r.body);
    if (j == null) {
      // 🔴 `emptyMeansEmpty` 只该用于「形状合法的空结果」，不能用于
      //    「压根不是 JSON」。原来这里直接 `return const []`，于是
      //    登录页 HTML、维护页、`{"code":"-1"}` 都被当成「本学期没有数据」
      //    —— 考试页与教材页因此长期示人「暂无考试 / 暂无教材」，
      //    而真相是查询失败。
      //    非 JSON 一律抛错，让上层显示「查询失败，请重试」。
      throw CampusException('教务返回了非预期内容（可能正在维护）');
    }
    // 形态一：{items:[...]}（成绩/课表/考试等多数模块）
    if (j is Map) {
      final items = j['items'];
      if (items is List) {
        return items
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
      // 有些模块把数组放在 rows / data 里
      for (final key in const ['rows', 'data', 'list']) {
        final v = j[key];
        if (v is List) {
          return v
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      }
    }
    // 形态二：顶层直接就是数组（教材预订等模块）
    if (j is List) {
      return j
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    // 到这里还剩三种情况，必须分开：
    //   · Map 里出现了「我们知道怎么读」的容器键但值是空数组
    //     → 真的是这一学期没有数据，可以放心返回空；
    //   · Map 是**成功响应但没有容器键**（正方对「本学期无考试」常见返回
    //     形如 {"code":"0","msg":"操作成功"}）
    //     → 也是「没有数据」。🔴 这一条不能漏：漏了会把「暂无考试安排」
    //       变成红卡报错，正好砸在本轮想修的那两个页面上；
    //   · Map 里带失败码（典型 {"code":"-1","msg":"..."}）
    //     → 查询失败，不是「没有数据」。原来靠 emptyMeansEmpty 返回空，
    //       把失败包装成了「暂无」，用户永远看不到错误提示。
    if (j is Map) {
      const containerKeys = ['items', 'rows', 'data', 'list'];
      if (containerKeys.any(j.containsKey)) return const [];
      // 正方成功码：历史上出现过 '0' / 0 / '200' / 'success' 四种写法。
      final code = j['code'] ?? j['status'];
      final ok = code == null ||
          code == 0 ||
          code == '0' ||
          code == 200 ||
          code == '200' ||
          '$code'.toLowerCase() == 'success';
      if (ok && (j.containsKey('msg') || j.containsKey('message'))) {
        return const [];
      }
    }
    if (emptyMeansEmpty) return const [];
    throw CampusException('未能解析教务返回的数据');
  }
}

class CampusException implements Exception {
  final String message;
  final bool needRelogin;
  CampusException(this.message, {this.needRelogin = false});

  @override
  String toString() => message;
}

/// 学年名称：「2025」→「2025-2026」。
///
/// 用 tryParse 而不是裸 int.parse：xnm 来自 UI 透传，一旦传进来
/// 「2025-2026」或空串，裸 parse 会抛 FormatException 打断整条抓取链路。
String _academicYear(String xnm) {
  final y = int.tryParse(xnm);
  return y == null ? xnm : '$xnm-${y + 1}';
}
