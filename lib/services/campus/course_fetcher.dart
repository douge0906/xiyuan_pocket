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
}