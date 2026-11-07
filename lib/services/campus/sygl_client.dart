import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'campus_session.dart';
import 'cas_client.dart';

/// 实验课系统（`sygl.cwxu.edu.cn`）客户端。
///
/// ## 它到底怎么登录（2026-11-04 实测确认，别再来回猜）
///
/// 站点是 IIS + ASP.NET（asmx WebService），**确实接入了学校统一认证**，
/// 但入口不是首页 —— 首页 `customer/index/index.html` 是纯静态页，带不带
/// `?ticket=` 返回逐字节相同（我一开始就是被这一点误导，得出「不接 CAS」的
/// 错误结论）。
///
/// 真正的 CAS 客户端在 **`/caslogin.aspx`**：
/// - `GET /caslogin.aspx`（无 ticket）→ `302 Location:
///   https://wxcas.cwxu.edu.cn/lyuapServer/login?service=http://sygl.cwxu.edu.cn/caslogin.aspx`
/// - `GET /caslogin.aspx?ticket=ST-1-fake` → `200`，正文
///   `CAS returned to this application, but then refused to validate your identity.`
///   —— 它拿到 ticket 后真的去 `serviceValidate` 校验了，只是假 ticket 不通过。
///
/// 所以登录链路是标准 CAS：
/// `CasClient.login(service: serviceUrl)` 拿 TGT
/// → `CasClient.ssoTo(tgt, service: serviceUrl)` 让 CAS 给 ST 并访问
///   `caslogin.aspx?ticket=ST`
/// → ASP.NET 校验通过后下发 `ASP.NET_SessionId`
/// → 之后所有 asmx 都带这个 cookie。
///
/// ## 已知的坑（都实测过）
///
/// 1. **只能走 http**。`https://sygl.cwxu.edu.cn/` 直接连接超时（curl exit 28，
///    443 端口实测不通、80 通）。所以 Flutter 侧不能依赖 `CampusSession` 的默认
///    https 升级，见 `campus_session.dart` 的 `httpsOnlyExclusions`。
///    明文流量本身不用额外配置：`AndroidManifest.xml` 已有
///    `android:usesCleartextTraffic="true"`（v2.2.x 起为教务/门户保留）。
/// 2. **未登录时 asmx 给 401/500，不是 404**。`WebService.asmx/GetApparatusLab`
///    → `500 {"Message":"处理请求时出错。","StackTrace":"","ExceptionType":""}`、
///    `UserCenter.asmx/getUserMenu` → `401`、`labinfoWebService.asmx/GetLabDetail`
///    → `401`。方法**存在**，只是要会话。所以「401/500」不能当「接口不存在」。
/// 3. **所有 asmx 都要求 `Authorization: WanXinKey2019`**，除了
///    `labinfoWebService.asmx`（实测不带也能到 401 而不是 404）。这是站点自己的
///    约定，不是真正意义上的鉴权（值是公开的常量）。
/// 4. **请求体是「类 JSON 的 JS 字面量」而不是合法 JSON**：站点用
///    `"{kzJson:'" + x + "'}"` 这种拼法，键不带引号、值用单引号。服务端能接受，
///    但 `CampusSession.tryJson` 解析响应时要用 `d` 字段（ASMX 的老包裹格式）。
/// 5. **响应多为 gb2312/gb18030**。`CampusSession` 按 `Content-Type` 解码，
///    若站点没给 charset 就会按 UTF-8 解出乱码 —— 这里在解析前做一次兜底转换。
class SyglClient {
  SyglClient._();

  /// 站点根地址。**必须 http**（https 连不通）。
  static const String base = 'http://sygl.cwxu.edu.cn';

  /// CAS service 必须是这个精确地址，少一个字符 CAS 换票后对不上。
  static const String serviceUrl = '$base/caslogin.aspx';

  /// 站点公开的请求头常量（`Customer/js/*.js` 里硬编码）。
  static const String wanXinKey = 'WanXinKey2019';

  /// 上一次 [login] 里 `checklogin` 探测是否成功（仅用于自检与日志，不参与判定）。
  static bool _lastProbeOk = false;

  /// 上一次 [login] 里 `checklogin` 探测是否成功（仅自检/日志用）。
  static bool get lastProbeOk => _lastProbeOk;

  static String? _uiToken;

  /// 上一次 asmx 请求的 HTTP 状态码（0 = 连都没连上）。
  ///
  /// 2026-11-04（用户反馈「实验课无法导入」）：此前菜单拉不到时只能报
  /// 「可能是登录已过期」，而 401/404/500 三种情况在用户眼里完全一样。
  /// 站点语义是：**401 = 没会话**、**404 = 方法不存在**、**500 = 服务端异常**、
  /// **0 = 连不上（只能走 http，443 不通）**。把这几个数字摊出来，
  /// 用户和我都不用再猜。
  static int _lastStatus = 0;
  static int get lastStatus => _lastStatus;

