import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'campus/jwgl_client.dart' show CampusException;
import 'dorm_bridge_stub.dart' if (dart.library.js_util) 'dorm_bridge_web.dart'
    as browser;
import 'dorm_web_client.dart';

/// Web 端的「浏览器内网桥接」—— 电费查询与充值的最后一块。
///
/// ### 为什么服务端代跑不行
/// 安卓端查电费是直连校内平台 `10.3.100.110`（`dart:io` + 校园网）。浏览器连不到
/// 内网，于是原本把整条链搬到控制端代跑。但 **WebVPN 网关按出口 IP 拦截**：
/// 服务器出口（上海电信 IDC）访问网关一律 `403 访问被拒绝`，而用户自己的浏览器
/// 出口正常。⇒ 内网这最后一段只能由**用户浏览器**去读。
///
/// ### 桥怎么搭
/// 1. 控制端用 CAS 的 TGT 现铸两张一次性票（网关票 `st_gw` + 平台票 `st_plat`），
///    连同「网关上的桥页路径」一起下发（`bridge-ticket` 端点）；
/// 2. 浏览器先顶层打开网关登录页换 cookie（`{gw}/login?cas_login=true&ticket=`）；
/// 3. 再让**同一个命名窗口**导航到桥页 —— 桥页虽是我们的代码，但**经网关加载**，
///    所以它的 origin 是 `https://webvpn.cwxu.edu.cn`，与内网平台同源，
///    页内的 `fetch` 天然带得上网关票据 cookie，没有跨域问题；
/// 4. 桥页跑完 CAS → 平台票 → oauth → `getThirdData`（或拼充值地址），把结果
///    `postMessage` 回本页。
///
/// ### 两条硬约束（都实测过，改了必炸）
/// - **必须两步**：网关票据 cookie 不存在时，网关**根本不代理**桥页（会把人带去
///   CAS 登录页），所以不能一步直达；
/// - **占位窗口必须在用户手势内同步打开**：Chrome 的弹窗拦截只看「手势还在不在」，
///   任何 `await` 之后再 `window.open` 都会被拦。所以本类每个入口的第一条语句
///   就是开窗。
///
/// ### 为什么用命名窗口而不是 iframe
/// 网关票据 cookie 的 `Set-Cookie` **没有 SameSite**（默认 `Lax`），
/// 第三方 iframe 里带不上 ⇒ 只能是顶层窗口。
class DormBridge {
  DormBridge._();

  /// 命名窗口名：后续导航都复用这一个窗口，不新开标签页。
  static const String windowName = 'xiyuan_bridge';

  /// 网关登录页换 cookie 后等多久再导航桥页。
  ///
  /// 实测 2500ms 稳定；1200ms 偶发「cookie 还没落盘就导航」→ 被弹回 CAS。
  static const Duration gatewaySettle = Duration(milliseconds: 2500);

  /// 一卡通预热页到充值页之间的缓冲（平台会话要先在浏览器里种上）。
  ///
  /// 实测 800ms 不够：预热页还在 302 换 cookie 时就被导航走，充值页会掉回
  /// 平台登录页。2500ms 稳定（与 [gatewaySettle] 同量级）。
  static const Duration warmupSettle = Duration(milliseconds: 2500);

  /// 桥页跑完整条链的上限（单测会改小）。
  @visibleForTesting
  static Duration resultTimeout = const Duration(seconds: 30);

  /// 浏览器拦截了开窗。
  static const String popupBlockedMessage = '浏览器拦截了新标签页，请允许本页弹出窗口后重试';

  /// 桥页超时。
  static const String timeoutMessage = '校园网网关响应超时，请重试';

  /// 兜底文案（桥页回了非预期结构）。
  static const String failureMessage = '电费查询失败，请稍后重试';

  /// 充值页地址没拿到时的兜底文案。
  static const String rechargeFailureMessage = '充值页准备失败，请稍后重试';

  /// 测试接缝：默认走真实浏览器窗口，单测注入假 driver。
  @visibleForTesting
  static BridgeDriver driver = const RealBridgeDriver();

