import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiyuan_pocket/pages/balance_detail_pages.dart';
import 'package:xiyuan_pocket/services/dorm_service.dart';

/// 两个详情页必须能**正常构建**。
///
/// 2026-10-26 出过一次事故：批量替换把 `_dorm = widget.dorm;` 改成了 `_dorm = _dorm;`，
/// `late` 变量自赋值 → `LateInitializationError` → release 下整页全屏灰。
/// analyze 不报错（语法合法），只能靠实际构建一次才抓得到。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 注入空账号：让 loginOrError 直接走「缺账密」分支，
    // 避开 flutter_secure_storage（测试环境没有平台通道）与真实网络。
    DormService.debugSno = '';
    DormService.debugPwd = '';
  });

  const dorm = DormInfo(
    feeitemid: 448,
    buildingValue: 'A5&李园壹號A5',
    buildingName: '李一',
    room: '211',
  );

  testWidgets('电费详情页可构建', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ElectricityPage(
        info: ElectricityInfo(
          text: '当前余额34.52元,当前剩余电量63.92度',
          balance: 34.52,
          kwh: 63.92,
          buildingName: '李一',
          room: '211',
        ),
        dorm: dorm,
      ),
    ));
    await tester.pump();
    expect(find.byType(ElectricityPage), findsOneWidget);
    // 金额应渲染出来（不是 "--"）
    expect(find.textContaining('34.52'), findsWidgets);
  });

  testWidgets('电费详情页：无电量片区（449/450）可构建', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ElectricityPage(
        info: ElectricityInfo(
          text: '房间当前剩余电费625.35',
          balance: 625.35,
          kwh: null,
          buildingName: '李九',
          room: '211',
        ),
        dorm: dorm,
      ),
    ));
    await tester.pump();
    expect(find.byType(ElectricityPage), findsOneWidget);
    expect(find.textContaining('625.35'), findsWidgets);
  });

  testWidgets('一卡通详情页可构建', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: CardBalancePage(balance: 40.89),
    ));
    await tester.pump();
    expect(find.byType(CardBalancePage), findsOneWidget);
    expect(find.textContaining('40.89'), findsWidgets);
  });
}