  /// 用已保存的统一认证账号登录实验课系统。
  ///
  /// [session] 必须是一个**干净的** `CampusSession`：它会被写入 CAS 的
  /// cookie（TGT/CASTGC）和 sygl 的 `ASP.NET_SessionId`。
  ///
  /// 返回 null 表示成功，否则返回给用户看的错误文案。
  static Future<String?> login(
    CampusSession session,
    String username,
    String password,
  ) async {
    // 1) 走 CAS 拿 TGT。CAS 自身永远是 https，不受 sygl 的 http 限制。
    final res = await CasClient.login(
      session,
      username,
      password,
      service: serviceUrl,
    );
    if (res.status != CasClient.ok) {
      return res.note;
    }
    final tgt = res.tgt;
    if (tgt == null || tgt.isEmpty) {
      return '统一认证没有返回登录票据';
    }

    // 2) 用 TGT 换 ST 并访问 caslogin.aspx，让 ASP.NET 建立会话。
    final ok = await CasClient.ssoTo(session, tgt, service: serviceUrl);
    if (!ok) {
      return '统一认证已通过，但实验课系统拒绝了这次登录';
    }

    // 3) 尽力探一次 `checklogin`，但**不拿它当登录成败的判据**。
    //
    // 为什么：这个 asmx 端点从浏览器外调不通（未登录回 401、带 kzJson 的请求体
    // 被服务端回 404），可 CAS 票据已经换到了 ASP.NET 会话 —— 会话成不成，
    // 后面读菜单时自然会见分晓。若在这里把「探测失败」判成「登录失败」，
    // 整条链路会死在一步**本来就调不通**的健康检查上。
    // 所以这里只把探测结果记进 note，让 `fetchLabs` 的真实结果来决定。
    // 🔴 2026-11-04（用户反馈「实验课无法导入」）：
    //    浏览器走完 CAS 后**落地的是一个 HTML 页面**，ASP.NET 在那次响应里
    //    完成会话初始化并下发 `ASP.NET_SessionId`。我们只 `ssoTo` 到
    //    `caslogin.aspx`（那是个跳板，不建业务会话）就直接打 asmx ——
    //    会话没长出来，asmx 一律回 401。
    //    这里补上浏览器会做的那一步：先 GET 用户中心页，让站点把会话种下。
    //    页面拿不到也不阻断（可能只是模板路径变了），后面的探测会给出真实状态。
    await _getPage(session, '/Customer/MasterPage/UserCenterPage.html');
    await _getPage(session, '/');
    // 浏览器在 global.js 里先取 UIToken，再由 $.ajaxSetup 给后续请求带上。
    // 少了这个请求头，部分 ASMX 即使会话正确也会返回错误。
    await _ensureUiToken(session);

    final probe = await _post(
      session,
      'WebService.asmx',
      'checklogin',
      "{kzJson:''}",
    );
    _lastProbeOk = probe != null;
    return null;
  }

  /// 拉「我的实验课」。
  ///
  /// 返回 null 表示已登录但**没有找到实验课入口**（此时 [note] 里会写明为什么），
  /// 用来区分「没登录」和「登录了但站点结构变了」。
  static Future<SyglLabFetchResult> fetchLabs(CampusSession session) async {
    // ① 主路径：直接调用「我的课表」栏目背后的数据接口（2026-11-06 打通）。
    final direct = await _fetchRuleManage(session);
    if (direct.labs.isNotEmpty) return direct;

    // ② 兜底：旧的「菜单 → 栏目页 → HTML 表格」链路，只保留诊断价值。
    final legacy = await _fetchLabsByMenu(session);
    if (legacy.labs.isNotEmpty) return legacy;

    final notes =
        [direct.note, legacy.note].where((e) => e.isNotEmpty).toList();
    return SyglLabFetchResult(
      labs: const [],
      note: notes.isEmpty ? '没有抓到实验课数据' : notes.join('；'),
      menuDump: legacy.menuDump,
      needRelogin: legacy.needRelogin,
    );
  }

  // ─────────────── 实验课：直连数据接口（2026-11-06 主路径） ───────────────

  /// 「我的课表」栏目背后的数据接口。
  ///
  /// 🔴 为什么不再解析栏目页 HTML：栏目页只有一句
  ///    `<table id="ruleManage" class="layui-hide"></table>`（实测 3531 字节），
  ///    表头都没有；真实数据由同目录 `js/RuleManage.js` 的
  ///    `table.render({url:'../../WebService/Syjx.asmx/getRuleManage',
  ///    method:'post', page:'true', cols:[...]})` 异步拉。
  ///    从页面里找 `<a href>`、找 `data-json`、找 `url:` 全都是空集。
  ///
  /// 接口约定（实测）：
  /// - `POST /WebService/Syjx.asmx/getRuleManage`
  /// - 正文 **form-urlencoded** 的 `page=1&limit=200`（不是 `{kzJson:''}` 外壳，
  ///   也不是 JSON）。不带 `page`/`limit` 直接 500。
  /// - `limit` 必须 ≥ 100，写 30 只会回 30 条。
  /// - 响应是 XML 包 JSON：
  ///   `<string xmlns="http://tempuri.org/">{"code":0,...,"count":39,"data":[…]}</string>`
  static Future<SyglLabFetchResult> _fetchRuleManage(
    CampusSession session,
  ) async {
    await _ensureUiToken(session);

    final endpoint = await _discoverRuleManageEndpoint(session);
    if (endpoint == null) {
      return const SyglLabFetchResult(
        labs: [],
        note: '实验课表接口没找到（栏目 JS 与默认地址都不可用）',
      );
    }

    CampusResponse r;
    try {
      r = await session.postForm(
        '$base/${endpoint.path}',
        const {'page': '1', 'limit': '200'},
        headers: {
          'Authorization': wanXinKey,
          'X-Requested-With': 'XMLHttpRequest',
          'Referer': '$base/${endpoint.page}',
          if (_uiToken != null && _uiToken!.isNotEmpty) 'UIToken': _uiToken!,
        },
      );
    } catch (e) {
      return SyglLabFetchResult(
        labs: const [],
        note: '实验课表接口请求失败：$e',
      );
    }

    _lastStatus = r.statusCode;
    if (r.statusCode != 200) {
      return SyglLabFetchResult(
        labs: const [],
        note: '实验课表接口 HTTP ${r.statusCode}：${_statusHint(r.statusCode)}',
        needRelogin: r.statusCode == 401,
      );
    }

    final rows = _rowsFromAsmx(r.body);
    if (rows == null) {
      return SyglLabFetchResult(
        labs: const [],
        note: '实验课表接口返回的内容看不懂（不是 JSON，也不是 XML 包 JSON）',
      );
    }
    if (rows.isEmpty) {
      return const SyglLabFetchResult(
        labs: [],
        note: '本学期没有实验课排课记录',
      );
    }

    final labs = _labsFromRuleManageRows(rows);
    return SyglLabFetchResult(
      labs: labs,
      note: labs.isEmpty
          ? '实验课表有 ${rows.length} 条记录，但没有一条能解析出星期与节次'
          : '从实验课表接口取到 ${rows.length} 条排课，合并成 ${labs.length} 条课表记录',
      menuDump: 'Syjx.asmx/getRuleManage · ${endpoint.path}',
    );
  }

