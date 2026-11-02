import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/campus/campus_session.dart';
import 'package:xiyuan_pocket/services/campus/cas_client.dart';
import 'package:xiyuan_pocket/services/campus/webvpn.dart';
import 'package:xiyuan_pocket/services/dorm_service.dart';

/// 真实链路联通测试（**需要真实账号**，默认不跑）。
///
/// 用法（账号只走环境变量，不落盘）：
///   XY_SNO=xxx XY_PWD=xxx flutter test test/live_webvpn_test.dart
///
/// 目的：把「CAS → WebVPN → 平台换票 → oauth → 查卡」整条链跑一遍并打印每一步，
/// 定位到底卡在哪一环，而不是靠界面猜。
const _basic =
    'Basic bW9iaWxlX3NlcnZpY2VfcGxhdGZvcm06bW9iaWxlX3NlcnZpY2VfcGxhdGZvcm1fc2VjcmV0';

String cut(String s, [int n = 160]) =>
    s.length <= n ? s : '${s.substring(0, n)}…';

void main() {
  final sno = Platform.environment['XY_SNO'] ?? '';
  final pwd = Platform.environment['XY_PWD'] ?? '';

  test('真实链路：CAS → WebVPN → 换票 → oauth → 查卡', () async {
    if (sno.isEmpty || pwd.isEmpty) {
      // ignore: avoid_print
      print('跳过：未提供 XY_SNO / XY_PWD');
      return;
    }

    final s = CampusSession(
      urlRewrite: WebVpn.wrapUrl, // 校外：所有内网请求走网关
      timeout: const Duration(seconds: 20),
    );

    try {
      // ---------- 1. CAS 登录 ----------
      // ignore: avoid_print
      print('\n=== 1. CAS 登录 ===');
      final login = await CasClient.login(s, sno, pwd,
          service: DormService.casService);
      // ignore: avoid_print
      print('ok=${login.ok}  note=${login.note}  tgt=${cut(login.tgt ?? '-', 24)}');
      if (!login.ok || login.tgt == null) return;

      // ---------- 2. WebVPN 登录 ----------
      // ignore: avoid_print
      print('\n=== 2. WebVPN 登录 ===');
      final vpnErr = await WebVpn.login(s, login.tgt!);
      // ignore: avoid_print
      print('vpnErr=${vpnErr ?? "(null = 成功)"}');
      // ignore: avoid_print
      print('cookie keys=${s.cookies.keys.join(",")}');

      // ---------- 3. CAS 换 ST ----------
      // ignore: avoid_print
      print('\n=== 3. CAS 换 ST ===');
      final stResp = await s.postForm(
        '${CasClient.casBase}/lyuapServer/v1/tickets/${login.tgt}',
        {'service': DormService.casService},
        headers: {'Referer': '${CasClient.casBase}/'},
      );
      final st = stResp.body.trim();
      // ignore: avoid_print
      print('st=${cut(st, 30)}  (${stResp.statusCode})');
      if (!st.startsWith('ST-')) return;

      // ---------- 4. 平台票（关键一步） ----------
      // ignore: avoid_print
      print('\n=== 4. 平台票 ===');
      final start =
          '${DormService.casService}&ticket=${Uri.encodeComponent(st)}';
      final platformTicket =
          await DormService.locatePlatformTicket(s, start);
      // ignore: avoid_print
      print('platformTicket=${platformTicket.isEmpty ? "(空 → 会退回 ST)" : platformTicket}');
      final ticketForToken =
          platformTicket.isEmpty ? st : platformTicket;

      // ---------- 5. oauth token ----------
      // ignore: avoid_print
      print('\n=== 5. oauth token ===');
      final tokenResp = await s.postForm(
        '${DormService.base}/berserker-auth/oauth/token',
        {
          'username': ticketForToken,
          'password': ticketForToken,
          'grant_type': 'password',
          'scope': 'all',
          'loginFrom': 'app',
          'logintype': 'sso',
          'device_token': 'h5',
        },
        headers: {'Authorization': _basic},
      );
      // ignore: avoid_print
      print('body=${cut(tokenResp.body, 240)}');
      final tj = CampusSession.tryJson(tokenResp.body);
      final token = tj?['access_token']?.toString() ?? '';
      if (token.isEmpty) return;

      // ---------- 6. 用户信息（找卡号） ----------
      // ignore: avoid_print
      print('\n=== 6. berserker-base/user ===');
      // 对照实验：synAccessSource=app + 双份携带（query + 头）
      final ur = await s.get(
        '${DormService.base}/berserker-base/user?synAccessSource=app',
        headers: {
          'synjones-auth': 'bearer $token',
          'synAccessSource': 'app',
        },
      );
      // ignore: avoid_print
      print('status=${ur.statusCode}  body=${cut(ur.body, 600)}');

      // ---------- 7. 查卡 ----------
      // ignore: avoid_print
      print('\n=== 7. 直接从 user 响应里找卡号并查卡 ===');
      final uj = CampusSession.tryJson(ur.body);
      if (uj == null) return;
      final m = RegExp(r'"cardAccount"\s*:\s*"?(\d+)"?')
          .firstMatch(ur.body);
      final account = m?.group(1) ?? '';
      // ignore: avoid_print
      print('regex cardAccount=$account');
      if (account.isEmpty) return;
      final cr = await s.get(
        '${DormService.base}/berserker-app/ykt/tsm/queryCard'
        '?account=$account&synAccessSource=app',
        headers: {
          'synjones-auth': 'bearer $token',
          'synAccessSource': 'h5',
        },
      );
      // ignore: avoid_print
      print('查卡 status=${cr.statusCode}  body=${cut(cr.body, 600)}');
    } finally {
      s.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
