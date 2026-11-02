import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'control_service.dart';
import 'textbook_storage.dart';

/// 资源类型：教材 PDF / 试卷 / 答案。
enum ResourceKind {
  textbook('textbook'),
  examPaper('exam_paper'),
  answer('answer');

  const ResourceKind(this.code);
  final String code;

  static ResourceKind? tryFromCode(String code) {
    for (final kind in ResourceKind.values) {
      if (kind.code == code) return kind;
    }
    return null;
  }
}

class ResourceEntry {
  const ResourceEntry({
    required this.name,
    required this.kind,
    this.fileId = 0,
    this.parentId = 0,
    this.size = 0,
    this.downloads = 0,
    this.contributor = '',
    this.createdAt = '',
  });

  final String name;
  final ResourceKind kind;
  final int fileId;
  final int parentId;
  final int size;
  final int downloads;

  /// 上传者自愿填写的署名；空串表示匿名，界面不展示。
  final String contributor;
  final String createdAt;

  bool get isPdf => name.toLowerCase().endsWith('.pdf');
}

class ResourceCourse {
  ResourceCourse({
    required this.name,
    this.book = '',
    List<ResourceEntry>? resources,
  }) : resources = resources ?? <ResourceEntry>[];

  final String name;
  String book;
  final List<ResourceEntry> resources;

  String get key => normalizeResourceName(name);
  bool get hasBook => book.trim().isNotEmpty;

  List<ResourceEntry> of(ResourceKind kind) =>
      resources.where((e) => e.kind == kind).toList();

  int get totalCount => resources.length;

  int get totalSize =>
      resources.fold<int>(0, (sum, e) => sum + (e.size > 0 ? e.size : 0));

  String get latestAt {
    var latest = '';
    for (final e in resources) {
      if (e.createdAt.isNotEmpty && e.createdAt.compareTo(latest) > 0) {
        latest = e.createdAt;
      }
    }
    return latest;
  }
}