  /// 用浏览器桥接查电费，返回桥页透传的 `getThirdData` 的 `map`。
  ///
  /// 参数口径与安卓端 `DormService._post(feeitemid, 'IEC', 3, {...})` 完全一致；
  /// [building] 必须是种子里的**完整值**（形如 `A5&李园壹號A5`），只传 `A5`
  /// 平台会回「无法获取房间信息」。
  static Future<Map<String, dynamic>> query({
    required String sessionId,
    required int feeitemid,
    required String campus,
    required String building,
    required String room,
  }) async {
    final payload = await _exchange(
      session: () async => sessionId,
      action: 'query',
      feeitemid: feeitemid,
      campus: campus,
      building: building,
      room: room,
    );
    final map = payload['map'];
    if (map is! Map) throw CampusException(failureMessage);
    return map.cast<String, dynamic>();
  }

  /// 打开电费 / 一卡通充值页（返回 null = 成功，非 null = 给用户看的原因）。
  ///
  /// 为什么地址也要桥页现拼：充值页 URL 里要带平台 `access_token`，而平台只有
  /// 浏览器进得去（服务端出口 IP 被网关 403）。桥页已经拿到 token，顺手把
  /// `/http/<hex(平台)>/charge-app?...&token=...` 这种网关包装地址拼出来即可。
  ///
  /// [session] 是「取会话 id」的回调 —— 它要发网络请求，所以必须是回调：
  /// 开窗（第一条语句）不能在等它之后。
  static Future<String?> openRecharge({
    required Future<String> Function() session,
    int? feeitemid,
    bool card = false,
  }) async {
    Map<String, dynamic> payload;
    try {
      payload = await _exchange(
        session: session,
        action: card ? 'card' : 'recharge',
        feeitemid: feeitemid,
        // 窗口要留给后面的充值页：这里不能关。
        keepWindow: true,
      );
    } on CampusException catch (e) {
      driver.close();
      return e.message;
    } catch (_) {
      driver.close();
      return rechargeFailureMessage;
    }

    final url = '${payload['url'] ?? ''}';
    final warmup = '${payload['warmup_url'] ?? ''}';
    if (url.isEmpty) {
      driver.close();
      return rechargeFailureMessage;
    }
    // 一卡通：先让平台把登录态种进浏览器，再进充值页。
    if (warmup.isNotEmpty) {
      if (!driver.open(warmup)) {
        driver.close();
        return popupBlockedMessage;
      }
      await driver.wait(warmupSettle);
    }
    if (!driver.open(url)) {
      driver.close();
      return popupBlockedMessage;
    }
    // 成功：窗口停在充值页，不关。
    return null;
  }

