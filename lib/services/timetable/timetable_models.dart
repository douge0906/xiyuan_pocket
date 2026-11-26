/// 班级课表在线库的数据模型。
///
/// 服务端返回的字段是 snake_case（`class_key` / `uploader_name` /
/// `course_count`…），这里统一转成 camelCase 的属性。转换集中在这一个文件，
/// 页面里就不再出现 `m['class_key']` 这种字符串下标 —— 拼错一个字母
/// 编译器不会报，运行时才悄悄变空值。
library;

/// 一致度：`matched / total`。`total == 0` 表示这条上传没带校方基线。
class TimetableConsistency {
  const TimetableConsistency({required this.matched, required this.total});

  final int matched;
  final int total;

  static const TimetableConsistency unknown =
      TimetableConsistency(matched: 0, total: 0);

  bool get hasBaseline => total > 0;
  bool get allSame => hasBaseline && matched == total;

  /// 「全一致」/「26/28」/「未比对」。与服务端后台同一套口径。
  String get label {
    if (!hasBaseline) return '未比对';
    if (allSame) return '全一致';
    return '$matched/$total';
  }

  factory TimetableConsistency.fromJson(Object? raw) {
    if (raw is! Map) return unknown;
    return TimetableConsistency(
      matched: _asInt(raw['matched']),
      total: _asInt(raw['total']),
    );
  }
}

/// 检索结果里的一个班级。
class TimetableClassSummary {
  const TimetableClassSummary({
    required this.classKey,
    required this.xnm,
    required this.xqm,
    required this.jgmc,
    required this.zymc,
    required this.bj,
    required this.njdmId,
    required this.timetableCount,
    required this.courseCount,
    required this.latestUploadedAt,
    required this.latestUploaderName,
    required this.consistency,
  });

  final String classKey;
  final String xnm;
  final String xqm;
  final String jgmc;
  final String zymc;
  final String bj;
  final String njdmId;
  final int timetableCount;

  /// 最新那一份的课程数（不是所有版本之和）。
  final int courseCount;
  final String latestUploadedAt;
  final String latestUploaderName;
  final TimetableConsistency consistency;

  String get orgLine {
    final parts = <String>[];
    if (zymc.isNotEmpty) parts.add(zymc);
    if (jgmc.isNotEmpty) parts.add(jgmc);
    return parts.join(' · ');
  }

  static TimetableClassSummary? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final bj = _s(raw['bj']);
    final classKey = _s(raw['class_key']);
    if (bj.isEmpty && classKey.isEmpty) return null;
    return TimetableClassSummary(
      classKey: classKey,
      xnm: _s(raw['xnm']),
      xqm: _s(raw['xqm']),
      jgmc: _s(raw['jgmc']),
      zymc: _s(raw['zymc']),
      bj: bj,
      njdmId: _s(raw['njdm_id']),
      timetableCount: _asInt(raw['timetable_count']),
      courseCount: _asInt(raw['course_count']),
      latestUploadedAt: _s(raw['latest_uploaded_at']),
      latestUploaderName: _s(raw['latest_uploader_name']),
      consistency: TimetableConsistency.fromJson(raw['consistency']),
    );
  }
}

/// 一门课（课表里的最小单元）。
class TimetableCourseItem {
  const TimetableCourseItem({
    required this.name,
    required this.teacher,
    required this.classroom,
    required this.weekday,
    required this.startSlot,
    required this.endSlot,
    required this.weeks,
  });

  final String name;
  final String teacher;
  final String classroom;

  /// 1 = 周一 … 7 = 周日。
  final int weekday;
  final int startSlot;
  final int endSlot;
  final String weeks;

  String get slotLabel => startSlot == endSlot ? '第$startSlot节' : '第$startSlot-$endSlot节';