String normalizeResourceName(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll(RegExp(r'[()（）\[\]【】\-—_]+'), '');

class ResourceLoadResult {
  const ResourceLoadResult({
    required this.courses,
    this.failure,
    this.syncedAt,
  });

  final List<ResourceCourse> courses;
  final ControlFailure? failure;
  final String? syncedAt;

  bool get offline => failure != null;
}

/// 资源中心数据合并：教材中心课程 + 控制台审核通过的资源。
/// 只按课程名去重，自动合并教材与资源，不再区分“我的课程/共享课程”。
class ResourceStore {
  ResourceStore._();

  static const String _cacheKey = 'resource_center_cache_v1';
  static const String _cacheAtKey = 'resource_center_cache_at_v1';

  /// 上次成功上传时填的署名，下次自动带出（可改可清空）。
  static const String _contributorKey = 'resource_contributor_v1';

  /// 署名长度上限，与控制台 /api/v1/resource-uploads 的校验保持一致。
  static const int contributorMaxLength = 32;

  /// 记住的署名；空串表示匿名，界面不展示贡献者。
  static Future<String> loadContributor() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_contributorKey) ?? '').trim();
  }

  /// 保存署名；传空串会清掉记住的值（下次默认匿名）。
  static Future<void> saveContributor(String value) async {
    final prefs = await SharedPreferences.getInstance();
    final clean = value.trim();
    if (clean.isEmpty) {
      await prefs.remove(_contributorKey);
    } else {
      await prefs.setString(_contributorKey, clean);
    }
  }

  static Future<List<ResourceCourse>> loadCourses() async {
    return (await loadCoursesResult()).courses;
  }

  /// 只读教材 + 本地缓存，不发网络请求；用于先渲染再同步。
  static Future<ResourceLoadResult> loadCachedResult() async {
    final map = <String, ResourceCourse>{};

    void add(
      String name, {
      String book = '',
      List<ResourceEntry>? resources,
    }) {
      final clean = name.trim();
      if (clean.isEmpty) return;
      final key = normalizeResourceName(clean);
      final existing = map[key];
      if (existing == null) {
        map[key] = ResourceCourse(
          name: clean,
          book: book,
          resources: resources,
        );
        return;
      }
      if (existing.book.trim().isEmpty) existing.book = book.trim();
      if (resources != null) {
        for (final item in resources) {
          final duplicate = existing.resources.any(
              (x) => x.name == item.name && x.kind == item.kind);
          if (!duplicate) existing.resources.add(item);
        }
      }
    }

    try {
      for (final b in await TextbookStorage.loadBooks()) {
        add((b['name'] ?? '').toString(), book: (b['book'] ?? '').toString());
      }
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic>? cachedData;
    final raw = prefs.getString(_cacheKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) cachedData = decoded;
      } catch (_) {}
    }
    final courses = cachedData?['courses'];
    if (courses is List) {
      for (final c in courses) {
        if (c is! Map) continue;
        final files = c['files'];
        final entries = <ResourceEntry>[];
        if (files is List) {
          for (final f in files) {
            if (f is! Map) continue;
            final name = (f['name'] ?? '').toString().trim();
            if (name.isEmpty) continue;
            final kind = ResourceKind.tryFromCode(
                (f['area'] ?? '').toString());
            if (kind == null) continue;
            entries.add(ResourceEntry(
              name: name,
              kind: kind,
              fileId: (f['id'] as num?)?.toInt() ?? 0,
              parentId: (f['parentId'] as num?)?.toInt() ?? 0,
              size: (f['size'] as num?)?.toInt() ?? 0,
              downloads: (f['downloads'] as num?)?.toInt() ?? 0,
              contributor: (f['contributor'] ?? '').toString(),
              createdAt: (f['createdAt'] ?? '').toString(),
            ));
          }
        }
        add(
          (c['courseName'] ?? '').toString(),
          book: (c['bookName'] ?? '').toString(),
          resources: entries,
        );
      }
    }

    return ResourceLoadResult(
      courses: map.values.toList()..sort((a, b) => a.name.compareTo(b.name)),
      syncedAt: prefs.getString(_cacheAtKey),
    );
  }

  /// 先读本地缓存，再尝试网络；失败时保留缓存并返回失败原因。
  static Future<ResourceLoadResult> loadCoursesResult() async {
    final map = <String, ResourceCourse>{};

    void add(
      String name, {
      String book = '',
      List<ResourceEntry>? resources,
    }) {
      final clean = name.trim();
      if (clean.isEmpty) return;
      final key = normalizeResourceName(clean);
      final existing = map[key];
      if (existing == null) {
        map[key] = ResourceCourse(
          name: clean,
          book: book,
          resources: resources,
        );
        return;
      }
      if (existing.book.trim().isEmpty) existing.book = book.trim();
      if (resources != null) {
        for (final item in resources) {
          final duplicate = existing.resources.any(
              (x) => x.name == item.name && x.kind == item.kind);
          if (!duplicate) existing.resources.add(item);
        }
      }
    }

    void applyServerData(Map<String, dynamic>? data) {
      final courses = data?['courses'];
      if (courses is! List) return;
      for (final c in courses) {
        if (c is! Map) continue;
        final files = c['files'];
        final entries = <ResourceEntry>[];
        if (files is List) {
          for (final f in files) {
            if (f is! Map) continue;
            final name = (f['name'] ?? '').toString().trim();
            if (name.isEmpty) continue;
            final kind = ResourceKind.tryFromCode(
                (f['area'] ?? '').toString());
            if (kind == null) continue;
            entries.add(ResourceEntry(
              name: name,
              kind: kind,
              fileId: (f['id'] as num?)?.toInt() ?? 0,
              parentId: (f['parentId'] as num?)?.toInt() ?? 0,
              size: (f['size'] as num?)?.toInt() ?? 0,
              downloads: (f['downloads'] as num?)?.toInt() ?? 0,
              contributor: (f['contributor'] ?? '').toString(),
              createdAt: (f['createdAt'] ?? '').toString(),
            ));
          }
        }
        add(
          (c['courseName'] ?? '').toString(),
          book: (c['bookName'] ?? '').toString(),
          resources: entries,
        );
      }
    }

    try {
      for (final b in await TextbookStorage.loadBooks()) {
        add(
          (b['name'] ?? '').toString(),
          book: (b['book'] ?? '').toString(),
        );
      }
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic>? cachedData;
    final cachedRaw = prefs.getString(_cacheKey);
    if (cachedRaw != null && cachedRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(cachedRaw);
        if (decoded is Map<String, dynamic>) cachedData = decoded;
      } catch (_) {}
    }
    final cachedAt = prefs.getString(_cacheAtKey);

    final network = await ControlService.fetchResourcesResult();
    if (network.data != null) {
      applyServerData(network.data);
      final at = network.syncedAt ?? DateTime.now().toIso8601String();
      await prefs.setString(_cacheKey, jsonEncode(network.data));
      await prefs.setString(_cacheAtKey, at);
      return ResourceLoadResult(
        courses: map.values.toList()..sort((a, b) => a.name.compareTo(b.name)),
        syncedAt: at,
      );
    }

    applyServerData(cachedData);
    return ResourceLoadResult(
      courses: map.values.toList()..sort((a, b) => a.name.compareTo(b.name)),
      failure: network.failure,
      syncedAt: cachedAt,
    );
  }
}