  /// 走一遍「占位窗 → 铸票 → 网关登录 → 桥页 → 等回执」。
  ///
  /// [action] 交给桥页分派：`query`（电费查询）/ `recharge`（电费充值地址）/
  /// `card`（一卡通充值地址）。
  static Future<Map<String, dynamic>> _exchange({
    required Future<String> Function() session,
    required String action,
    int? feeitemid,
    String campus = '',
    String building = '',
    String room = '',
    bool keepWindow = false,
  }) async {
    // ① 占位窗：必须在用户手势内**同步**打开，抢在任何 await 之前。
    if (!driver.open('about:blank')) {
      throw CampusException(popupBlockedMessage);
    }
    var closed = false;
    void closeOnce() {
      if (closed) return;
      closed = true;
      driver.close();
    }

    void Function()? cancel;
    try {
      // ② 现铸一次性票（每次都要铸，票是一次性的）。
      final sid = await session();
      final ticket = await DormWebClient.bridgeTicket(sid);

      // ③ 网关登录页：拿到浏览器自己的网关票据 cookie。
      if (!driver.open(
        '${ticket.gatewayOrigin}/login?cas_login=true'
        '&ticket=${Uri.encodeQueryComponent(ticket.stGw)}',
      )) {
        throw CampusException(popupBlockedMessage);
      }
      await driver.wait(gatewaySettle);

      // ④ 先挂监听再导航，避免桥页太快回执时漏掉消息。
      final completer = Completer<Map<String, dynamic>>();
      cancel = driver.listen(ticket.gatewayOrigin, (data) {
        if (completer.isCompleted) return;
        // 桥页的固定标记（`app/dorm_proxy.py` 的 `finish()` 对拍）。
        if ('${data['source'] ?? ''}' != 'xiyuan-bridge') return;
        if ('${data['type'] ?? ''}' != 'dorm-result') return;
        final payload = data['payload'];
        if (payload is! Map) {
          completer.completeError(CampusException(failureMessage));
          return;
        }
        final body = payload.map((k, v) => MapEntry(k.toString(), v));
        if (body['ok'] != true) {
          final error = '${body['error'] ?? ''}';
          completer.completeError(
            CampusException(error.isEmpty ? failureMessage : error),
          );
          return;
        }
        completer.complete(body);
      });

      // ⑤ 同名窗口导航到桥页（参数全在 fragment：票据不进 query、不进访问日志）。
      final fragment = _fragment(
        ticket: ticket,
        action: action,
        feeitemid: feeitemid,
        campus: campus,
        building: building,
        room: room,
      );
      if (!driver.open('${ticket.gatewayOrigin}${ticket.bridgePath}#$fragment')) {
        throw CampusException(popupBlockedMessage);
      }

      final payload = await completer.future.timeout(
        resultTimeout,
        onTimeout: () => throw CampusException(timeoutMessage),
      );
      if (keepWindow) closed = true;
      return payload;
    } finally {
      cancel?.call();
      closeOnce();
    }
  }

  /// 拼 fragment：`action` / `st_plat` / `hex` / 查询参数。
  ///
  /// `st_gw2` 是「备用网关票」：桥页若发现被弹回登录页，会用它自举一次再重试。
  /// 服务端一次只铸一张网关票，这里把同一张传过去（票一次性，但自举只在
  /// 「第一次没用过」时才有意义 —— 留着不增加成本）。
  static String _fragment({
    required BridgeTicket ticket,
    required String action,
    int? feeitemid,
    String campus = '',
    String building = '',
    String room = '',
  }) {
    final pairs = <String, String>{
      'action': action,
      'st_gw2': ticket.stGw,
      'st_plat': ticket.stPlat,
      'hex': ticket.hexPlat,
    };
    if (feeitemid != null) pairs['feeitemid'] = '$feeitemid';
    if (campus.isNotEmpty) pairs['campus'] = campus;
    if (building.isNotEmpty) pairs['building'] = building;
    if (room.isNotEmpty) pairs['room'] = room;
    return pairs.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  }
}

/// 浏览器动作接缝（单测注入假实现，生产走 [RealBridgeDriver]）。
abstract class BridgeDriver {
  const BridgeDriver();

  /// 打开（或复用）命名窗口；false = 被弹窗拦截。
  bool open(String url);

  /// 监听指定 origin 的 `postMessage`，返回取消监听的函数。
  void Function() listen(
    String origin,
    void Function(Map<String, dynamic> data) onMessage,
  );

  /// 关掉刚才那个窗口（没开过就什么都不做）。
  void close();

  /// 等待（单测里恒立即返回）。
  Future<void> wait(Duration duration);
}

/// 真实浏览器实现。
///
/// 具体动作在 `dorm_bridge_web.dart`（`dart:html` + `dart:js_util`），
/// 非 Web 环境是 `dorm_bridge_stub.dart`（一调就抛，永远走不到这里）。
class RealBridgeDriver extends BridgeDriver {
  const RealBridgeDriver();

  @override
  bool open(String url) => browser.openBridgeWindow(url, DormBridge.windowName);

  @override
  void Function() listen(
    String origin,
    void Function(Map<String, dynamic> data) onMessage,
  ) =>
      browser.listenBridgeMessages(origin, onMessage);

  @override
  void close() => browser.closeBridgeWindow(DormBridge.windowName);

  @override
  Future<void> wait(Duration duration) => Future<void>.delayed(duration);
}