  static TimetableCourseItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = _s(raw['name']).trim();
    if (name.isEmpty) return null;
    final weekday = _asInt(raw['weekday']);
    if (weekday < 1 || weekday > 7) return null;
    final start = _asInt(raw['start_slot']);
    if (start < 1) return null;
    return TimetableCourseItem(
      name: name,
      teacher: _s(raw['teacher']).trim(),
      classroom: _s(raw['classroom']).trim(),
      weekday: weekday,
      startSlot: start,
      endSlot: _asInt(raw['end_slot']) < start ? start : _asInt(raw['end_slot']),
      weeks: _s(raw['weeks']).trim(),
    );
  }

  /// 上报给服务端的形状（camelCase，与服务端 `_validate_body` 对齐）。
  Map<String, dynamic> toRequestJson() => <String, dynamic>{
        'name': name,
        'teacher': teacher,
        'classroom': classroom,
        'weekday': weekday,
        'startSlot': startSlot,
        'endSlot': endSlot,
        'weeks': weeks,
      };
}

/// 班级详情里的一份课表（某个同学提交的某一版）。
class TimetableVersion {
  const TimetableVersion({
    required this.id,
    required this.version,
    required this.uploaderName,
    required this.source,
    required this.courseCount,
    required this.createdAt,
    required this.publishedAt,
    required this.consistency,
    required this.note,
    required this.courses,
  });

  final int id;
  final int version;
  final String uploaderName;

  /// `local_table`（从本机课程表导入）/ `local_file`（从本机导出的文件导入）。
  final String source;
  final int courseCount;
  final String createdAt;
  final String publishedAt;
  final TimetableConsistency consistency;
  final String note;
  final List<TimetableCourseItem> courses;

  String get sourceLabel =>
      source == 'local_table' ? '从本机课程表导入' : '从本机导出的文件导入';

  static TimetableVersion? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = _asInt(raw['id']);
    if (id <= 0) return null;
    final coursesRaw = raw['courses'];
    final courses = <TimetableCourseItem>[];
    if (coursesRaw is List) {
      for (final item in coursesRaw) {
        final c = TimetableCourseItem.fromJson(item);
        if (c != null) courses.add(c);
      }
    }
    return TimetableVersion(
      id: id,
      version: _asInt(raw['version']),
      uploaderName: _s(raw['uploader_name']),
      source: _s(raw['source']),
      courseCount: _asInt(raw['course_count']),
      createdAt: _s(raw['created_at']),
      publishedAt: _s(raw['published_at']),
      consistency: TimetableConsistency.fromJson(raw['consistency']),
      note: _s(raw['note']),
      courses: courses,
    );
  }
}

/// 一个班级下所有已发布的课表。
class TimetableClassDetail {
  const TimetableClassDetail({
    required this.classKey,
    required this.xnm,
    required this.xqm,
    required this.jgmc,
    required this.zymc,
    required this.bj,
    required this.njdmId,
    required this.timetableCount,
    required this.timetables,
  });

  final String classKey;
  final String xnm;
  final String xqm;
  final String jgmc;
  final String zymc;
  final String bj;
  final String njdmId;
  final int timetableCount;
  final List<TimetableVersion> timetables;

  static TimetableClassDetail? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final listRaw = raw['timetables'];
    final versions = <TimetableVersion>[];
    if (listRaw is List) {
      for (final item in listRaw) {
        final v = TimetableVersion.fromJson(item);
        if (v != null) versions.add(v);
      }
    }
    return TimetableClassDetail(
      classKey: _s(raw['class_key']),
      xnm: _s(raw['xnm']),
      xqm: _s(raw['xqm']),
      jgmc: _s(raw['jgmc']),
      zymc: _s(raw['zymc']),
      bj: _s(raw['bj']),
      njdmId: _s(raw['njdm_id']),
      timetableCount: _asInt(raw['timetable_count']),
      timetables: versions,
    );
  }
}

/// 「我的上传」里的一条。**包含未发布的**（草稿、待审核、被驳回的都在）。
class TimetableOwnUpload {
  const TimetableOwnUpload({
    required this.id,
    required this.version,
    required this.xnm,
    required this.xqm,
    required this.jgmc,
    required this.zymc,
    required this.bj,
    required this.source,
    required this.uploaderName,
    required this.courseCount,
    required this.status,
    required this.published,
    required this.createdAt,
    required this.reviewedAt,
    required this.reviewReason,
    required this.reviewReasonText,
    required this.reviewNote,
  });

  final int id;
  final int version;
  final String xnm;
  final String xqm;
  final String jgmc;
  final String zymc;
  final String bj;
  final String source;
  final String uploaderName;
  final int courseCount;

