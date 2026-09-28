import 'dart:convert';

import 'campus_session.dart';
import 'cas_client.dart';
import 'jwgl_client.dart' show CampusException;

/// 无锡学院融合门户「一卡通余额」—— 客户端直连。
///
/// 与 `server/card_balance.py` 逻辑一一对应（便于两边对拍排查）。
///
/// 链路：
///   1. CAS 统一认证登录（与教务同一个 CAS，service = 门户 shiro-cas）
///   2. TGT 换 ST 后访问 `/shiro-cas?ticket=ST-xxx` 建立门户会话
///   3. 动态定位承载余额的「学生个人信息」卡片（卡片 id 是学校后台配置，
///      故按**卡片名**匹配，不硬编码）
///   4. `queryAppointCard/{cardId}` 的 `data.data` 是 **JSON 字符串**，
///      其中 `YE` 字段即一卡通余额（元）
///
/// 隐私：账号密码只用于向**学校 CAS** 认证，不落盘、不发往第三方。
class CardBalanceClient {
  static const String portalBase = CasClient.portalBase;
  static const String portalService = CasClient.portalService;

  /// 承载一卡通余额的卡片名关键词（学校后台配置）
  static const List<String> _cardKeywords = ['个人信息'];

  /// 门户接口需要的自定义 header
  static const Map<String, String> _apiHeaders = {
    'Referer': '$portalBase/',
    'X-Requested-With': 'XMLHttpRequest',
    'Accept': 'application/json, text/plain, */*',
    'gatewayAppId': 'ly-upp',
  };

  /// 建立门户会话（失败抛 [CampusException]）。
  ///
  /// ⚠️ **换票后的那次跳转必须不跟随**：建立会话所需的
  ///   `customsid` / `Authorization` cookie 在 302 响应里就已下发，
  ///   那个跳转对我们毫无用处（且它指向 80 端口，部分网络下不可达）。
  static Future<void> loginPortal(
      CampusSession session, String username, String password) async {
    final res = await CasClient.login(session, username, password,
        service: portalService);
    if (!res.ok) {
      throw CampusException(res.note,
          needRelogin: res.status == CasClient.badCredential);
    }
    final tgt = res.tgt;
    if (tgt == null) {
      throw CampusException('CAS 登录未返回 TGT', needRelogin: true);
    }

    // TGT → ST
    final rSt = await session.postForm(
      '${CasClient.casBase}/lyuapServer/v1/tickets/$tgt',
      {'service': portalService},
      headers: {'Referer': '${CasClient.casBase}/'},
    );
    var st = rSt.body.trim();
    final j = CampusSession.tryJson(st);
    if (j != null && j['ticket'] is String) st = j['ticket'] as String;
    if (st.isEmpty) {
      throw CampusException('门户取票失败', needRelogin: true);
    }

    // 建立门户会话（不跟随跳转）
    await session.get(
      '$portalService?ticket=$st',
      headers: {'Referer': '${CasClient.casBase}/'},
      followRedirects: false,
    );

    if ((session.cookies['customsid'] ?? '').isEmpty) {
      throw CampusException('门户会话建立失败（未拿到 customsid）',
          needRelogin: true);
    }
  }

  /// 调用门户接口（回复 JSON；解析失败返回空 Map）
  static Future<Map<String, dynamic>> _api(
    CampusSession session,
    String path, {
    Map<String, String>? params,
  }) async {
    final uri = Uri.parse('$portalBase$path');
    final q = (params == null || params.isEmpty)
        ? uri
        : uri.replace(queryParameters: params);
    final r = await session.get(q.toString(), headers: _apiHeaders);
    final j = CampusSession.tryJson(r.body);
    if (j == null) throw CampusException('门户返回的不是 JSON');
    return j;
  }

