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

  /// 按工具 id 取使用次数（云端 + 本地合并）。
  ///
  /// 2026-11-25：「服务页按使用自动排序」需要整张表，原来只有 increment
  /// 与两个总和。合并两份是因为同一个服务在 isCloud 变化后（比如以后改了
  /// 判定）历史计数不该丢 —— 一个服务只属于一边，相加不会重复计。
  static Future<Map<String, int>> loadCounts() async {
    final prefs = await SharedPreferences.getInstance();
    _migrateLegacy(prefs);
    final out = <String, int>{};
    for (final key in const [_kCloud, _kLocal]) {
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) continue;
      try {
        final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        map.forEach((id, v) {
          if (v is int) out[id] = (out[id] ?? 0) + v;
        });
      } catch (_) {
        // 存储被写坏就当没有 —— 排序是锦上添花，不能因此打不开服务页
      }
    }
    return out;
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