  /// 找 `getRuleManage` 的地址。
  ///
  /// 第一优先按**站点自身的目录约定**推导，而不是写死：
  /// 菜单 `lj` 写的是 `../../model/Syjx/RuleManage.html`，
  /// 页面脚本是 `js/RuleManage.js`，接口地址就写在这个 JS 的 `url:` 里。
  /// 站点哪天换了接口路径，读 JS 就自动跟着走。
  ///
  /// 推导不出来时退回实测可用的固定地址（保证今天就能用）。
  static Future<_RuleManageEndpoint?> _discoverRuleManageEndpoint(
    CampusSession session,
  ) async {
    const page = 'model/Syjx/RuleManage.html';
    // 页面与脚本同目录（`/model/Syjx/` 下的 `js/`）。
    final jsPath = page.replaceFirst(RegExp(r'[^/]+$'), 'js/RuleManage.js');
    final js = await _getPage(session, '/$jsPath');
    if (js != null && js.isNotEmpty) {
      final m = RegExp(
        r'''url\s*:\s*["']([^"']+)["']''',
      ).firstMatch(js);
      if (m != null) {
        var p = m.group(1)!.trim();
        // JS 里是相对栏目页的 `../../WebService/...`，归并掉点段。
        if (!p.startsWith('http')) {
          p = Uri.parse('$base/$page').resolve(p).toString();
          p = p.replaceFirst(RegExp('^https?://[^/]+/'), '');
        }
        if (p.contains('asmx')) {
          return _RuleManageEndpoint(p, page);
        }
      }
    }
    // 保底：实测 200 / 39 条的地址。
    return const _RuleManageEndpoint(
      'WebService/Syjx.asmx/getRuleManage',
      page,
    );
  }

  /// 把 asmx 的 XML 包 JSON 剥成行列表。
  ///
  /// 正常形态：`<?xml …?><string xmlns="http://tempuri.org/">{…}</string>`；
  /// 个别版本会直接返回裸 JSON，两种都认。
  @visibleForTesting
  static List<Map<String, Object?>>? rowsFromAsmxBody(String body) =>
      _rowsFromAsmx(body);

  /// 把一段 asmx 原始正文直接跑成实验课列表（离线回归用）。
  @visibleForTesting
  static List<SyglLab> labsFromRuleManageForTest(String asmxBody) {
    final rows = _rowsFromAsmx(asmxBody);
    if (rows == null) return const [];
    return _labsFromRuleManageRows(rows);
  }

