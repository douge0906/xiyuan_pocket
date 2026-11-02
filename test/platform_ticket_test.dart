import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/campus/campus_session.dart';
import 'package:xiyuan_pocket/services/dorm_service.dart';

/// 平台票定位的**本地桩测试**（不依赖真实账号，也不依赖校园网/网关）。
///
/// 背景：平台票只出现在 `lyCas → /plat/?ticket=…` 这一跳的 URL 上。
/// 走 WebVPN 时网关会多跳一次、最终落点是门户首页，若只看最终 URL 就会取空，
/// 退回用 ST 换 token → 低权限 token → 一卡通「4030 服务大厅未授权1」。
/// 这里用本地 HttpServer 复刻两种链路，断言取票成功。
void main() {
  late HttpServer server;
  late String base;

  Future<void> startServer(List<String> script) async {
    server = await HttpServer.bind('127.0.0.1', 0);
    var i = 0;
    server.listen((req) async {
      final step = i < script.length ? script[i] : 'end';
      i++;
      if (step == 'home') {
        req.response.statusCode = 200;
        req.response.write('<html>home</html>');
      } else {
        req.response.statusCode = 302;
        req.response.headers.set('location', step);
      }
      await req.response.close();
    });
    base = 'http://127.0.0.1:${server.port}';
  }

  tearDown(() async {
    try {
      await server.close(force: true);
    } catch (_) {}
  });

  test('① 票在第二跳的 Location 上（直连形态）', () async {
    await startServer(['/plat/?ticket=PLAT-123', 'home']);
    final s = CampusSession(timeout: const Duration(seconds: 5));
    final ticket = await DormService.locatePlatformTicket(
      s,
      '$base/berserker-auth/cas/login/lyCas?ticket=ST-abc',
    );
    s.close();
    expect(ticket, 'PLAT-123');
  });

  test('② 网关多跳一次：中间还有一跳不含票，仍能取到', () async {
    await startServer(['/wengine-vpn-token-login?token=X', '/plat/?ticket=PLAT-456', 'home']);
    final s = CampusSession(timeout: const Duration(seconds: 5));
    final ticket = await DormService.locatePlatformTicket(
      s,
      '$base/berserker-auth/cas/login/lyCas?ticket=ST-abc',
    );
    s.close();
    expect(ticket, 'PLAT-456');
  });

  test('③ 链上完全没有平台票 → 返回空（调用方会退回 ST）', () async {
    await startServer(['/plat/?name=loginTransit', 'home']);
    final s = CampusSession(timeout: const Duration(seconds: 5));
    final ticket = await DormService.locatePlatformTicket(
      s,
      '$base/berserker-auth/cas/login/lyCas?ticket=ST-abc',
    );
    s.close();
    expect(ticket, '');
  });

  test('④ 起始 URL 自带 ST 时不会被误当成平台票', () async {
    await startServer(['/plat/?ticket=PLAT-789', 'home']);
    final s = CampusSession(timeout: const Duration(seconds: 5));
    final ticket = await DormService.locatePlatformTicket(
      s,
      '$base/lyCas?ticket=ST-should-be-ignored',
    );
    s.close();
    expect(ticket, 'PLAT-789');
  });
}