  /// 动态定位「学生个人信息」卡片 id（找不到返回 null）
  static Future<String?> _findPersonalCardId(CampusSession session) async {
    String? siteId;
    try {
      final data = (await _api(session, '/api/upp/site/queryUserSiteList'))['data'];
      if (data is List && data.isNotEmpty) {
        siteId = (data.first as Map)['siteId']?.toString();
      } else if (data is Map) {
        siteId = data['siteId']?.toString();
      }
    } catch (_) {
      // 忽略：下面统一按 siteId 为空处理
    }
    if (siteId == null || siteId.isEmpty) return null;

    List<dynamic> pages;
    try {
      final d = (await _api(session, '/api/upp/pages/getPage',
          params: {'siteId': siteId}))['data'];
      pages = d is List ? d : const [];
    } catch (_) {
      return null;
    }

    // 学生首页优先，找不到再依次尝试其它页面
    final ordered = <dynamic>[];
    ordered.addAll(pages.where((p) => (p as Map)['pagePath'] == 'studentNewPage'));
    ordered.addAll(pages.where((p) => (p as Map)['pagePath'] != 'studentNewPage'));

    for (final page in ordered) {
      final pageId = (page as Map)['pageId']?.toString();
      if (pageId == null || pageId.isEmpty) continue;
      Map<String, dynamic> pageData;
      try {
        final d = (await _api(session, '/api/upp/layout/getPageContent',
            params: {'pageId': pageId}))['data'];
        pageData = d is Map ? d.cast<String, dynamic>() : const {};
      } catch (_) {
        continue;
      }
      final content = pageData['pageContent'];
      final comps = (content is Map ? content['component'] : null);
      if (comps is! List) continue;
      for (final comp in comps) {
        final areas = (comp is Map ? comp['componentArea'] : null);
        if (areas is! List) continue;
        for (final area in areas) {
          if (area is! Map) continue;
          final props = area['cardProps'];
          final name = (props is Map ? props['cardName'] : null)?.toString() ?? '';
          if (_cardKeywords.any((kw) => name.contains(kw))) {
            final cid = (props is Map ? props['cardId'] : null)?.toString();
            return (cid != null && cid.isNotEmpty)
                ? cid
                : area['id']?.toString();
          }
        }
      }
    }
    return null;
  }

  /// 取卡片数据行（响应里的 `data.data` 是 JSON 字符串）
  static Future<Map<String, dynamic>> _fetchCardRow(
      CampusSession session, String cardId) async {
    final payload = await _api(
        session, '/api/upp/contentDisplay/queryAppointCard/$cardId');
    var inner = (payload['data'] is Map)
        ? (payload['data'] as Map)['data']
        : null;
    if (inner is String) {
      try {
        inner = jsonDecode(inner);
      } catch (_) {
        inner = null;
      }
    }
    if (inner is List && inner.isNotEmpty) {
      final first = inner.first;
      if (first is Map) return first.cast<String, dynamic>();
    }
    return const {};
  }

  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    final d = v is num ? v.toDouble() : double.tryParse(v.toString());
    if (d == null) return null;
    return (d * 100).roundToDouble() / 100;
  }

  /// 整理成客户端需要的结构（不返回邮箱 authkey 等敏感字段）
  static Map<String, dynamic> _parseBalance(Map<String, dynamic> row) => {
        'balance': _toDouble(row['YE']), // 一卡通余额（元）
        'account_balance': _toDouble(row['ZHYE']), // 账户余额
        'jye': _toDouble(row['JYE']),
        'ssye': _toDouble(row['SSYE']),
        'book_count': row['SL'], // 借阅数量（可为「暂无」）
        'mail_unread': row['mailNewCount'],
      };

  /// 对外入口：登录门户并取一卡通余额。失败抛 [CampusException]。
  ///
  /// 外层再包一层 `data` 由调用方处理。
  static Future<Map<String, dynamic>> fetch(
      CampusSession session, String username, String password) async {
    await loginPortal(session, username, password);

    final cardId = await _findPersonalCardId(session);
    if (cardId == null || cardId.isEmpty) {
      throw CampusException('未在门户找到个人信息卡片配置');
    }

    final row = await _fetchCardRow(session, cardId);
    if (row.isEmpty) {
      throw CampusException('门户未返回一卡通数据');
    }
    return _parseBalance(row);
  }
}