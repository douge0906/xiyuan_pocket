import 'dart:async';

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
  static Future<Map<String, dynamic>> fetchGrades(
    CampusSession session, {
    int rows = 500,
  }) async {
    final csrf = await _openPage(session, _gradePage);

    // 「全部学期」+ 当前/前两个学期各查一次（行数拉满），合并去重
    final terms = <List<String>>[
      ['', ''],
      ..._recentTerms(2),
    ];

    final all = <Map<String, dynamic>>[];
    for (final t in terms) {
      final items = await _query(
        session,
        _gradeApi,
        {
          'xnm': t[0],
          'xqm': t[1],
          '_search': 'false',
          'nd': '${DateTime.now().millisecondsSinceEpoch}',
          'page': '1',
          'rows': '$rows',
          'sidx': '',
          'sord': 'asc',
          if (csrf.isNotEmpty) 'csrftoken': csrf,
        },
      );
      all.addAll(items);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }

    // 去重（课程号_课程名_学年_学期）
    final seen = <String>{};
    final unique = <Map<String, dynamic>>[];
    for (final g in all) {
      final key = '${g['kch']}_${g['kcmc']}_${g['xnm']}_${g['xqm']}';
      if (seen.add(key)) unique.add(g);
    }
    if (unique.isEmpty) {
      throw CampusException('未查询到成绩数据，请确认账号已选课或稍后重试');
    }
    return _buildGradeResult(unique);
  }

  /// 最近 n 个学年/学期码（含当前与前 2 个），用于兜底覆盖「全部学期」查询
  static List<List<String>> _recentTerms(int n) {
    final now = DateTime.now();
    var year = now.month >= 8 ? now.year : now.year - 1;
    var qm = now.month >= 8 ? '3' : '12';
    final out = <List<String>>[];
    for (var i = 0; i < n; i++) {
      out.add(['$year', qm]);
      if (qm == '3') {
        year -= 1;
        qm = '12';
      } else {
        qm = '3';
      }
    }
    return out;
  }

  /// 把原始成绩行整理为「按学期分组」的结构（字段与原实现一致）
  static Map<String, dynamic> _buildGradeResult(List<Map<String, dynamic>> grades) {
    final bySem = <String, List<Map<String, dynamic>>>{};
    for (final g in grades) {
      final key = '${g['xnmmc'] ?? ''} 第${g['xqmmc'] ?? ''}学期';
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
        final cxf = (c['xf'] as num).toDouble();
        allXf += cxf;
        allXfjd += cxf * (c['jd'] as num).toDouble();
      }
    }
    final first = grades.isNotEmpty ? grades.first : const <String, dynamic>{};

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
      'semester': '$xnm-${int.parse(xnm) + 1} 第${xqm == '3' ? 1 : 2}学期',
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
    final m = RegExp(r'id="csrftoken"[^>]*value="([^"]+)"').firstMatch(r.body);
    return m?.group(1) ?? '';
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
      if (emptyMeansEmpty) return const [];
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
