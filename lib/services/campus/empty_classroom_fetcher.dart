import '../../models/academic_term.dart';
import 'campus_session.dart';
import 'cas_client.dart';
import 'jwgl_client.dart';

/// 空教室查询相关模型与教务抓取器（客户端直连，复用现有 CAS 会话）。
///
/// 侦察结论来自 2026-11-16 真实教务页面与两次真实 POST：
/// - 页面：`/jwglxt/cdjy/cdjy_cxKxcdlb.html?gnmkdm=N2155&layout=default`
/// - 选项：`/jwglxt/cdjy/cdjy_cxXqjc.html?xqh_id=&xnm=&xqm=`
/// - 查询：`/jwglxt/cdjy/cdjy_cxKxcdlb.html?doType=query`
/// - 周次/节次是位掩码；星期是逗号拼接的 value 列表；楼号提交 option value。
class EmptyClassroomBuilding {
  const EmptyClassroomBuilding({required this.value, required this.label});

  final String value;
  final String label;

  /// 教务「全部」楼号在真实 HTML 里就是空字符串。UI 用单独的选中态表达，
  /// 但提交时仍必须把空串发给教务。
  bool get isAll => value.isEmpty;

  Map<String, dynamic> toJson() => {'value': value, 'label': label};

  static EmptyClassroomBuilding fromJson(Map<String, dynamic> j) =>
      EmptyClassroomBuilding(
        value: '${j['value'] ?? ''}',
        label: '${j['label'] ?? ''}',
      );
}

/// 节次选项，节次号 [index] 与教务 `JCMC` 对齐；[time] 是 `SJD` 时间段。
class EmptyClassroomSection {
  const EmptyClassroomSection({
    required this.index,
    required this.period,
    required this.time,
  });

  final int index;
  final String period;
  final String time;

  String get label => '第$index节';

  Map<String, dynamic> toJson() => {
        'index': index,
        'period': period,
        'time': time,
      };

  static EmptyClassroomSection fromJson(Map<String, dynamic> j) =>
      EmptyClassroomSection(
        index: _parseInt(j['index']),
        period: '${j['period'] ?? ''}',
        time: '${j['time'] ?? ''}',
      );
}

/// 打开页面后自动携带的学期 / 校区上下文；UI 不新增学期、校区必选项。
class EmptyClassroomOptions {
  const EmptyClassroomOptions({
    required this.xnm,
    required this.xqm,
    required this.campusId,
    required this.campusLabel,
    required this.weekMax,
    required this.buildings,
    required this.sections,
  });

  final String xnm;
  final String xqm;
  final String campusId;
  final String campusLabel;
  final int weekMax;
  final List<EmptyClassroomBuilding> buildings;
  final List<EmptyClassroomSection> sections;

  String get semesterLabel {
    final year = int.tryParse(xnm);
    final yearText = year == null ? xnm : '$year-${year + 1}';
    final termText = switch (xqm) {
      '1' || '3' => '第一',
      '2' || '12' => '第二',
      _ => '',
    };
    return '$yearText学年${termText.isEmpty ? '（学期待确认）' : ' $termText学期'}';
  }

  Map<String, dynamic> toJson() => {
        'xnm': xnm,
        'xqm': xqm,
        'campusId': campusId,
        'campusLabel': campusLabel,
        'weekMax': weekMax,
        'buildings': buildings.map((e) => e.toJson()).toList(),
        'sections': sections.map((e) => e.toJson()).toList(),
      };

