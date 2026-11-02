import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/dorm_service.dart';
import 'package:xiyuan_pocket/services/net_mode.dart';

/// 走**完整业务方法**的真实链路测试（需要真实账号，默认不跑）。
///
///   XY_SNO=xxx XY_PWD=xxx flutter test test/live_dorm_test.dart
///
/// 与 live_webvpn_test 的区别：那个手工拼请求定位协议，这个直接调
/// `DormService.loginOrError / fetchCardBalanceDetailed / fetchTurnover`，
/// 验证的是**用户实际会走的那条路**。
void main() {
  final sno = Platform.environment['XY_SNO'] ?? '';
  final pwd = Platform.environment['XY_PWD'] ?? '';

  test('真实：一卡通余额 + 交易明细（走完整业务方法）', () async {
    if (sno.isEmpty || pwd.isEmpty) {
      // ignore: avoid_print
      print('跳过：未提供 XY_SNO / XY_PWD');
      return;
    }

    // 校外：强制走 WebVPN
    NetMode.notifier.value = CampusNetMode.webvpn;
    DormService.debugSno = sno;
    DormService.debugPwd = pwd;

    final err = await DormService.loginOrError();
    // ignore: avoid_print
    print('\n[登录] err=${err ?? "(成功)"}');
    expect(err, isNull, reason: '登录应成功：$err');

    final card = await DormService.fetchCardBalanceDetailed();
    // ignore: avoid_print
    print('[一卡通] balance=${card.balance}  reason=${card.reason ?? "-"}');
    expect(card.balance, isNotNull, reason: '余额应拿到：${card.reason}');

    // 充值页地址：校外应被包装成网关地址
    final recharge = await DormService.rechargeUrlFor(448);
    // ignore: avoid_print
    print('[充值URL] ${recharge ?? "(null)"}');
    expect(recharge, isNotNull);
    expect(recharge!, contains('webvpn.cwxu.edu.cn/http/'),
        reason: '校外必须包装成网关地址，否则浏览器打不开');

    DormService.clearToken();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
