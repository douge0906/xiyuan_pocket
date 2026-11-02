import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/dorm_service.dart';
import 'package:xiyuan_pocket/services/net_mode.dart';

/// 验证 WebView 注入所需的两件事：网关 cookie 存在、充值地址已包装。
void main() {
  final sno = Platform.environment['XY_SNO'] ?? '';
  final pwd = Platform.environment['XY_PWD'] ?? '';

  test('网关 cookie 与充值地址', () async {
    if (sno.isEmpty) return;
    NetMode.notifier.value = CampusNetMode.webvpn;
    DormService.debugSno = sno;
    DormService.debugPwd = pwd;

    final err = await DormService.loginOrError();
    // ignore: avoid_print
    print('[登录] ${err ?? "成功"}');
    if (err != null) return;

    final cookies = DormService.vpnCookies;
    // ignore: avoid_print
    print('[网关cookie] ${cookies.length} 个：${cookies.keys.join(", ")}');
    expect(cookies.keys.any((k) => k.startsWith('wengine_vpn_ticket')), isTrue,
        reason: '缺少网关票据 cookie，WebView 无法免登录');

    final url = await DormService.rechargeUrlFor(448);
    // ignore: avoid_print
    print('[充值地址] ${url?.substring(0, 72)}…');
    expect(url, contains('webvpn.cwxu.edu.cn/http/'));

    DormService.clearToken();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
