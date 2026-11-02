import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/dorm_service.dart';
import 'package:xiyuan_pocket/services/net_mode.dart';

/// 遍历所有预置楼栋，用同一个房号查电费，看哪些通、哪些不通。
///
///   XY_SNO=xxx XY_PWD=xxx XY_ROOM=211 flutter test test/live_buildings_test.dart
///
/// 只读接口，不改任何数据；请求间留 300ms，避免触发平台风控。
void main() {
  final sno = Platform.environment['XY_SNO'] ?? '';
  final pwd = Platform.environment['XY_PWD'] ?? '';
  final room = Platform.environment['XY_ROOM'] ?? '211';

  test('各楼栋电费查询可用性', () async {
    if (sno.isEmpty || pwd.isEmpty) {
      // ignore: avoid_print
      print('跳过：未提供 XY_SNO / XY_PWD');
      return;
    }

    NetMode.notifier.value = CampusNetMode.webvpn; // 校外
    DormService.debugSno = sno;
    DormService.debugPwd = pwd;

    final err = await DormService.loginOrError();
    // ignore: avoid_print
    print('\n[登录] ${err ?? "成功"}\n');
    if (err != null) return;

    final list = await DormService.buildings();
    // ignore: avoid_print
    print('共 ${list.length} 栋，房号统一用 $room\n');
    // ignore: avoid_print
    print('楼栋\t\t结果');

    var ok = 0;
    var fail = 0;
    for (final b in list) {
      final dorm = DormInfo(
        feeitemid: b.feeitemid,
        buildingValue: b.value,
        buildingName: b.name,
        room: room,
        campus: b.campus,
      );
      final info = await DormService.query(dorm);
      if (info != null && (info.balance != null || info.kwh != null)) {
        ok++;
        // ignore: avoid_print
        print('${b.name}\t\tOK  ${info.balance} 元 / ${info.kwh} 度');
      } else {
        fail++;
        // ignore: avoid_print
        print('${b.name}\t\tFAIL ${DormService.lastLoginError.isEmpty ? "(无返回)" : DormService.lastLoginError}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    // ignore: avoid_print
    print('\n汇总：成功 $ok / 失败 $fail（共 ${list.length}）');
    DormService.clearToken();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
