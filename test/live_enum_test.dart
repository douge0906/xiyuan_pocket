import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/campus/campus_session.dart';
import 'package:xiyuan_pocket/services/dorm_service.dart';
import 'package:xiyuan_pocket/services/net_mode.dart';

const _chargeBasic = 'Basic Y2hhcmdlOmNoYXJnZV9zZWNyZXQ=';

/// 列出三个片区在平台上的**真实楼栋**，用于核对 `_seed` 是否漏项/多项。
void main() {
  final sno = Platform.environment['XY_SNO'] ?? '';
  final pwd = Platform.environment['XY_PWD'] ?? '';

  test('枚举三片区楼栋', () async {
    if (sno.isEmpty) return;
    NetMode.notifier.value = CampusNetMode.webvpn;
    DormService.debugSno = sno;
    DormService.debugPwd = pwd;
    final err = await DormService.loginOrError();
    // ignore: avoid_print
    print('[登录] ${err ?? "成功"}');
    if (err != null) return;

    final s = DormService.activeSession!;
    final h = {
      'Authorization': _chargeBasic,
      'synjones-auth': 'bearer ${DormService.debugToken ?? ""}',
    };

    Future<List<String>> cascade(String fee, int level, Map<String, String> picked) async {
      final r = await s.postForm(
        'http://10.3.100.110/charge/feeitem/getThirdData',
        {'feeitemid': fee, 'type': 'select', 'level': '$level', ...picked},
        headers: h,
      );
      final j = CampusSession.tryJson(r.body);
      final list = (j?['map']?['data'] as List?) ?? const [];
      return list
          .whereType<Map>()
          .map((e) => '${e['name']} | ${e['value']}')
          .toList();
    }

    for (final fee in ['448', '449', '450']) {
      final campusOpts = await cascade(fee, 0, {});
      // ignore: avoid_print
      print('\n=== 片区 $fee：校区 ${campusOpts.length} 个 ===');
      for (final c in campusOpts) {
        final campusVal = c.split(' | ').last;
        final blds = await cascade(fee, 1, {'campus': campusVal});
        // ignore: avoid_print
        print('  校区 $campusVal → 楼栋 ${blds.length} 个');
        for (final b in blds) {
          // ignore: avoid_print
          print('    $b');
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    DormService.clearToken();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
