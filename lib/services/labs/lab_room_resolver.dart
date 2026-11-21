import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// 一次「实验室名 → 标准教室」的换算结果。
///
/// [original] 非空表示确实发生了替换（原值 → [value]）；
/// 为空表示原值未命中对照表、或本身已经是「楼栋+房号」，保持原样。
class LabRoomResolution {
  const LabRoomResolution(this.value, [this.original]);

  final String value;
  final String? original;

  bool get changed => original != null;
}

/// 实验室 → 标准教室（楼栋 + 房间号）的换算器。
///
/// 数据来源：`assets/data/lab_rooms.json`（由《无锡学院实验室_机器可读.csv》生成，
/// 126 条，其中 55 条有房间号；房间号缺失的条目只用于识别、不参与替换）。
///
/// 规则（刻意保守，宁可不变也不要改错）：
/// 1. 原值已经是「已知楼栋 + 3~4 位房号」（如 `思齐楼309`）→ 只做空格归一化，视为标准；
/// 2. 实验室名称精确命中 → 换成 `楼栋+房号`；
/// 3. 名称包含命中（如 `电路与电子技术实验室2(21201032)` 含 `电路与电子技术实验室`）→
///    取最长的命中项；
/// 4. 对照表里该实验室没有房号、或完全没命中 → **保持原值**。
/// 5. 多房间实验室取对照表里的首个房号（这类结果用户仍可在导入面板里改）。
class LabRoomResolver {
  LabRoomResolver._(this._entries);

  final List<_LabRoomEntry> _entries;

  static const String assetPath = 'assets/data/lab_rooms.json';
  static LabRoomResolver? _cache;

  /// 读取并缓存内置对照表。读取失败时返回空表（调用方应保持原值）。
  static Future<LabRoomResolver> instance() async {
    final cached = _cache;
    if (cached != null) return cached;
    final raw = await rootBundle.loadString(assetPath);
    return _cache = fromJsonString(raw);
  }

  /// 测试用：直接从 JSON 文本构造，不依赖 asset bundle。
  static LabRoomResolver fromJsonString(String raw) {
    final data = jsonDecode(raw);
    final list = data is Map ? data['entries'] : null;
    final entries = <_LabRoomEntry>[];
    if (list is List) {
      for (final e in list) {
        if (e is! Map) continue;
        final name = (e['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        entries.add(_LabRoomEntry(
          name: name,
          building: (e['building'] ?? '').toString().trim(),
          room: (e['room'] ?? '').toString().trim(),
        ));
      }
    }
    return LabRoomResolver._(entries);
  }

  /// 已知楼栋名（用于识别「已经是标准教室」的值）。
  List<String> get buildings {
    final set = <String>{
      for (final e in _entries)
        if (e.building.isNotEmpty) e.building,
    };
    return set.toList()..sort((a, b) => b.length.compareTo(a.length));
  }

  /// 换算一个教室字段。返回结果里的 [LabRoomResolution.original] 便于 UI 统计。
  LabRoomResolution resolvePlace(String raw) {
    final original = raw.trim();
    if (original.isEmpty) return const LabRoomResolution('');

    final already = _canonicalBuildingRoom(original);
    if (already != null) {
      return already == original
          ? LabRoomResolution(original)
          : LabRoomResolution(already, original);
    }

    final norm = _norm(original);
    if (norm.isEmpty) return LabRoomResolution(original);

    _LabRoomEntry? best;
    for (final e in _entries) {
      if (e.room.isEmpty) continue;
      if (e.norm == norm) {
        best = e;
        break;
      }
      if (e.norm.length < 4 || norm.length < 4) continue;
      // 只允许「原值包含对照表全名」：`电路与电子技术实验室(21201032)` 命中
      // `电路与电子技术实验室`。反过来用 `e.norm.contains(norm)` 会让
      // 「电路实验室」这种短名称把「电路与电子技术实验室」误认成同一间。
      if (norm.contains(e.norm)) {
        if (best == null || e.norm.length > best.norm.length) best = e;
      }
    }
    if (best == null) return LabRoomResolution(original);

    final mapped = best.building.isEmpty ? best.room : '${best.building}${best.room}';
    if (mapped == original) return LabRoomResolution(original);
    return LabRoomResolution(mapped, original);
  }

  /// `思齐楼309` / `思齐楼 309` / `思齐楼309（PLC）` → `思齐楼309`。
  String? _canonicalBuildingRoom(String raw) {
    for (final b in buildings) {
      if (!raw.startsWith(b)) continue;
      final rest = raw.substring(b.length);
      final m = RegExp(r'^\s*(\d{3,4})').firstMatch(rest);
      if (m != null) return '$b${m.group(1)}';
      return null;
    }
    return null;
  }
}

String _norm(String input) {
  var s = input
      .replaceAll('（', '(')
      .replaceAll('）', ')')
      .replaceAll('　', ' ')
      .replaceAll(RegExp(r'\([^()]*\)'), '')
      .replaceAll(RegExp(r'\s+'), '');
  return s.toLowerCase();
}

class _LabRoomEntry {
  _LabRoomEntry({
    required this.name,
    required this.building,
    required this.room,
  }) : norm = _norm(name);

  final String name;
  final String building;
  final String room;
  final String norm;
}
