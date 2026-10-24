import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 电费显示单位（2026-10-24）。
///
/// 全局唯一：详情页切换后，服务页卡片立即跟着变。
enum ElecUnit { yuan, kwh }

class ElecUnitStore {
  static const String _key = 'elec_unit_v1';

  static final ValueNotifier<ElecUnit> unit =
      ValueNotifier<ElecUnit>(ElecUnit.yuan);

  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_key);
    unit.value = v == 'kwh' ? ElecUnit.kwh : ElecUnit.yuan;
  }

  static Future<void> set(ElecUnit u) async {
    unit.value = u;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, u == ElecUnit.kwh ? 'kwh' : 'yuan');
  }

  static String label(ElecUnit u) => u == ElecUnit.kwh ? '度' : '元';
}