  /// `pending` / `approved` / `rejected` / `removed`。
  final String status;
  final bool published;
  final String createdAt;
  final String reviewedAt;
  final String reviewReason;
  final String reviewReasonText;
  final String reviewNote;

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';
  bool get isRemoved => status == 'removed';

  /// 状态说明。审核通过但还没发布时要说清「还在发布」，否则用户会一直刷
  /// 班级详情页找不到自己那份，以为审核没过。
  String get statusLabel => switch (status) {
        'pending' => '待审核',
        'approved' => published ? '已发布' : '审核通过 · 发布中',
        'rejected' => '已驳回',
        'removed' => '已下架',
        _ => status,
      };

  String get sourceLabel =>
      source == 'local_table' ? '从本机课程表导入' : '从本机导出的文件导入';

  static TimetableOwnUpload? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = _asInt(raw['id']);
    if (id <= 0) return null;
    return TimetableOwnUpload(
      id: id,
      version: _asInt(raw['version']),
      xnm: _s(raw['xnm']),
      xqm: _s(raw['xqm']),
      jgmc: _s(raw['jgmc']),
      zymc: _s(raw['zymc']),
      bj: _s(raw['bj']),
      source: _s(raw['source']),
      uploaderName: _s(raw['uploader_name']),
      courseCount: _asInt(raw['course_count']),
      status: _s(raw['status']),
      published: _asInt(raw['published']) == 1,
      createdAt: _s(raw['created_at']),
      reviewedAt: _s(raw['reviewed_at']),
      reviewReason: _s(raw['review_reason']),
      reviewReasonText: _s(raw['review_reason_text']),
      reviewNote: _s(raw['review_note']),
    );
  }
}

/// 一条「新增 / 变更 / 移除」的差异明细，用来在导入前给用户看清楚。
class TimetableDiffEntry {
  const TimetableDiffEntry({
    required this.kind,
    required this.name,
    required this.detail,
  });

  /// `added` / `changed` / `removed`。
  final String kind;
  final String name;
  final String detail;
}

/// 覆盖导入前的差异摘要。
class TimetableDiffSummary {
  const TimetableDiffSummary({
    required this.added,
    required this.changed,
    required this.removed,
    required this.details,
  });

  final int added;
  final int changed;
  final int removed;
  final List<TimetableDiffEntry> details;

  bool get isEmpty => added == 0 && changed == 0 && removed == 0;
  bool get hasChanges => !isEmpty;
}

/// 学年学期：`2026-2027` + `3`（第 1 学期）/`12`（第 2 学期）/`16`（暑期）。
///
/// 服务端只认这三个 xqm 值，界面上要显示成人话。
class TimetableTerm {
  const TimetableTerm(this.xnm, this.xqm);

  final String xnm;
  final String xqm;

  String get label {
    final term = switch (xqm) {
      '3' => '第一学期',
      '12' => '第二学期',
      '16' => '暑期',
      _ => '第$xqm学期',
    };
    return '$xnm $term';
  }

  /// 从「2026-2027 + 3」推下一学期。
  TimetableTerm get next {
    if (xqm == '3') return TimetableTerm(xnm, '12');
    final startYear = int.tryParse(xnm.split('-').first);
    if (startYear == null) return TimetableTerm(xnm, '3');
    return TimetableTerm('${startYear + 1}-${startYear + 2}', '3');
  }

  @override
  bool operator ==(Object other) =>
      other is TimetableTerm && other.xnm == xnm && other.xqm == xqm;

  @override
  int get hashCode => Object.hash(xnm, xqm);
}

/// 把 `2026-11-25T16:30:00+08:00` 变成「2 小时前」。
///
/// 服务端时间都带 `+08:00`，`DateTime.parse` 能直接吃。解析不出来就返回空串
/// —— 绝不返回「刚刚」，那是在编造事实。
String timetableRelativeTime(String iso) {
  if (iso.trim().isEmpty) return '';
  final t = DateTime.tryParse(iso);
  if (t == null) return '';
  final diff = DateTime.now().difference(t.toLocal());
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return '${t.year}-${_two(t.month)}-${_two(t.day)}';
}

String _two(int n) => n.toString().padLeft(2, '0');

String _s(Object? v) => v == null ? '' : v.toString();

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? 0;
}