  static List<Map<String, Object?>>? _rowsFromAsmx(String body) {
    var text = body.trim();
    if (text.isEmpty) return null;

    // ① 剥 XML 外壳（`<?xml …?><string xmlns="…">{…}</string>`）。
    //    没有外壳时原样当裸 JSON 处理 —— 个别版本会直接返回 JSON。
    final tagAt = text.indexOf('<string');
    if (tagAt >= 0) {
      final open = text.indexOf('>', tagAt);
      final close = text.lastIndexOf('</string>');
      if (open < 0 || close <= open) return null;
      text = text.substring(open + 1, close);
    } else {
      // 以 `<` 开头的多半是 XML 错误页，不是我们要的数据。
      if (text.startsWith('<')) return null;
    }
    text = _decodeXmlEntities(text.trim());

    Object? root;
    try {
      root = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (root is! Map) return null;
    final data = root['data'];
    if (data is! List) return null;
    return [
      for (final e in data)
        if (e is Map) e.map((k, v) => MapEntry('$k', v)),
    ];
  }

  /// asmx 把 JSON 塞进 XML 文本节点时会把 `& < > "` 转义。
  /// 实测这份数据里没有出现，但换了学期/课程名就可能出现，顺手解掉。
  static String _decodeXmlEntities(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');

  /// getRuleManage 的行 → `SyglLab`。
  ///
  /// 字段固定 9 个：
  ///   `ZC` 周次 / `BJMC` 班级 / `SKRQ` 日期 / `SKSJ` 节次(时间) /
  ///   `rs` 人数 / `KCMC` 实验课程(课程代码) / `XMMC` 实验项目 /
  ///   `ZJJS` 教师(工号) / `SYSMC` 实验室
  ///
  /// 一行 = 一次排课。同一门课同一天同一节会在多周出现（`ZC` 不同），
  /// 所以要先按「课程+星期+节次+地点+教师+时间」聚成一张课表格，
  /// 再把周次并起来。
  static List<SyglLab> _labsFromRuleManageRows(
    List<Map<String, Object?>> rows,
  ) {
    final groups = <String, _LabGroup>{};

    for (final row in rows) {
      String cell(String key) => '${row[key] ?? ''}'.trim();

      final rawName = cell('KCMC');
      if (rawName.isEmpty) continue;
      final name = _stripTrailingCode(rawName);
      if (name.isEmpty) continue;

      final slots = _slotsFromCell(cell('SKSJ'));
      final weekday = _weekdayFromDate(cell('SKRQ')) ?? 0;
      if (weekday < 1 || slots.$1 < 1) continue;

      final teacher = _stripTrailingCode(cell('ZJJS'));
      final place = cell('SYSMC');
      final time = _clockFromCell(cell('SKSJ'));
      final week = int.tryParse(cell('ZC')) ?? 0;

      final key = '$name|$weekday|${slots.$1}|${slots.$2}|$place|$teacher|$time';
      final g = groups.putIfAbsent(
        key,
        () => _LabGroup(
          name: name,
          weekday: weekday,
          startSlot: slots.$1,
          endSlot: slots.$2,
          place: place,
          teacher: teacher,
          time: time,
          code: _trailingCode(rawName),
        ),
      );
      if (week >= 1 && week <= 25) g.weeks.add(week);
    }

    final out = groups.values.toList()
      ..sort((a, b) {
        final byDay = a.weekday.compareTo(b.weekday);
        if (byDay != 0) return byDay;
        final bySlot = a.startSlot.compareTo(b.startSlot);
        if (bySlot != 0) return bySlot;
        return a.name.compareTo(b.name);
      });

    return [
      for (final g in out)
        SyglLab(
          name: g.name,
          code: g.code,
          place: g.place,
          teacher: g.teacher,
          time: g.time,
          weekday: g.weekday,
          startSlot: g.startSlot.clamp(1, 12),
          endSlot: (g.endSlot >= g.startSlot ? g.endSlot : g.startSlot)
              .clamp(1, 12),
          weeks: _formatWeeks(g.weeks),
          source: '我的课表',
        ),
    ];
  }

  /// 去掉结尾的 `(141306309)` / `(001310)` 这类代码。
  static String _stripTrailingCode(String raw) => raw
      .replaceFirst(RegExp(r'\s*[(（]\s*[0-9A-Za-z_-]+\s*[)）]\s*$'), '')
      .trim();

  /// 取出结尾括号里的代码。
  static String _trailingCode(String raw) {
    final m = RegExp(r'[(（]\s*([0-9A-Za-z_-]+)\s*[)）]\s*$').firstMatch(raw);
    return m?.group(1) ?? '';
  }

  /// 从 `7-11(15:55-21:20)` 里取括号中的钟点。
  static String _clockFromCell(String raw) {
    final m = RegExp(r'[(（]([^)）]+)[)）]').firstMatch(raw);
    return m?.group(1)?.trim() ?? '';
  }

  /// 周次集合 → `formatWeeks` 的文本形态（`1-3周,5-7周`）。
  static String _formatWeeks(Set<int> weeks) {
    if (weeks.isEmpty) return '';
    final sorted = weeks.toList()..sort();
    final parts = <String>[];
    var start = sorted.first;
    var prev = sorted.first;
    for (var i = 1; i < sorted.length; i++) {
      final w = sorted[i];
      if (w == prev + 1) {
        prev = w;
        continue;
      }
      parts.add(start == prev ? '$start周' : '$start-$prev周');
      start = w;
      prev = w;
    }
    parts.add(start == prev ? '$start周' : '$start-$prev周');
    return parts.join(',');
  }

  /// 旧链路（现降级为兜底）。保留是为了接口全挂时能给出可读的诊断。
  static Future<SyglLabFetchResult> _fetchLabsByMenu(
    CampusSession session,
  ) async {
    // 第一步：拿左侧菜单。这是唯一能动态发现「实验」栏目的入口。
    final menu = await _post(
      session,
      'UserCenter.asmx',
      'getUserMenu',
      "{kzJson:''}",
    );
    // 🔴 asmx 拿不到菜单时的兜底（2026-11-04）：
    //    `UserCenter.asmx/getUserMenu` 从浏览器外实测一律 404/401 —— 站点对
    //    非浏览器的 .NET asmx 请求有额外限制。但 CAS 落地的那张
    //    `UserCenterPage.html` 本身带着左侧菜单的 <a>，直接从 HTML 里挖，
    //    能挖到实验栏目就继续往下走，挖不到再报错。
    if (menu == null) {
      final page = await _getPage(
        session,
        '/Customer/MasterPage/UserCenterPage.html',
      );
      final linksFromHtml = page == null
          ? <_MenuLink>[]
          : _collectLabLinksFromHtml(_ensureUtf8(page));
      if (linksFromHtml.isEmpty) {
        return SyglLabFetchResult(
          labs: const [],
          note: '实验课系统没有返回菜单（菜单接口 HTTP $_lastStatus）：'
              '${_statusHint(_lastStatus)}'
              '${page == null ? '；用户中心页也打不开' : '；用户中心页里也没有实验栏目'}',
          needRelogin: _lastStatus == 401 || _lastStatus == 0,
        );
      }
      return _fetchFromLinks(session, linksFromHtml, menuDump: '');
    }

    final links = _collectLabLinks(menu);
    if (links.isEmpty) {
      return SyglLabFetchResult(
        labs: const [],
        note: '菜单里没有实验相关栏目（已扫描 ${_countMenuNodes(menu)} 个节点）',
        menuDump: _menuTitles(menu),
      );
    }

    return _fetchFromLinks(session, links, menuDump: _menuTitles(menu));
  }

  /// 逐个栏目页找实验课表格。两条入口（asmx 菜单 / HTML 兜底）共用。
  static Future<SyglLabFetchResult> _fetchFromLinks(
    CampusSession session,
    List<_MenuLink> links, {
    required String menuDump,
  }) async {
    final labs = <SyglLab>[];
    final notes = <String>[];
    for (final link in links) {
      final page = await _getPage(session, link.link);
      if (page == null) {
        notes.add('${link.name}：页面打不开');
        continue;
      }
      var parsed = _parseLabPage(page, link);
      if (parsed.isEmpty) {
        // 🔴 layui 异步壳（2026-11-06，用户 m26371「你应当测试出可以抓取到数据」）：
        //    静态 HTML 里往往只有表头，真实数据走 layui 的数据接口异步拉。
        //    所以解析不出时，从页面 <script> 里挖数据接口地址，调一次接口再解。
        parsed = await _fetchViaPageApi(session, page, link);
      }
      if (parsed.isEmpty) {
        notes.add('${link.name}：页面里没解析出实验课');
      } else {
        labs.addAll(parsed);
      }
    }
    return SyglLabFetchResult(
      labs: labs,
      note: notes.isEmpty ? '' : notes.join('；'),
      menuDump: menuDump,
    );
  }

  /// 从用户中心页的 HTML 里扫 `<a href>`，把像实验栏目的链接挖出来。
  ///
  /// 站点菜单是 layui 渲染的，但服务端模板里已经带了完整 `<a href="...">名称</a>`；
  /// 这里只认相对/绝对路径里含关键词的条目，避免抓到外链与锚点。
  static List<_MenuLink> _collectLabLinksFromHtml(String html) {
    final out = <_MenuLink>[];
    final seen = <String>{};
    for (final m in RegExp(
      r'''<a[^>]+href=["\x27]([^"\x27]+)["\x27][^>]*>(?:(?!</a>).)*?</a>''',
      dotAll: true,
    ).allMatches(html)) {
      final href = m.group(1)!.trim();
      if (href.isEmpty || href.startsWith('#') || href.startsWith('javascript:')) {
        continue;
      }
      final text = _plainText(m.group(0)!);
      if (!_looksLikeLab(text, href)) continue;
      if (!seen.add(href)) continue;
      out.add(_MenuLink(text.isEmpty ? '实验课' : text, href));
    }
    return out;
  }

  /// 把 asmx 的 HTTP 状态码翻译成一句人话。
  static String _statusHint(int code) {
    switch (code) {
      case 0:
        return '连不上站点。实验课系统只开 http（第 80 端口），https 不通。';
      case 401:
        return '站点认为没有登录会话 —— 统一认证过了，但实验课系统没接住，请重新登录一次。';
      case 403:
        return '站点拒绝了这次请求（可能限制了校园网访问）。';
      case 404:
        return '这个接口在站点上不存在，站点已改版。';
      case 500:
        return '站点自己出错了，不是本应用的问题，稍后再试。';
      default:
        return 'HTTP $code。';
    }
  }

  // ───────────────────────── 内部实现 ─────────────────────────

  static Future<void> _ensureUiToken(CampusSession session) async {
    if (_uiToken != null && _uiToken!.isNotEmpty) return;
    try {
      final r = await session.postRaw(
        '$base/WebService/WebService.asmx/GetUIToken',
        '',
        headers: const {
          'Content-Type': 'application/json',
          'X-Requested-With': 'XMLHttpRequest',
        },
      );
      if (r.statusCode != 200) return;
      final root = jsonDecode(r.body);
      final token = root is Map ? root['d'] : null;
      if (token is String && token.isNotEmpty) _uiToken = token;
    } catch (_) {
      // 老站点没有 UIToken 时仍可继续；不能把一个可选探测变成登录失败。
    }
  }

  /// POST 一个 asmx 方法，返回已解析的 `d` 字段（对象/数组），失败返回 null。
  static Future<Object?> _post(
    CampusSession session,
    String service,
    String method,
    String body,
  ) async {
    try {
      // 与真实页面的 $.ajax 一致：正文必须是原始 {kzJson:'…'} 外壳。
      // postJson 会 jsonEncode 一次，传字符串会变成 "{…}"（外层多一对引号），
      // 这正是上一版真机菜单接口 500 的协议差异。这里用原始正文。
      final r = await session.postRaw(
        '$base/WebService/$service/$method',
        body,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': wanXinKey,
          'X-Requested-With': 'XMLHttpRequest',
          'Referer': '$base/Customer/MasterPage/UserCenterPage.html',
          if (_uiToken != null && _uiToken!.isNotEmpty) 'UIToken': _uiToken!,
        },
      );
      _lastStatus = r.statusCode;
      if (r.statusCode != 200) return null;
      return _unwrapD(r.body);
    } catch (_) {
      _lastStatus = 0;
      return null;
    }
  }

  static Future<String?> _getPage(CampusSession session, String link) async {
    try {
      final url = link.startsWith('http')
          ? link
          : (link.startsWith('/') ? '$base$link' : '$base/$link');
      final r = await session.get(url, headers: {
        'Authorization': wanXinKey,
        'Referer': '$base/Customer/MasterPage/UserCenterPage.html',
      });
      if (!r.ok) return null;
      return r.body;
    } catch (_) {
      return null;
    }
  }

  /// 把 `"{kzJson:''}"` 这种外壳剥成值本身。
  ///
  /// 🔴 raw string 里写 \\s 得到的是「字面反斜杠 + s」，
  ///    永远匹配不到空白字符 —— 这里必须是单反斜杠。
  ///    （上一版写成双反斜杠，本函数恒返回空串，asmx 请求体永远为空。）
  @visibleForTesting
  static String stripBody(String body) {
    final m = RegExp(r"kzJson\s*:\s*'(.*)'\s*}").firstMatch(body);
    return m == null ? '' : m.group(1)!;
  }

  /// ASMX 的老包裹：`{"d":"<json 字符串>"}`。也有直接返回对象的写法。
  static Object? _unwrapD(String body) {
    final text = _ensureUtf8(body);
    Object? root;
    try {
      root = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (root is! Map) return root;
    final d = root['d'];
    if (d == null) return root;
    if (d is! String) return d;
    final s = d.trim();
    if (s.isEmpty) return null;
    try {
      return jsonDecode(s);
    } catch (_) {
      return s;
    }
  }

  /// 站点页面实测全是 UTF-8（`customer/index/index.html`、`model/Center/UserCenter.html`、
  /// `Customer/MasterPage/UserCenterPage.html` 三份都是 utf-8 解码成功、gb18030 失败）。
  /// 只有 IIS 的 404/500 错误页是 gb2312，而那些页面我们只用来判状态码、不解析内容。
  /// 所以这里只做一件轻量的事：把已经被错误解码出来的替换字符丢掉，不做整页转码。
  static String _ensureUtf8(String body) {
    if (!body.contains('�')) return body;
    return body.replaceAll('�', '');
  }

  /// 从菜单树里挑出「名字或链接像实验课」的节点。
  ///
  /// 站点菜单字段：`name`（显示名）、`lj`（链接）、`child`（子节点）、
  /// `mrlj`（默认栏目标记）、`JKDZ`（角标接口）。实验课在不同学期被管理员
  /// 挂在不同的父栏目下，所以只能按关键词扫。
  static List<_MenuLink> _collectLabLinks(Object? menu) {
    final out = <_MenuLink>[];
    final seen = <String>{};
    void walk(Object? node) {
      if (node is List) {
        for (final e in node) {
          walk(e);
        }
        return;
      }
      if (node is! Map) return;
      final name = '${node['name'] ?? node['LMMC'] ?? ''}'.trim();
      final link = '${node['lj'] ?? node['LJ'] ?? ''}'.trim();
      if (link.isNotEmpty && _looksLikeLab(name, link) && seen.add(link)) {
        out.add(_MenuLink(name.isEmpty ? '实验课' : name, link));
      }
      walk(node['child']);
      walk(node['menu']);
    }

    if (menu is Map) {
      walk(menu['menu'] ?? menu['data'] ?? menu);
    } else {
      walk(menu);
    }
    return out;
  }

  static bool _looksLikeLab(String name, String link) {
    const kw = ['实验', '实训', '排课', '课表', '预约', '实验课'];
    for (final k in kw) {
      if (name.contains(k) || link.contains(Uri.encodeComponent(k))) return true;
      if (link.contains(k)) return true;
    }
    return false;
  }

  static int _countMenuNodes(Object? menu) {
    var n = 0;
    void walk(Object? node) {
      if (node is List) {
        for (final e in node) {
          walk(e);
        }
        return;
      }
      if (node is! Map) return;
      n++;
      walk(node['child']);
      walk(node['menu']);
    }

    walk(menu is Map ? (menu['menu'] ?? menu) : menu);
    return n;
  }

  /// 菜单标题清单，给自检卡用（真机上第一次跑就能看到站点到底有什么栏目）。
  static String _menuTitles(Object? menu) {
    final titles = <String>[];
    void walk(Object? node) {
      if (node is List) {
        for (final e in node) {
          walk(e);
        }
        return;
      }
      if (node is! Map) return;
      final name = '${node['name'] ?? node['LMMC'] ?? ''}'.trim();
      if (name.isNotEmpty) titles.add(name);
      walk(node['child']);
    }

    walk(menu is Map ? (menu['menu'] ?? menu) : menu);
    // 🔴 必须用 '\n' 拼接：上层 `_showLabEmpty` 按 '\n' 切分后 take(12)，
    // 原来 join(' / ') 产出的是一整行，split 只能得到 1 个元素，
    // 40 个栏目名挤在一行里横向溢出，take(12) 形同虚设。
    return titles.take(40).join('\n');
  }

  /// 从栏目页的 <script> 里挖出 layui 的数据接口地址，逐个调一次，
  /// 把返回的 JSON 解成实验课。这是「异步壳」页面（静态只有表头）的兜底。
  static Future<List<SyglLab>> _fetchViaPageApi(
    CampusSession session,
    String pageHtml,
    _MenuLink link,
  ) async {
    final urls = <String>[];
    for (final m in RegExp(r'''url\s*:\s*["']([^"']+)["']''').allMatches(pageHtml)) {
      final u = m.group(1)!.trim();
      if (u.isEmpty) continue;
      // 只认本站 asmx / 数据方法，避免把 css/js 静态资源当接口打。
      if (!u.contains('.asmx') &&
          !(u.contains('Get') && (u.contains('Lab') || u.contains('List') || u.contains('Data')))) {
        continue;
      }
      if (!urls.contains(u)) urls.add(u);
    }
    for (final u in urls.take(3)) {
      // 站点是 .NET asmx，正文统一用 {kzJson:''} 外壳（与 _post 一致）。
      final lastSlash = u.lastIndexOf('/');
      if (lastSlash <= 0) continue;
      final method = u.substring(lastSlash + 1);
      final svcPath = u.substring(0, lastSlash);
      final svc = svcPath.substring(svcPath.lastIndexOf('/') + 1);
      final body = await _post(session, svc, method, "{kzJson:''}");
      if (body == null) continue;
      final labs = _labsFromJson(body, link.name);
      if (labs.isNotEmpty) return labs;
    }
    return const <SyglLab>[];
  }

  /// 从栏目页 HTML 里解析实验课条目。
  ///
  /// ⚠️ 这一层是**尽力而为**：站点用 layui 动态渲染，真实数据走 asmx，
  /// 页面里可能只有表头。所以遇到解析不出时返回空列表 + note，不抛异常，
  /// 让上层能把「菜单标题」展示给用户，便于下一次补规则。
  static List<SyglLab> _parseLabPage(String html, _MenuLink link) {
    final source = link.name;
    final text = _ensureUtf8(html);
    final out = <SyglLab>[];

    // 形态一：页面里内嵌了 JSON（layui table 的 data 属性）
    for (final m in RegExp(
      r'data-json=["\x27]([^"\x27]{20,})["\x27]',
    ).allMatches(text)) {
      try {
        final raw = m.group(1)!.replaceAll('&quot;', '"');
        final data = jsonDecode(raw);
        out.addAll(_labsFromJson(data, source));
      } catch (_) {
        // 不是合法 JSON 就跳过
      }
    }

    // 形态二：直接渲染好的表格行
    if (out.isEmpty) {
      out.addAll(_labsFromTable(text, source));
    }
    return out;
  }

  static List<SyglLab> _labsFromJson(Object? data, String source) {
    final out = <SyglLab>[];
    void walk(Object? node) {
      if (node is List) {
        for (final e in node) {
          walk(e);
        }
        return;
      }
      if (node is! Map) return;
      final lab = _labFromMap(node, source);
      if (lab != null) out.add(lab);
      for (final v in node.values) {
        if (v is List) walk(v);
      }
    }

    walk(data);
    return out;
  }

  @visibleForTesting
  static SyglLab? labFromJsonForTest(Map<String, Object?> node) =>
      _labFromMap(node, 'test');

  @visibleForTesting
  static List<SyglLab> labsFromTableForTest(String html) =>
      _labsFromTable(html, 'test');

  static SyglLab? _labFromMap(Map node, String source) {
    String pick(List<String> keys) {
      for (final k in keys) {
        final v = node[k];
        if (v != null && '$v'.trim().isNotEmpty) return '$v'.trim();
      }
      return '';
    }

    final name = pick(const [
      'SYSMC', 'sysmc', 'SYMC', 'KCMC', 'kcmc', 'NAME', 'name', '实验名称', '课程名称',
    ]);
    if (name.isEmpty) return null;
    final time = pick(const [
      'SJMC', 'sjmc', 'SKSJ', 'sksj', 'TIME', 'time', '时间', '上课时间', '节次', '排课时间',
    ]);
    final weekday = _weekdayOf(pick(const ['XQ', 'xq', 'WEEKDAY', 'weekday', '星期']));
    final startSlot = _slotOf(pick(const ['KJ', 'kj', 'STARTSLOT', 'startSlot', '开始节']));
    final endSlot = _slotOf(pick(const ['JJ', 'jj', 'ENDSLOT', 'endSlot', '结束节']));
    final schedule = _scheduleFromText(time);
    return SyglLab(
      name: name,
      code: pick(const ['SYSBH', 'sysbh', 'KCH', 'kch', 'CODE', 'code', '编号']),
      place: pick(const ['SYSDZ', 'sysdz', 'DZ', 'ADDRESS', '地点', '场地', '实验室']),
      teacher: pick(const ['JSXM', 'jsxm', 'TEACHER', 'teacher', '教师', '指导老师']),
      time: time,
      weekday: weekday == 0 ? schedule.weekday : weekday,
      startSlot: startSlot == 0 ? schedule.startSlot : startSlot,
      endSlot: endSlot == 0 ? schedule.endSlot : endSlot,
      weeks: pick(const ['ZC', 'zc', 'WEEKS', 'weeks', '周次']).isNotEmpty
          ? pick(const ['ZC', 'zc', 'WEEKS', 'weeks', '周次'])
          : schedule.weeks,
      source: source,
    );
  }

  static List<SyglLab> _labsFromTable(String html, String source) {
    final out = <SyglLab>[];
    // 逐行抽出单元格。保留空列：列位置有意义，丢一列就全错位。
    final rows = <List<String>>[];
    for (final rowMatch in RegExp('<tr[^>]*>(.*?)</tr>',
        dotAll: true, caseSensitive: false).allMatches(html)) {
      final cells = <String>[
        for (final c in RegExp('<(?:td|th)[^>]*>(.*?)</(?:td|th)>',
            dotAll: true, caseSensitive: false).allMatches(rowMatch.group(1)!))
          _plainText(c.group(1)!),
      ];
      if (cells.isNotEmpty) rows.add(cells);
    }

    // 表头驱动的列号：截图 m26006「我的课表」的真实列。
    int weekIdx = -1, dateIdx = -1, slotIdx = -1, nameIdx = -1,
        teacherIdx = -1, placeIdx = -1;
    for (final cells in rows) {
      final joined = cells.join('|');
      if (joined.contains('周次') && joined.contains('日期') &&
          (joined.contains('节次') || joined.contains('实验课程'))) {
        for (var i = 0; i < cells.length; i++) {
          final c = cells[i];
          if (c.contains('周次')) {
            weekIdx = i;
          } else if (c.contains('日期')) {
            dateIdx = i;
          } else if (c.contains('节次')) {
            slotIdx = i;
          } else if (c.contains('实验课程')) {
            nameIdx = i;
          } else if (c.contains('教师')) {
            teacherIdx = i;
          } else if (c.contains('实验室')) {
            placeIdx = i;
          }
        }
        break;
      }
    }
    // 表头没解析出来时按截图固定列序兜底：
    // 周次/班级/日期/节次时间/人数/实验课程/实验项目/教师/实验室
    if (nameIdx < 0 || slotIdx < 0) {
      weekIdx = 0;
      dateIdx = 2;
      slotIdx = 3;
      nameIdx = 5;
      teacherIdx = 7;
      placeIdx = 8;
    }

    String cell(List<String> cells, int idx) =>
        (idx >= 0 && idx < cells.length) ? cells[idx] : '';

    for (final cells in rows) {
      // 旧形态：单元格直接写了「星期三 第5-6节 3-8周」-> 沿用原解析。
      final legacyIdx = cells.indexWhere((c) =>
          RegExp('(星期|周)[一二三四五六日天1-7]').hasMatch(c) &&
          c.contains('节'));
      if (legacyIdx >= 0) {
        final time = cells[legacyIdx];
        final schedule = _scheduleFromText(time);
        final before = cells.take(legacyIdx).toList();
        final name = before.isEmpty ? cells.first : before.last;
        if (name.isEmpty || name.length > 80 ||
            _scheduleFromText(name).weekday > 0) {
          continue;
        }
        out.add(SyglLab(
          name: name,
          code: before.length > 1 ? before.first : '',
          place: cells.length > legacyIdx + 1 ? cells[legacyIdx + 1] : '',
          teacher: cells.length > legacyIdx + 2 ? cells[legacyIdx + 2] : '',
          time: time,
          weekday: schedule.weekday,
          startSlot: schedule.startSlot,
          endSlot: schedule.endSlot,
          weeks: schedule.weeks,
          source: source,
        ));
        continue;
      }

      // 新形态（截图 m26006）：星期由日期推、节次由「7-11(时钟)」推。
      final name = cell(cells, nameIdx);
      if (name.isEmpty || name.length > 80) {
        continue;
      }
      if (name.contains('实验课程') || name.contains('课程名称') ||
          name.contains('周次') || name.contains('节次')) {
        continue;
      }
      final weekday = _weekdayFromDate(cell(cells, dateIdx));
      final slots = _slotsFromCell(cell(cells, slotIdx));
      if (weekday == null || slots.$1 < 1) {
        continue;
      }
      out.add(SyglLab(
        name: name,
        place: cell(cells, placeIdx),
        teacher: cell(cells, teacherIdx),
        time: cell(cells, slotIdx),
        weekday: weekday,
        startSlot: slots.$1.clamp(1, 12).toInt(),
        endSlot: slots.$2.clamp(1, 12).toInt(),
        weeks: _weeksFromCell(cell(cells, weekIdx)),
        source: source,
      ));
    }
    return out;
  }

  /// 从「日期」列（yyyymmdd / yyyy-mm-dd）推星期几（1=周一 .. 7=周日）。
  static int? _weekdayFromDate(String raw) {
    final digits = raw.replaceAll(RegExp('[^0-9]'), '');
    if (digits.length < 8) return null;
    final y = int.tryParse(digits.substring(0, 4));
    final m = int.tryParse(digits.substring(4, 6));
    final d = int.tryParse(digits.substring(6, 8));
    if (y == null || m == null || d == null) return null;
    if (y < 2000 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31) {
      return null;
    }
    return DateTime(y, m, d).weekday;
  }

  /// 从「节次/时间」列取起止节：先去括号里的时钟，再取第一组「7-11」。
  static (int, int) _slotsFromCell(String raw) {
    var text = raw.replaceAll(RegExp('[(（][^)）]*[)）]'), '');
    text = text.replaceAll(RegExp('[0-9]{1,2}:[0-9]{2}'), '');
    final m = RegExp('([0-9]{1,2})[ ]*[-~—至][ ]*([0-9]{1,2})')
        .firstMatch(text);
    if (m != null) {
      return (
        int.tryParse(m.group(1)!) ?? 0,
        int.tryParse(m.group(2)!) ?? 0,
      );
    }
    final one = RegExp('[0-9]{1,2}').firstMatch(text);
    final a = one == null ? 0 : (int.tryParse(one.group(0)!) ?? 0);
    return (a, a);
  }

  /// 从「周次」列取单个教学周，写成 parseWeeks 认得的「N周」。
  static String _weeksFromCell(String raw) {
    final m = RegExp('[0-9]{1,2}').firstMatch(raw);
    if (m == null) return '';
    final w = int.tryParse(m.group(0)!) ?? 0;
    if (w < 1 || w > 25) return '';
    return '$w周';
  }

  static String _plainText(String html) => html
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();


  /// 从「星期二 第3-4节 1-16周」这类站点文本补全排课信息。
  /// 独立字段存在时仍优先使用独立字段；这里只负责常见的合并文本形态。
  static _LabScheduleText _scheduleFromText(String raw) {
    final text = raw.replaceAll('　', ' ').trim();
    if (text.isEmpty) return const _LabScheduleText();
    final weekday = _weekdayOf(text);
    final slot = RegExp(r'(?:第\s*)?(\d{1,2})(?:\s*[-~—至]\s*(\d{1,2}))?\s*节')
        .firstMatch(text);
    var start = 0;
    var end = 0;
    if (slot != null) {
      start = int.parse(slot.group(1)!);
      end = int.parse(slot.group(2) ?? slot.group(1)!);
      if (start < 1 || start > maxSlot || end < start || end > maxSlot) {
        start = 0;
        end = 0;
      }
    }
    final week = RegExp(r'(\d{1,2})(?:\s*[-~—至]\s*(\d{1,2}))?\s*周')
        .firstMatch(text);
    final weeks = week == null
        ? ''
        : '${week.group(1)}${week.group(2) == null ? '' : '-${week.group(2)}'}周';
    return _LabScheduleText(weekday, start, end, weeks);
  }

  static int _weekdayOf(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return 0;
    // '天' 是「星期天」的写法，站点两种都出现；只认 '日' 会让周日的实验课
    // 全部 weekday=0 被 hasSchedule 过滤掉，而且没有任何提示。
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    if (t.contains('星期') || t.contains('周')) {
      // 日/天都归星期天，不能按数组下标把「天」算成星期八。
      if (t.contains('日') || t.contains('天')) return 7;
      for (var i = 0; i < names.length - 1; i++) {
        // 先认中文星期，不能把「星期二 第3-4节」里的 3 当成星期三。
        if (t.contains(names[i])) return i + 1;
      }
      final m = RegExp(r'(?:星期|周)\s*([1-7])').firstMatch(t);
      if (m != null) return int.parse(m.group(1)!);
      return 0;
    }
    final m = RegExp(r'^[1-7]$').firstMatch(t);
    return m == null ? 0 : int.parse(m.group(0)!);
  }

  /// 节次上限。
  ///
  /// 本项目网格默认 12 节，但**确实有学校排到 13、14 节**（实验课尤其常见）。
  /// 原来写死 `1..12`，越界一律归 0 → 被 `hasSchedule` 静默过滤，
  /// 用户只觉得「这个实验没导进来」。这里放宽到 16 节，
  /// 超出网格范围的部分由 `Course.fromJson` 的 `clamp` 与网格的越界告警兜底。
  static const int maxSlot = 16;

  static int _slotOf(String raw) {
    final m = RegExp(r'\d+').firstMatch(raw);
    if (m == null) return 0;
    final v = int.parse(m.group(0)!);
    return (v >= 1 && v <= maxSlot) ? v : 0;
  }
}

class _LabScheduleText {
  const _LabScheduleText([this.weekday = 0, this.startSlot = 0, this.endSlot = 0, this.weeks = '']);
  final int weekday;
  final int startSlot;
  final int endSlot;
  final String weeks;
}

class _MenuLink {
  const _MenuLink(this.name, this.link);
  final String name;
  final String link;
}

/// `getRuleManage` 的调用地址（相对站点根）。
///
/// [path] 用来 POST，[page] 用来填 Referer —— 站点按 Referer 判来源，
/// 填成用户中心页也能通，但填栏目页更贴近真实请求。
class _RuleManageEndpoint {
  const _RuleManageEndpoint(this.path, this.page);
  final String path;
  final String page;
}

/// 聚合成一张「课表格」时的累加器。
class _LabGroup {
  _LabGroup({
    required this.name,
    required this.weekday,
    required this.startSlot,
    required this.endSlot,
    required this.place,
    required this.teacher,
    required this.time,
    required this.code,
  });

  final String name;
  final int weekday;
  final int startSlot;
  final int endSlot;
  final String place;
  final String teacher;
  final String time;
  final String code;
  final Set<int> weeks = <int>{};
}

/// 一条实验课安排。
class SyglLab {
  const SyglLab({
    required this.name,
    this.code = '',
    this.place = '',
    this.teacher = '',
    this.time = '',
    this.weekday = 0,
    this.startSlot = 0,
    this.endSlot = 0,
    this.weeks = '',
    this.source = '',
  });

  final String name;
  final String code;
  final String place;
  final String teacher;
  final String time;

  /// 0 表示站点没给 / 没解析出来。
  final int weekday;
  final int startSlot;
  final int endSlot;
  final String weeks;

  /// 来自哪个菜单栏目（自检用）。
  final String source;

  /// 结束节的安全值。
  ///
  /// 🔴 站点 JSON 里 `KJ`（开始节）有值而 `JJ`（结束节）缺省是**常见形态**，
  /// `_slotOf('')` 在这种情况下返回 0。原来 `hasSchedule` 只校验 `startSlot`，
  /// 于是这门课能通过过滤、能被算进「已添加 N 门实验课」，
  /// 但网格的 `_indexForSlot(blocks, 0, isEnd: true)` 恒返回 -1，
  /// 整门课被 `continue` 静默丢弃 —— 用户拿到成功提示、课表空白，
  /// 重启后 `Course.fromJson` 的 `clamp` 又把它夹成「只有 1 节高」冒出来，
  /// 而提醒服务只看 `startSlot`，所以还会收到一条点进去找不到课的提醒。
  ///
  /// 兜底策略：结束节不可用时按 1 节处理，绝不让整门课消失。
  int get safeEndSlot =>
      (endSlot >= startSlot && endSlot <= 12) ? endSlot : startSlot;

  bool get hasSchedule =>
      weekday >= 1 && weekday <= 7 && startSlot >= 1 && startSlot <= 12;
}

class SyglLabFetchResult {
  const SyglLabFetchResult({
    required this.labs,
    this.note = '',
    this.menuDump = '',
    this.needRelogin = false,
  });

  final List<SyglLab> labs;

  /// 给用户看的说明（解析了几条、哪一步没通）。
  final String note;

  /// 站点菜单标题，放在自检卡里方便下一次补规则。
  final String menuDump;

  final bool needRelogin;

  bool get isEmpty => labs.isEmpty;
}
