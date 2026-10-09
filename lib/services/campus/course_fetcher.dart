import 'campus_session.dart';
import 'jwgl_client.dart' show CampusException;

/// 课表查询（开源版 · 客户端直连）。
///
/// 抓取流程：
///   · 先打开课表页（拿 csrftoken，同时确保会话有效）
///   · POST `xskbcx_cxXsKb.html?doType=query`，尝试多组参数
///   · 解析正方教务系统的 JSON（字段名有多种别名）
///
/// ⚠️ 正方字段名各校/各版本不一，`_parseZhengfang` 覆盖常见别名
///    （覆盖正方教务的常见字段别名）。
class CourseFetcher {
  CourseFetcher._();

  static const String _base = 'https://jwgl.cwxu.edu.cn';
  static const String _kbPage =
      '$_base/jwglxt/kbcx/xskbcx_cxXsKb.html?gnmkdm=N2151&layout=default';

  /// 学期码 → 中文学期序号（与 Python `qmc` 一致）。
  static String semesterLabel(String xqm) {
    const m = {'3': '1', '12': '2', '16': '3'};
    return m[xqm] ?? xqm;
  }

  /// 查课表。返回结构：
  /// `{xnm, xqm, semester, courses: [...], count}`。
  static Future<Map<String, dynamic>> fetch(
    CampusSession session,
    String xnm,
    String xqm,
  ) async {
    // ① 打开课表页，拿 csrftoken（顺带校验会话）
    final csrftoken = await _openKbPage(session);

    // ② 尝试多组参数（兼容不同版本的正方）
    final payloads = <Map<String, String>>[
      {
        'xnm': xnm,
        'xqm': xqm,
        '_search': 'false',
        'nd': DateTime.now().millisecondsSinceEpoch.toString(),
        'queryModel.showCount': '100',
      },
      {
        'xnm': xnm,
        'xqm': xqm,
        'queryModel.showCount': '100',
        'queryModel.currentPage': '1',
      },
      {'xnm': xnm, 'xqm': xqm},
      {'xnm': xnm, 'xqm': xqm, 'XNXQDM': '$xnm-$xqm'},
    ];

    Object? lastError;
    for (final p in payloads) {
      final form = Map<String, String>.from(p);
      if (csrftoken.isNotEmpty) form['csrftoken'] = csrftoken;
      try {
        final r = await session.postForm(
          '$_base/jwglxt/kbcx/xskbcx_cxXsKb.html?doType=query',
          form,
          headers: {
            'Referer': _kbPage,
            'X-Requested-With': 'XMLHttpRequest',
            'Accept': 'application/json, text/javascript, */*; q=0.01',
          },
        );
        if (r.looksLikeLogin) {
          throw CampusException('登录已过期，请重新登录', needRelogin: true);
        }

        // 可能是 JSON，也可能是 `var xxx = {...};` 形式
        var j = CampusSession.tryJson(r.body);
        if (j == null) {
          final m = RegExp(r'var\s+\w+\s*=\s*(\{.*?\});', dotAll: true)
              .firstMatch(r.body);
          if (m != null) {
            try {
              j = CampusSession.tryJson(m.group(1)!);
            } catch (_) {}
          }
        }

        if (j != null) {
          final parsed = _parseZhengfang(j);
          if (parsed.isNotEmpty) {
            return {
              'xnm': xnm,
              'xqm': xqm,
              'semester': '$xnm-${int.parse(xnm) + 1} 第${semesterLabel(xqm)}学期',
              'courses': parsed,
              'count': parsed.length,
            };
          }
        }
        lastError = j ?? r.body.substring(0, r.body.length > 200 ? 200 : r.body.length);
      } catch (e) {
        lastError = e;
      }
    }

    throw CampusException('未能解析课程表数据，请检查学期参数。最后响应：$lastError');
  }

  /// 打开课表页取 csrftoken（对应 Python `fetch_schedule_page`）。
  static Future<String> _openKbPage(CampusSession session) async {
    final r = await session.get(_kbPage, headers: {
      'Referer': '$_base/jwglxt/xtgl/index_initMenu.html',
    });
    if (r.looksLikeLogin) {
      throw CampusException('登录已过期，请重新登录', needRelogin: true);
    }
    final m = RegExp(r'id="csrftoken"[^>]*value="([^"]+)"').firstMatch(r.body);
    return m?.group(1) ?? '';
  }

