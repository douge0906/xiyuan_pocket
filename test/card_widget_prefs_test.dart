import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiyuan_pocket/services/dorm_service.dart';
import 'package:xiyuan_pocket/services/storage_service.dart';
import 'package:xiyuan_pocket/services/widget_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('校园卡余额缓存与小组件缓存联动', () async {
    SharedPreferences.setMockInitialValues({});
    await DormService.saveCardCache(128.5);
    final cache = await StorageService.loadCardBalanceCache();
    expect(cache, isNotNull);
    expect(cache!.balance, 128.5);
  });

  test('小号课表组件模式二选一', () async {
    SharedPreferences.setMockInitialValues({});
    await WidgetPrefs.setSmallMode('countdown');
    expect(await WidgetPrefs.smallMode(), 'countdown');
    final json = await WidgetPrefs.toJson();
    expect(json['smallMode'], 'countdown');
    await WidgetPrefs.setSmallMode('time');
    expect(await WidgetPrefs.smallMode(), 'time');
  });
}
