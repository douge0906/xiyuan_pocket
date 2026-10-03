import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 工具使用次数统计（纯本地）。
/// v2.2.0: 拆分为云端工具与本地工具两个独立计数。
class ToolUsageStorage {
  static const _kCloud = 'tool_usage_cloud';
  static const _kLocal = 'tool_usage_local';
  static const _kLegacy = 'tool_usage_counts';

  /// 递增指定工具的计数并返回新值。
  /// [isCloud] 标记该工具是否调用云端接口（默认 true）。
  static Future<int> increment(String toolId, {bool isCloud = true}) async {
    final key = isCloud ? _kCloud : _kLocal;
    final prefs = await SharedPreferences.getInstance();
    _migrateLegacy(prefs);
    final raw = prefs.getString(key);
    final map =
        raw != null ? Map<String, int>.from(jsonDecode(raw) as Map) : <String, int>{};
    map[toolId] = (map[toolId] ?? 0) + 1;
    await prefs.setString(key, jsonEncode(map));
    return map[toolId]!;
  }

  /// 云端工具总使用次数。
  static Future<int> getCloudTotal() async {
    final prefs = await SharedPreferences.getInstance();
    _migrateLegacy(prefs);
    return _sumKey(prefs, _kCloud);
  }

  /// 本地工具总使用次数。
  static Future<int> getLocalTotal() async {
    final prefs = await SharedPreferences.getInstance();
    _migrateLegacy(prefs);
    return _sumKey(prefs, _kLocal);
  }

  // ---- internal ----

  static int _sumKey(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return 0;
    final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    return map.values.fold<int>(0, (a, b) => a + (b as int));
  }

  /// 将旧的 tool_usage_counts 数据迁移到新的云端 key（历史数据全按云端处理）。
  static void _migrateLegacy(SharedPreferences prefs) {
    final legacy = prefs.getString(_kLegacy);
    if (legacy == null || legacy.isEmpty) return;
    // 迁移到云端 key（历史所有工具默认都是云端调用）
    final existing = prefs.getString(_kCloud);
    final cloudMap = existing != null
        ? Map<String, int>.from(jsonDecode(existing) as Map)
        : <String, int>{};
    final legacyMap = Map<String, int>.from(jsonDecode(legacy) as Map);
    for (final entry in legacyMap.entries) {
      cloudMap[entry.key] = (cloudMap[entry.key] ?? 0) + entry.value;
    }
    prefs.setString(_kCloud, jsonEncode(cloudMap));
    prefs.remove(_kLegacy);
  }
}