  /// 解析正方课表 JSON（对应 Python `_try_parse_zhengfang_schedule`）。
  ///
  /// 字段别名覆盖：课程名 `kcmc/courseName/KCMC`、教师 `jsxm/xm/teacher/teaxms`、
  /// 教室 `cdmc/classroom/room`、星期 `xqj/weekday/xq`、节次 `jcor/jcs/jc`。
  static List<Map<String, dynamic>> _parseZhengfang(Object data) {
    List<dynamic> raw;
    if (data is List) {
      raw = data;
    } else if (data is Map) {
      const keys = ['items', 'kbList', 'courseList', 'result', 'data'];
      raw = const [];
      for (final k in keys) {
        final v = data[k];
        if (v is List) {
          raw = v;
          break;
        }
      }
    } else {
      raw = const [];
    }

    final out = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final m = Map<String, dynamic>.from(item);

      String pick(List<String> names) {
        for (final n in names) {
          final v = m[n];
          if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
        }
        return '';
      }

      final name = pick(['kcmc', 'courseName', 'KCMC']);
      if (name.isEmpty) continue;

      out.add({
        'name': name,
        'teacher': pick(['jsxm', 'xm', 'teacher', 'teaxms', 'JSXM']),
        'classroom': pick(['cdmc', 'classroom', 'room', 'CDMC']),
        'weekday': pick(['xqj', 'weekday', 'xq', 'weekDay']),
        'slots': pick(['jcor', 'jcs', 'slot', 'jc']),
        'weeks': pick(['zcd', 'weeks', 'weekRange']),
        // 保留原始字段，便于界面按需取值
        'raw': m,
      });
    }
    return out;
  }

  // ==================== 班级课表（跨专业自选） ====================
  //
  // 教务「班级课表打印」模块，客户端直连（2026-10-09 抓包确认）：
  //   1. POST bjkbdy_cxBjkbdyTjkbList.html?gnmkdm=N214505 → 全部班级
  //   2. POST bjkbdy_cxBjKb.html?gnmkdm=N214505           → 单个班的课
  //
  // 🔴 两个地址都必须带 gnmkdm=N214505 —— 漏了教务直接 500「系统运行异常」；
  //    列表还必须带 queryModel.showCount=500，否则每页只有 10 行，
  //    会误以为要找的班级不存在（这两个坑都是探测时踩过的）。

  static const String _bjPage =
      '$_base/jwglxt/kbdy/bjkbdy_cxBjkbdyIndex.html?gnmkdm=N214505&layout=default';
  static const String _bjListUrl =
      '$_base/jwglxt/kbdy/bjkbdy_cxBjkbdyTjkbList.html?gnmkdm=N214505';
  static const String _bjKbUrl =
      '$_base/jwglxt/kbdy/bjkbdy_cxBjKb.html?gnmkdm=N214505';

  static final Map<String, List<Map<String, dynamic>>> _rowsCache = {};
  static final Map<String, DateTime> _rowsCacheAt = {};
  static String? _campusIdCache;
  static DateTime? _campusIdAt;

  /// 校区代码：打印页的下拉是服务端渲染的，取第一个非空选项（缓存 30 分钟）。
  static Future<String> _campusId(CampusSession session) async {
    final now = DateTime.now();
    if (_campusIdCache != null &&
        _campusIdAt != null &&
        now.difference(_campusIdAt!) < const Duration(minutes: 30)) {
      return _campusIdCache!;
    }
    final r = await session.get(_bjPage, headers: {
      'Referer': '$_base/jwglxt/xtgl/index_initMenu.html',
    });
    if (r.looksLikeLogin) {
      throw CampusException('登录已过期，请重新登录', needRelogin: true);
    }
    final m = RegExp(r'<select[^>]*id="xqh_id"[^>]*>(.*?)</select>',
            dotAll: true)
        .firstMatch(r.body);
    var val = '';
    if (m != null) {
      for (final o in RegExp(r'value="([^"]*)"').allMatches(m.group(1)!)) {
        final v = o.group(1)!;
        if (v.isNotEmpty) {
          val = v;
          break;
        }
      }
    }
    _campusIdCache = val;
    _campusIdAt = now;
    return val;
  }

  static Future<List<Map<String, dynamic>>> _classRows(
    CampusSession session,
    String xnm,
    String xqm,
    String xqhId,
  ) async {
    final key = '$xnm:$xqm:$xqhId';
    final now = DateTime.now();
    final at = _rowsCacheAt[key];
    if (at != null && now.difference(at) < const Duration(minutes: 30)) {
      return _rowsCache[key] ?? const [];
    }
    final r = await session.postForm(_bjListUrl, {
      'xnm': xnm,
      'xqm': xqm,
      'xqh_id': xqhId,
      'njdm_id': '',
      'jg_id': '',
      'zyh_id': '',
      'zyfx_id': '',
      'bh_id': '',
      'xsdm': '',
      'pyccdm': '',
      'kclxdm': '',
      'kclbdm': '',
      'sfzhsjk': '',
      'kbsjlyqz': '',
      'zs': '',
      'yf': '',
      'queryModel.showCount': '500',
      'queryModel.currentPage': '1',
    }, headers: {
      'Referer': _bjPage,
      'X-Requested-With': 'XMLHttpRequest',
      'Accept': 'application/json, text/javascript, */*; q=0.01',
    });
    if (r.looksLikeLogin) {
      throw CampusException('登录已过期，请重新登录', needRelogin: true);
    }
    final j = CampusSession.tryJson(r.body);
    final items = (j?['items']) as List? ?? const [];
    final rows = items
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    _rowsCache[key] = rows;
    _rowsCacheAt[key] = now;
    return rows;
  }

  /// 跨专业自选 · 步骤1：列出全部班级（可按班名/专业/学院关键字过滤）。
  /// 返回 `{xnm, xqm, total, count, classes:[{bh_id, bj, zymc, jgmc, njdm_id, xkrs}]}`。
  static Future<Map<String, dynamic>> searchClassList(
    CampusSession session,
    String xnm,
    String xqm,
    String keyword,
  ) async {
    final xqhId = await _campusId(session);
    final rows = await _classRows(session, xnm, xqm, xqhId);
    final kw = keyword.trim().toLowerCase();
    final classes = <Map<String, dynamic>>[];
    for (final row in rows) {
      final bj = (row['bj'] ?? '').toString();
      final zymc = (row['zymc'] ?? '').toString();
      final jgmc = (row['jgmc'] ?? '').toString();
      if (kw.isNotEmpty &&
          !bj.toLowerCase().contains(kw) &&
          !zymc.toLowerCase().contains(kw) &&
          !jgmc.toLowerCase().contains(kw)) {
        continue;
      }
      classes.add({
        'bh_id': (row['bh_id'] ?? '').toString(),
        'bj': bj,
        'zymc': zymc,
        'jgmc': jgmc,
        'njdm_id': (row['njdm_id'] ?? '').toString(),
        'xkrs': row['xkrs'],
      });
    }
    return {
      'xnm': xnm,
      'xqm': xqm,
      'total': rows.length,
      'count': classes.length,
      'classes': classes,
    };
  }

  /// 跨专业自选 · 步骤2：取一个班的课表。
  /// 返回 `{xnm, xqm, class, count, courses:[...]}`，课程字段与学生课表一致。
  static Future<Map<String, dynamic>> fetchClassCourses(
    CampusSession session,
    String xnm,
    String xqm,
    String bhId,
  ) async {
    final xqhId = await _campusId(session);
    final rows = await _classRows(session, xnm, xqm, xqhId);
    Map<String, dynamic>? row;
    for (final r in rows) {
      if ((r['bh_id'] ?? '').toString() == bhId) {
        row = r;
        break;
      }
    }
    if (row == null) {
      throw CampusException('班级不存在，或本学期没有它的课表');
    }
    final row0 = row;
    String p(String k) => (row0[k] ?? '').toString();
    final payload = <String, String>{
      for (final k in const [
        'xnm', 'xqm', 'xnmc', 'xqmmc', 'xqh_id', 'njdm_id', 'zyh_id',
        'bh_id', 'tjkbzdm', 'tjkbzxsdm', 'zymc', 'jgmc', 'njmc', 'bj',
        'xkrs', 'jsxm', 'lxdh', 'bh', 'zs', 'zxszjjs', 'xsdm', 'kclxdm',
        'kclbdm', 'kbsjlyqz', 'yf',
      ])
        k: p(k),
    };
    if (payload['xnmc']!.isEmpty) {
      payload['xnmc'] = '$xnm-${int.parse(xnm) + 1}';
    }
    if (payload['xqmmc']!.isEmpty) {
      payload['xqmmc'] = semesterLabel(xqm);
    }
    payload['zxszjjs'] = 'false';
    payload['kzlx'] = 'ck';

    final r = await session.postForm(_bjKbUrl, payload, headers: {
      'Referer': _bjPage,
      'X-Requested-With': 'XMLHttpRequest',
      'Accept': 'application/json, text/javascript, */*; q=0.01',
    });
    if (r.looksLikeLogin) {
      throw CampusException('登录已过期，请重新登录', needRelogin: true);
    }
    final j = CampusSession.tryJson(r.body);
    final kb = (j?['kbList']) as List? ?? const [];

    final courses = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final item in kb) {
      if (item is! Map) continue;
      final m = Map<String, dynamic>.from(item);
      final name = (m['kcmc'] ?? '').toString().trim();
      final weekday = int.tryParse((m['xqj'] ?? '').toString());
      final weeks = (m['zcd'] ?? '').toString().trim();
      final slotM =
          RegExp(r'(\d+)(?:-(\d+))?').firstMatch((m['jcor'] ?? '').toString());
      if (name.isEmpty || weekday == null || slotM == null || weeks.isEmpty) {
        continue; // 无固定节次的条目（实践课等）跳过，与其它导入口径一致
      }
      final start = int.parse(slotM.group(1)!);
      final end = int.tryParse(slotM.group(2) ?? '') ?? start;
      final key = '$name|$weekday|$start|$weeks';
      if (!seen.add(key)) continue;
      courses.add({
        'name': name,
        'teacher': (m['xm'] ?? '').toString().trim(),
        'classroom': (m['cdmc'] ?? '').toString().trim(),
        'weekday': weekday,
        'start_slot': start,
        'end_slot': end,
        'weeks': weeks,
      });
    }
    return {
      'xnm': xnm,
      'xqm': xqm,
      'class': (row['bj'] ?? '').toString(),
      'count': courses.length,
      'courses': courses,
    };
  }
}