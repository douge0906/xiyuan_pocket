import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/storage_service.dart';

/// 成绩缓存状态：**成绩数据的唯一数据源**。
///
/// 为什么要有它：
///   - 「成绩查询」页写入缓存 → 「成绩概览」页自动刷新，不必重进页面；
///   - 两个页面不再各自 `StorageService.loadGradeCache()`。
///
/// 兼容性：底层仍是 `StorageService`（SharedPreferences），**存储格式不变**，
/// 与老版本数据完全兼容。
class GradeState {
  final List<dynamic> semesters;
  final Map<String, dynamic> summary;
  final Map<String, dynamic> student;
  final String savedAt;
  final bool loading;

  const GradeState({
    this.semesters = const [],
    this.summary = const {},
    this.student = const {},
    this.savedAt = '',
    this.loading = true,
  });

  bool get isEmpty => semesters.isEmpty;

  /// 可选学期名列表（教务格式形如 `2025-2026 第1学期`）
  List<String> get semesterNames => semesters
      .whereType<Map>()
      .map((m) => (m['name'] ?? '').toString())
      .where((n) => n.isNotEmpty)
      .toList();

  Map<String, dynamic>? semesterByName(String? name) {
    if (name == null || name.isEmpty) return null;
    for (final s in semesters) {
      if (s is Map && s['name'] == name) {
        return Map<String, dynamic>.from(s);
      }
    }
    return null;
  }
}

class GradeNotifier extends Notifier<GradeState> {
  Future<void>? _pending;

  @override
  GradeState build() {
    _pending = _reload();
    return const GradeState();
  }

  /// 等首次加载完成再返回当前状态。
  ///
  /// ⚠️ v2.4.2 修复：原实现是 `if (state.loading && _pending != null)`，
  ///    但 `build()` 里 `_pending = _reload()` 是**异步启动**、紧接着就
  ///    `return const GradeState()` —— 此刻 `state.loading` 还是 **false**
  ///    （`_reload` 还没来得及把 loading 置 true），条件永不成立，
  ///    `ensureLoaded()` **直接返回空状态**，导致本地缓存永远读不出来
  ///    （用户反馈「本地缓存了，但入口/页面看不到」）。
  ///
  /// 正确做法：只要 `_pending` 存在就等它，不依赖 `state.loading`。
  Future<GradeState> ensureLoaded() async {
    final pending = _pending;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        // 读取失败按空处理，不抛给界面
      }
      // `_reload()` 是给 `state` 赋值，await 完重新读一次即为最新
      return state;
    }
    return state;
  }

  /// 从本地缓存重新载入
  Future<void> load() => _reload();

  Future<void> _reload() async {
    Map<String, dynamic>? cache;
    try {
      cache = await StorageService.loadGradeCache();
    } catch (_) {
      cache = null;
    }
    state = GradeState(
      semesters: (cache?['semesters'] as List<dynamic>?) ?? const [],
      summary: (cache?['summary'] as Map<String, dynamic>?) ?? const {},
      student: (cache?['student'] as Map<String, dynamic>?) ?? const {},
      savedAt: (cache?['saved_at'] as String?) ?? '',
      loading: false,
    );
  }

  /// 查询成功后写入缓存（唯一写入口）
  Future<void> save({
    required List<dynamic> semesters,
    Map<String, dynamic>? summary,
    Map<String, dynamic>? student,
  }) async {
    final data = <String, dynamic>{
      'semesters': semesters,
      'summary': summary ?? const {},
      'student': student ?? const {},
      'saved_at': DateTime.now().toIso8601String(),
    };
    await StorageService.saveGradeCache(data);
    state = GradeState(
      semesters: semesters,
      summary: summary ?? const {},
      student: student ?? const {},
      savedAt: data['saved_at'] as String,
      loading: false,
    );
  }

  Future<void> clear() async {
    await StorageService.saveGradeCache(const {});
    state = const GradeState(loading: false);
  }
}

final gradeProvider =
    NotifierProvider<GradeNotifier, GradeState>(GradeNotifier.new);