  static EmptyClassroomOptions fromJson(Map<String, dynamic> j) =>
      EmptyClassroomOptions(
        xnm: '${j['xnm'] ?? ''}',
        xqm: '${j['xqm'] ?? ''}',
        campusId: '${j['campusId'] ?? ''}',
        campusLabel: '${j['campusLabel'] ?? ''}',
        weekMax: _parseInt(j['weekMax'], fallback: 19),
        buildings: (j['buildings'] as List? ?? [])
            .whereType<Map>()
            .map((e) =>
                EmptyClassroomBuilding.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        sections: (j['sections'] as List? ?? [])
            .whereType<Map>()
            .map((e) =>
                EmptyClassroomSection.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

/// UI 只传四项筛选；学期、校区由服务层从页面上下文补齐。
class EmptyClassroomQuery {
  const EmptyClassroomQuery({
    required this.xnm,
    required this.xqm,
    required this.campusId,
    required this.weeks,
    required this.weekdays,
    required this.slots,
    required this.buildingValue,
  });

  final String xnm;
  final String xqm;
  final String campusId;

  /// 教学周，1 起。
  final List<int> weeks;

  /// 星期，1=周一 … 7=周日，与教务 `xqj` value 对齐。
  final List<int> weekdays;

  /// 节次号，1 起。
  final List<int> slots;

  /// 楼号 option value；空串表示「全部」。
  final String buildingValue;

  /// 四项必填校验；楼号空串是合法的「全部」，不算缺失。
  String? validateMissing() {
    if (weeks.isEmpty) return '请选择周次';
    if (weekdays.isEmpty) return '请选择星期';
    if (slots.isEmpty) return '请选择节次';
    return null;
  }
}

class EmptyClassroomRoom {
  const EmptyClassroomRoom({
    required this.id,
    required this.code,
    required this.name,
    required this.buildingCode,
    required this.building,
    required this.floor,
    required this.campus,
    required this.category,
    required this.seats,
    required this.examSeats,
  });

  final String id;
  final String code;
  final String name;
  final String buildingCode;
  final String building;
  final String floor;
  final String campus;
  final String category;
  final int? seats;
  final int? examSeats;

  Map<String, dynamic> toJson() => {
        'id': id,
        'code': code,
        'name': name,
        'buildingCode': buildingCode,
        'building': building,
        'floor': floor,
        'campus': campus,
        'category': category,
        'seats': seats,
        'examSeats': examSeats,
      };

  static EmptyClassroomRoom fromJson(Map<String, dynamic> j) =>
      EmptyClassroomRoom(
        id: '${j['cd_id'] ?? j['cdbh'] ?? ''}',
        code: '${j['cdbh'] ?? j['cd_id'] ?? ''}',
        name: '${j['cdmc'] ?? ''}',
        buildingCode: '${j['lh'] ?? ''}',
        building: '${j['jxlmc'] ?? ''}',
        floor: '${j['lch'] ?? ''}',
        campus: '${j['xqmc'] ?? ''}',
        category: '${j['cdlbmc'] ?? ''}',
        seats: _parseNullableInt(j['zws']),
        examSeats: _parseNullableInt(j['kszws1']),
      );
}

class EmptyClassroomResult {
  const EmptyClassroomResult({
    required this.rooms,
    required this.total,
    required this.message,
  });

  final List<EmptyClassroomRoom> rooms;
  final int total;
  final String? message;

  Map<String, dynamic> toJson() => {
        'rooms': rooms.map((e) => e.toJson()).toList(),
        'total': total,
        'message': message,
      };
}

class _QueryCacheEntry {
  const _QueryCacheEntry(this.result, this.at);

  final EmptyClassroomResult result;
  final DateTime at;
}

/// 教务空教室模块的纯 Dart 抓取器。
class EmptyClassroomFetcher {
  static const String _base = CasClient.jwglBase;
  static const String _pagePath =
      '/jwglxt/cdjy/cdjy_cxKxcdlb.html?gnmkdm=N2155&layout=default';
  static const String _optionPath = '/jwglxt/cdjy/cdjy_cxXqjc.html';
  static const String _queryPath =
      '/jwglxt/cdjy/cdjy_cxKxcdlb.html?doType=query&gnmkdm=N2155';

  static const Duration _cacheTtl = Duration(minutes: 30);
  static const Duration _queryCacheTtl = Duration(minutes: 5);
  static EmptyClassroomOptions? _cachedOptions;
  static DateTime? _cachedAt;
  static String? _cachedKey;
  static final Map<String, _QueryCacheEntry> _queryCache = {};

  /// 退出登录/切换账号时清空空教室选项与查询结果缓存。
  ///
  /// 选项里带学期和校区；跨账号复用会把上一账号的楼号、节次带过来，
  /// 也会让教务侧上下文和当前账号不一致。查询结果同理，按账号隔离。
  static void clearCache() {
    _cachedOptions = null;
    _cachedAt = null;
    _cachedKey = null;
    _queryCache.clear();
  }

  static Future<EmptyClassroomOptions> fetchOptions(
    CampusSessionBase session, {
    bool forceRefresh = false,
    String cacheKey = '',
  }) async {
    final cached = _cachedOptions;
    final cachedAt = _cachedAt;
    if (!forceRefresh &&
        cached != null &&
        cachedAt != null &&
        _cachedKey == cacheKey &&
        DateTime.now().difference(cachedAt) < _cacheTtl) {
      return cached;
    }

    final (csrf, html) = await _openPage(session);
    final context = _parsePageContext(html);

    final optionUri = Uri.parse('$_base$_optionPath').replace(queryParameters: {
      'xqh_id': context.campusId,
      'xnm': context.xnm,
      'xqm': context.xqm,
    });
    final dynamicJson = await session.get(
      optionUri.toString(),
      headers: {
        'Referer': '$_base$_pagePath',
        'X-Requested-With': 'XMLHttpRequest',
      },
    );
    if (dynamicJson.looksLikeLogin) {
      throw CampusException('登录已过期，请重新登录', needRelogin: true);
    }

    final parsed = CampusSession.tryJson(dynamicJson.body);
    if (parsed == null) {
      throw CampusException('教务选项返回了非预期内容（可能正在维护）');
    }

    final buildings = parseBuildings(parsed, html);
    final sections = parseSections(parsed);
    if (buildings.length <= 1) {
      // 只有「全部」说明楼号清单没取到；不能退化成截图里的 7 项。
      throw CampusException('未能从教务读取完整楼号列表，请重试');
    }
    if (sections.isEmpty) {
      throw CampusException('未能从教务读取节次列表，请重试');
    }

    final options = EmptyClassroomOptions(
      xnm: context.xnm,
      xqm: context.xqm,
      campusId: context.campusId,
      campusLabel: context.campusLabel,
      weekMax: context.weekMax,
      buildings: buildings,
      sections: sections,
    );
    _cachedOptions = options;
    _cachedAt = DateTime.now();
    _cachedKey = cacheKey;
    return options;
  }

  static Future<EmptyClassroomResult> query(
    CampusSessionBase session,
    EmptyClassroomQuery query, {
    String cacheKey = '',
  }) async {
    if (query.weeks.isEmpty || query.weekdays.isEmpty || query.slots.isEmpty) {
      throw CampusException('请先完整选择周次、星期和节次');
    }

    // 查询结果缓存只保留 5 分钟：空教室是动态资源，跨了课间/临时借教室
    // 就不该继续命中。key 把账号和全部筛选条件都带上，换账号/换条件不串。
    final queryKey = [
      cacheKey,
      query.xnm,
      query.xqm,
      query.campusId,
      maskOf(query.weeks),
      joinWeekdays(query.weekdays),
      maskOf(query.slots),
      query.buildingValue,
    ].join('|');
    final hit = _queryCache[queryKey];
    if (hit != null && DateTime.now().difference(hit.at) < _queryCacheTtl) {
      return hit.result;
    }

    final (csrf, html) = await _openPage(session);
    final context = _parsePageContext(html);
    final xnm = query.xnm.isEmpty ? context.xnm : query.xnm;
    final xqm = query.xqm.isEmpty ? context.xqm : query.xqm;
    final campusId = query.campusId.isEmpty ? context.campusId : query.campusId;

    final form = <String, String>{
      'xqh_id': campusId,
      'xnm': xnm,
      'xqm': xqm,
      'cdlb_id': '',
      'cdejlb_id': '',
      'qszws': '',
      'jszws': '',
      'cdmc': '',
      'cd_id': '',
      'lh': query.buildingValue,
      'jyfs': '0',
      'cdjylx': '',
      'zysx': '',
      'sflb': '',
      'hbsl': '',
      'bbsl': '',
      'sfyzz': '',
      'sfjtjs': '',
      'tjsl': '',
      'tymbsl': '',
      'yczb': '',
      'zws': '',
      'sfbhkc': '',
      'kszws1': '',
      'zcd': '${maskOf(query.weeks)}',
      'xqj': joinWeekdays(query.weekdays),
      'jcd': '${maskOf(query.slots)}',
      '_search': 'false',
      'nd': '${DateTime.now().millisecondsSinceEpoch}',
      'page': '1',
      'rows': '500',
      'queryModel.showCount': '500',
      'queryModel.currentPage': '1',
      'queryModel.sortName': 'cdbh',
      'queryModel.sortOrder': 'asc',
      if (csrf.isNotEmpty) 'csrftoken': csrf,
    };

    final r = await session.postForm(
      '$_base$_queryPath',
      form,
      headers: {
        'Referer': '$_base$_pagePath',
        'X-Requested-With': 'XMLHttpRequest',
      },
    );
    if (r.looksLikeLogin) {
      throw CampusException('登录已过期，请重新登录', needRelogin: true);
    }

    final j = CampusSession.tryJson(r.body);
    if (j == null) {
      throw CampusException('教务返回了非预期内容（可能正在维护）');
    }
    final result = parseResult(j);
    if (_queryCache.length >= 32) {
      _queryCache.remove(_queryCache.keys.first);
    }
    _queryCache[queryKey] = _QueryCacheEntry(result, DateTime.now());
    return result;
  }

  /// 解析教务查询响应；抽成静态方法便于单测覆盖空列表、缺失字段和排序。
  static EmptyClassroomResult parseResult(Map<String, dynamic> j) {
    final items = (j['items'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final rooms = items.map(EmptyClassroomRoom.fromJson).toList();
    _sortRooms(rooms);

    final total = _parseInt(
      j['totalResult'] ?? j['totalCount'] ?? rooms.length,
      fallback: rooms.length,
    );
    return EmptyClassroomResult(
      rooms: rooms,
      total: total,
      message: rooms.isEmpty ? '这个时段没有空闲教室' : null,
    );
  }

  static Future<(String csrf, String html)> _openPage(
      CampusSessionBase session) async {
    final r = await session.get('$_base$_pagePath', headers: {
      'Referer': '$_base/jwglxt/xtgl/index_initMenu.html',
    });
    if (r.looksLikeLogin) {
      throw CampusException('登录已过期，请重新登录', needRelogin: true);
    }
    return (extractCsrfToken(r.body), r.body);
  }

  static _PageContext _parsePageContext(String html) {
    final term = currentAcademicTerm();
    final xnm = _hiddenValue(html, 'xnm').ifEmpty(term.xnm);
    final xqm = _hiddenValue(html, 'xqm').ifEmpty(term.xqm);

    String campusId = '';
    String campusLabel = '';
    final campusOptions = _selectOptions(html, 'xqh_id');
    if (campusOptions.isNotEmpty) {
      var picked = campusOptions.first;
      for (final option in campusOptions) {
        if (option.selected) {
          picked = option;
          break;
        }
      }
      campusId = picked.value;
      campusLabel = picked.label;
    }

    final weekMatch = RegExp(r'ZDKXZC\s*=\s*(\d+)').firstMatch(html);
    final weekMax =
        weekMatch != null ? int.tryParse(weekMatch.group(1)!) ?? 19 : 19;

    return _PageContext(
      xnm: xnm,
      xqm: xqm,
      campusId: campusId,
      campusLabel: campusLabel.isEmpty ? '校区待确认' : campusLabel,
      weekMax: weekMax,
    );
  }

  static List<EmptyClassroomBuilding> parseBuildings(
    Map<String, dynamic> json,
    String html,
  ) {
    final dynamicList = (json['lhList'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => EmptyClassroomBuilding(
              value: '${e['JXLDM'] ?? ''}',
              label: '${e['JXLMC'] ?? ''}',
            ))
        .where((e) => e.value.isNotEmpty && e.label.isNotEmpty)
        .toList();

    final buildings = <EmptyClassroomBuilding>[
      const EmptyClassroomBuilding(value: '', label: '全部'),
    ];
    final seen = <String>{''};

    for (final b in dynamicList) {
      if (seen.add(b.value)) buildings.add(b);
    }

    // 动态接口偶发不全时，用真实页面 DOM 补齐；两条来源都来自已登录教务页面，
    // 不使用 assets/data/lab_rooms.json。不能只在 dynamicList 为空时才补，
    // 否则接口只回部分楼号时，页面 DOM 里的其它楼号会被静默丢掉。
    for (final b in parseHtmlBuildings(html)) {
      if (seen.add(b.value)) buildings.add(b);
    }
    return buildings;
  }

  /// 从真实页面 `#lh` select 解析 option value/label。
  static List<EmptyClassroomBuilding> parseHtmlBuildings(String html) {
    return _selectOptions(html, 'lh')
        .map((e) => EmptyClassroomBuilding(value: e.value, label: e.label))
        .where((e) => e.value.isNotEmpty && e.label.isNotEmpty)
        .toList();
  }

  static List<EmptyClassroomSection> parseSections(Map<String, dynamic> json) {
    final list = (json['jcList'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => EmptyClassroomSection(
              index: _parseInt(e['JCMC']),
              period: '${e['RSDMC'] ?? ''}',
              time: '${e['SJD'] ?? ''}',
            ))
        .where((e) => e.index > 0)
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    return list;
  }

  /// 周次/节次位掩码：选中第 n 项累加 2^(n-1)。
  static int maskOf(Iterable<int> values) {
    var mask = 0;
    for (final v in values) {
      if (v >= 1) mask += 1 << (v - 1);
    }
    return mask;
  }

  /// 星期多选：按教务口径用英文逗号拼接 value 列表。
  static String joinWeekdays(Iterable<int> values) {
    final list = values.toList()..sort();
    return list.join(',');
  }

  static void _sortRooms(List<EmptyClassroomRoom> rooms) {
    rooms.sort((a, b) {
      final byBuilding = a.buildingCode.compareTo(b.buildingCode);
      if (byBuilding != 0) return byBuilding;
      final byFloor = a.floor.compareTo(b.floor);
      if (byFloor != 0) return byFloor;
      return _naturalCompare(a.code, b.code);
    });
  }

  static int _naturalCompare(String a, String b) {
    final aParts =
        RegExp(r'\D+|\d+').allMatches(a).map((m) => m.group(0)!).toList();
    final bParts =
        RegExp(r'\D+|\d+').allMatches(b).map((m) => m.group(0)!).toList();
    final len = aParts.length < bParts.length ? aParts.length : bParts.length;
    for (var i = 0; i < len; i++) {
      final ai = int.tryParse(aParts[i]);
      final bi = int.tryParse(bParts[i]);
      final c = ai != null && bi != null
          ? ai.compareTo(bi)
          : aParts[i].compareTo(bParts[i]);
      if (c != 0) return c;
    }
    return aParts.length.compareTo(bParts.length);
  }

  static String _hiddenValue(String html, String name) {
    for (final tag
        in RegExp(r'<input\b[^>]*>', caseSensitive: false).allMatches(html)) {
      final attrs = tag.group(0)!;
      final attrName = _attrValue(attrs, 'name');
      final attrId = _attrValue(attrs, 'id');
      if (attrName == name || attrId == name) {
        return _attrValue(attrs, 'value')?.trim() ?? '';
      }
    }
    return '';
  }

  /// 读取一个 select 的 option，兼容 id 在任意属性位置、单/双引号、无引号。
  static List<({String value, String label, bool selected})> _selectOptions(
    String html,
    String id,
  ) {
    final selects = RegExp(r'<select\b[\s\S]*?</select>', caseSensitive: false)
        .allMatches(html);
    for (final select in selects) {
      final block = select.group(0)!;
      final openEnd = block.indexOf('>');
      if (openEnd < 0) continue;
      final openTag = block.substring(0, openEnd + 1);
      if (_attrValue(openTag, 'id') != id) continue;

      final body = block.substring(openEnd + 1);
      final options =
          RegExp(r'<option\b([^>]*)>([\s\S]*?)</option>', caseSensitive: false)
              .allMatches(body);
      final result = <({String value, String label, bool selected})>[];
      for (final option in options) {
        final attrs = option.group(1)!;
        final rawLabel = option
            .group(2)!
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .replaceAll('&nbsp;', ' ')
            .replaceAll('&amp;', '&')
            .trim();
        final value =
            (_attrValue(option.group(0)!, 'value') ?? rawLabel).trim();
        final selected =
            RegExp(r'\bselected\b', caseSensitive: false).hasMatch(attrs);
        result.add((value: value, label: rawLabel, selected: selected));
      }
      return result;
    }
    return const [];
  }

  static String? _attrValue(String tag, String name) {
    final pattern = RegExp(
      r'\b' +
          RegExp.escape(name) +
          r'''\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
      caseSensitive: false,
    );
    final m = pattern.firstMatch(tag);
    if (m == null) return null;
    return m.group(1) ?? m.group(2) ?? m.group(3);
  }
}

int _parseInt(Object? v, {int fallback = 0}) => switch (v) {
      int() => v,
      num() => v.toInt(),
      String() => int.tryParse(v.trim()) ?? fallback,
      _ => fallback,
    };

int? _parseNullableInt(Object? v) => switch (v) {
      int() => v,
      num() => v.toInt(),
      String() => int.tryParse(v.trim()),
      _ => null,
    };

class _PageContext {
  const _PageContext({
    required this.xnm,
    required this.xqm,
    required this.campusId,
    required this.campusLabel,
    required this.weekMax,
  });

  final String xnm;
  final String xqm;
  final String campusId;
  final String campusLabel;
  final int weekMax;
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
