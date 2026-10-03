import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/todo.dart';

/// 待办本地数据源（持久化层）。
///
/// 单一职责：仅负责待办列表的**原始读写**（序列化 / 反序列化），
/// 不含任何业务规则、不感知通知。业务编排全部交给 [TodoRepository]。
///
/// 采用 SharedPreferences 以 JSON 形式持久化，键固定为 [_key]。
/// 之所以不引入 sqflite：待办数据量小、无复杂查询，键值存储已足够，
/// 且能无缝兼容历史数据、避免新增原生依赖影响构建。
///
/// 抗损坏设计（v2.4.0）：
/// - 写入前先把旧值备份到 [_keyBak]，主数据损坏时可回退；
/// - 读取时**逐条**解析，单条脏数据只丢这一条，不再牵连整份列表；
/// - 整串无法解析时回退备份；主备都坏则把原始文本另存到 [_keyCorruptPrefix]
///   供排查，并返回空列表（绝不静默把空列表写回去覆盖数据）。
class TodoDatabase {
  TodoDatabase._();
  static final TodoDatabase instance = TodoDatabase._();

  static const _key = 'todo_list';
  static const _keyBak = 'todo_list_bak';
  static const _keyCorruptPrefix = 'todo_list_corrupt_';

  /// 读取全部待办。
  Future<List<Todo>> readAll() async {
    final prefs = await SharedPreferences.getInstance();
    final primary = prefs.getString(_key);
    final parsed = _parseList(primary);
    if (parsed != null) return parsed;

    // 主数据整串解析失败 → 回退备份。
    final bakRaw = prefs.getString(_keyBak);
    final bak = _parseList(bakRaw);
    if (bak != null && bak.isNotEmpty) {
      debugPrint('待办主数据解析失败，已回退备份（${bak.length} 条）');
      try {
        await prefs.setString(_key, jsonEncode(bak.map((t) => t.toJson()).toList()));
      } catch (_) {}
      return bak;
    }

    // 主备都不行：保留现场（另存原始文本），返回空列表，避免静默清空。
    if (primary != null && primary.isNotEmpty) {
      debugPrint('待办数据主备均解析失败，已保留现场快照');
      try {
        await prefs.setString(
          '$_keyCorruptPrefix${DateTime.now().millisecondsSinceEpoch}',
          primary,
        );
      } catch (_) {}
    }
    return [];
  }

  /// 覆盖写入全部待办（写前备份旧值）。
  Future<void> writeAll(List<Todo> todos) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getString(_key);
    final encoded = jsonEncode(todos.map((t) => t.toJson()).toList());
    if (current != null && current.isNotEmpty && current != encoded) {
      try {
        await prefs.setString(_keyBak, current);
      } catch (_) {}
    }
    await prefs.setString(_key, encoded);
  }

  /// 解析 JSON 列表字符串。
  /// 整串不是合法 JSON 数组时返回 null（交由调用方决定回退）；
  /// 单条解析失败只跳过该条，保留其余。
  List<Todo>? _parseList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final out = <Todo>[];
      for (final e in decoded) {
        try {
          if (e is Map<String, dynamic>) {
            out.add(Todo.fromJson(e));
          } else if (e is Map) {
            out.add(Todo.fromJson(Map<String, dynamic>.from(e)));
          }
        } catch (err) {
          debugPrint('跳过损坏的待办记录: $err');
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }
}
