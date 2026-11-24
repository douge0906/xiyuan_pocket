/// Typed models for the 章节 / 任务点 (chapter / knowledge-point) study surface.
///
/// Everything here is a port of the official Android client 7.0.2's own beans
/// and parsers; inline citations give the exact `file:line` in the recovered
/// sources. The wire shapes are the Gson field names of those beans, so field
/// names below match the JSON keys rather than Dart style where the two differ.
library;

import 'dart:convert';

import 'chaoxing_sign_crypto.dart';

// =====================================================================
// Chapter tree — `com.chaoxing.fanya.common.model.Knowledge` /
// `com.chaoxing.fanya.aphone.ui.chapter.detail.bean.Knowledge2`
// =====================================================================

/// Per-node display state, port of `KnowledgeShowStatus`.
enum ChaoxingNodeShowStatus {
  /// Published and not studied yet (official: blue/normal title).
  open,

  /// Locked by the teacher (`close`/`time` while the class is not archived, or
  /// the unlock cascade of an unfinished `task` node).
  locked,

  /// Open with at least one unfinished 任务点 (`jobUnfinishedCount > 0`).
  jobNotOver,

  /// Open, no jobs left, and already clicked into (`clickcount > 0`).
  alreadyRead,
}

/// One flat entry of the chapter tree (chapter header *or* knowledge node).
///
/// Port of `Knowledge2` (`chapter/detail/bean/Knowledge2.java:13-35`) merged
/// with the per-user job fields the student `gas/clazz` gear call carries
/// (`img6 defpackage/fii.java:56` — `clickcount,finishcount,openlock,
/// unfinishcount,newchapterrule`). Parsing is lenient across the two field
/// spellings the server has used (`indexOrder`/`indexorder`,
/// `unfinishcount`/`jobUnfinishedCount`, …).
class ChaoxingKnowledgeNode {
  /// Creates a chapter-tree node.
  const ChaoxingKnowledgeNode({
    required this.id,
    required this.name,
    this.parentNodeId = '0',
    this.indexOrder = 0,
    this.label = '',
    this.layer = 1,
    this.status = '',
    this.beginTime = 0,
    this.endTime = 0,
    this.jobUnfinishedCount = 0,
    this.jobFinishedCount = 0,
    this.jobCount = 0,
    this.clickCount = 0,
    this.openLock = 0,
    this.newChapterRule = '',
    this.cards = const [],
    this.showStatus = ChaoxingNodeShowStatus.open,
  });

  /// Node id (`knowledgeid` elsewhere in the protocol).
  final String id;

  /// Display name.
  final String name;

  /// Parent node id; `"0"` marks a root chapter (`Course2.sortKnowledge`).
  final String parentNodeId;

  /// Sort key inside the parent (`Knowledge2.compareTo`).
  final int indexOrder;

  /// The small grey tag the official list shows next to the name.
  final String label;

  /// 1 = chapter header, ≥2 = studyable knowledge node.
  final int layer;

  /// Teacher-side publish state: `open` / `close` / `time` / `task`
  /// (`C6394b.f20120b = "task"`).
  final String status;

  /// Scheduled-open window, epoch millis; shown when [status] is `time`.
  final int beginTime;

  /// End of the scheduled-open window, epoch millis.
  final int endTime;

  /// Per-user unfinished 任务点 count (`unfinishcount` in the gear call,
  /// `jobUnfinishedCount` in `job/myjobsnodesmap`).
  final int jobUnfinishedCount;

  /// Per-user finished 任务点 count (`finishcount`).
  final int jobFinishedCount;

  /// Total 任务点 count of the node (`jobcount`).
  final int jobCount;

  /// Whether the student ever opened the node (`clickcount`; 0 = 未学).
  final int clickCount;

  /// 1 = the `task` unlock chain does *not* propagate through this node.
  final int openLock;

  /// Raw `newchapterrule` unlock-rule payload; opaque, kept for parity.
  final String newChapterRule;

  /// Card stubs when the gear response embedded `card.fields(…)`.
  final List<ChaoxingKnowledgeCard> cards;

  /// Computed by [ChaoxingChapterData.computeShowStatuses].
  final ChaoxingNodeShowStatus showStatus;

  /// True when this node is a studyable knowledge point, not a chapter header.
  bool get isKnowledge => layer > 1;

  /// Returns a copy with [showStatus] replaced.
  ChaoxingKnowledgeNode copyWithShowStatus(ChaoxingNodeShowStatus status) =>
      ChaoxingKnowledgeNode(
        id: id,
        name: name,
        parentNodeId: parentNodeId,
        indexOrder: indexOrder,
        label: label,
        layer: layer,
        status: this.status,
        beginTime: beginTime,
        endTime: endTime,
        jobUnfinishedCount: jobUnfinishedCount,
        jobFinishedCount: jobFinishedCount,
        jobCount: jobCount,
        clickCount: clickCount,
        openLock: openLock,
        newChapterRule: newChapterRule,
        cards: cards,
        showStatus: status,
      );

  /// Parses one entry of a gear `knowledge` array (lenient on spellings).
  factory ChaoxingKnowledgeNode.fromJson(Map<String, dynamic> json) {
    List<ChaoxingKnowledgeCard> cards = const [];
    var rawCards = json['card'] ?? json['cardList'];
    // Live `gas/knowledge` wraps the card list in another gear object
    // (`card:{data:[…]}`); older captures had a bare array.
    if (rawCards is Map) rawCards = asLooseMap(rawCards)['data'];
    if (rawCards is List) {
      cards = [
        for (final item in rawCards)
          if (item is Map)
            ChaoxingKnowledgeCard.fromJson(item.cast<String, dynamic>()),
      ]..sort();
    }
    return ChaoxingKnowledgeNode(
      id: _asString(json['id']),
      name: _asString(json['name']),
      parentNodeId: _asString(json['parentnodeid'], fallback: '0'),
      indexOrder: _asInt(json['indexOrder'] ?? json['indexorder']),
      label: _asString(json['label']),
      layer: _asInt(json['layer'], fallback: 1),
      status: _asString(json['status']),
      beginTime: _asInt(json['begintime']).toInt(),
      endTime: _asInt(json['endtime']).toInt(),
      jobUnfinishedCount: _asInt(
        json['unfinishcount'] ?? json['jobUnfinishedCount'],
      ),
      jobFinishedCount: _asInt(json['finishcount'] ?? json['jobFinishedCount']),
      jobCount: _asInt(json['jobcount']),
      clickCount: _asInt(json['clickcount']),
      openLock: _asInt(json['openlock']),
      newChapterRule: _asString(json['newchapterrule']),
      cards: cards,
    );
  }
}

/// One 卡片 inside a knowledge node — port of
/// `chapter/detail/bean/KnowledgeCard.java:7-17` /
/// `fanya/common/model/Card.java:4-12`.
class ChaoxingKnowledgeCard implements Comparable<ChaoxingKnowledgeCard> {
  /// Creates a card stub.
  const ChaoxingKnowledgeCard({
    required this.id,
    required this.knowledgeId,
    this.title = '',
    this.knowledgeTitle = '',
    this.description = '',
    this.cardOrder = 0,
    this.useType = -1,
  });

  /// Card id (`cardid` in the H5 card-page URL).
  final String id;

  /// The node this card belongs to.
  final String knowledgeId;

  /// Card title; falls back to [knowledgeTitle] when empty.
  final String title;

  /// `knowledgeTitile` (sic) — the node title as stored on the card.
  final String knowledgeTitle;

  /// Card description (HTML in `contentcard` responses).
  final String description;

  /// Sort key (`Card.compareTo`).
  final int cardOrder;

  /// Card use-type (`usetp`); live video cards carry `1`, documents carry
  /// other values. -1 when the field was not requested/absent.
  final int useType;

  /// Video attachments embedded in [description] — the `insertvideo` iframes
  /// the `contentcard(all)` response renders. A single card can hold several
  /// videos (each one its own 任务点).
  ///
  /// `gas/knowledge` returns the card list *without* the full video blobs, so
  /// these entries only carry the identities (`mid`/`objectid`/`jobid`) the
  /// caller uses to fetch each blob via
  /// `ChaoxingApiService.fetchKnowledgeCurVideo`.
  List<ChaoxingVideoEntry> get videoEntries => parseVideoEntries(description);

  /// True when [description] holds nothing but `insertvideo` iframes (plus
  /// whitespace/`<p>`/`<br/>` wrappers): the card is a pure video card with no
  /// document, attachment, quiz or text content.
  bool get isVideoOnly => _isOnlyModule(videoEntries);

  /// Document (PDF) attachments embedded in [description] — the `insertdoc`
  /// iframes. Mirrors [videoEntries] for PDFs; `jobid`/`objectid` are the keys
  /// for completion reporting and `ananas/status` respectively.
  List<ChaoxingDocumentEntry> get documentEntries =>
      parseDocumentEntries(description);

  /// True when [description] holds nothing but `insertdoc` iframes: a pure
  /// PDF/document card with no video, attachment, quiz or text content.
  bool get isDocumentOnly => _isOnlyModule(documentEntries);

  bool _isOnlyModule(List<Object> entries) {
    if (entries.isEmpty) return false;
    // Strip the iframes, then the paragraph/line-break wrappers (with or
    // without attributes) and whitespace. Any other tag or text — an <img>, an
    // <a>, a <span>, prose — survives, so a mixed card reads non-empty.
    final rest = description
        .replaceAll(_iframePattern, '')
        .replaceAll(RegExp(r'<p\b[^>]*>|</p>|<br\b[^>]*/?>|\s'), '');
    return rest.isEmpty;
  }

  /// Display title.
  String get displayTitle {
    final t = title.trim();
    if (t.isNotEmpty) return t;
    final k = knowledgeTitle.trim();
    return k.isEmpty ? displayOrderLabel : k;
  }

  /// Fallback label when the server sent no title at all.
  String get displayOrderLabel => 'card ${cardOrder + 1}';

  @override
  int compareTo(ChaoxingKnowledgeCard other) =>
      cardOrder.compareTo(other.cardOrder);

  /// Parses one entry of a gear `card` array.
  factory ChaoxingKnowledgeCard.fromJson(Map<String, dynamic> json) {
    return ChaoxingKnowledgeCard(
      id: _asString(json['id']),
      knowledgeId: _asString(json['knowledgeid']),
      title: _asString(json['title']),
      knowledgeTitle: _asString(json['knowledgeTitile']),
      description: _asString(json['description']),
      cardOrder: _asInt(json['cardorder']),
      useType: _asInt(json['usetp'], fallback: -1),
    );
  }
}

/// One video attachment referenced by a card's `insertvideo` iframe.
///
/// The card's [ChaoxingKnowledgeCard.description] embeds each video as an
/// `<iframe module="insertvideo" data="{…}">` whose `data` JSON carries the
/// `objectid`/`jobid`/`mid` trio plus the filename. These are the keys the
/// `knowledge/getknowledgecurvideo` endpoint needs to return the full video
/// blob.
class ChaoxingVideoEntry {
  /// Creates a video entry.
  const ChaoxingVideoEntry({
    required this.objectId,
    required this.jobId,
    required this.mid,
    this.title = '',
  });

  /// `objectid` — the ananas object identity.
  final String objectId;

  /// `jobid` — the 任务点 job the video completes.
  final String jobId;

  /// `mid` — the media id `getknowledgecurvideo` is keyed on.
  final String mid;

  /// `name` (filename) or empty; used as a fallback episode label.
  final String title;
}

/// One PDF/document attachment referenced by a card's `insertdoc` iframe.
///
/// Mirrors [ChaoxingVideoEntry] for documents: the `objectid` resolves the PDF
/// URL via `ananas/status/<objectid>`, and `jobid` is the job to report read
/// through `ananas/job` / `job/document`.
class ChaoxingDocumentEntry {
  /// Creates a document entry.
  const ChaoxingDocumentEntry({
    required this.objectId,
    required this.jobId,
    required this.mid,
    this.title = '',
  });

  /// `objectid` — the ananas object identity.
  final String objectId;

  /// `jobid` — the 任务点 job the document completes.
  final String jobId;

  /// `mid` — the media id.
  final String mid;

  /// `name` (filename) or empty.
  final String title;
}

/// The PDF status of one ananas object (`ananas/status/<objectid>`).
class ChaoxingPdfStatus {
  /// Creates a PDF status entry.
  const ChaoxingPdfStatus({
    required this.objectId,
    required this.pdfUrl,
    required this.filename,
    this.pagenum = 0,
  });

  /// `objectid` — echoes the requested ananas object id.
  final String objectId;

  /// The direct PDF URL (`pdf`); the CDN answers it anonymously (no cookie).
  final String pdfUrl;

  /// `filename` — the original file name.
  final String filename;

  /// `pagenum` — page count when the server reports it.
  final int pagenum;

  /// Parses the `ananas/status/<objectid>` JSON body, or null when it is not a
  /// usable PDF status.
  static ChaoxingPdfStatus? tryParse(Map<String, dynamic> json) {
    final objectId = _asString(json['objectid']);
    final pdfUrl = _asString(json['pdf']);
    if (objectId.isEmpty && pdfUrl.isEmpty) return null;
    return ChaoxingPdfStatus(
      objectId: objectId,
      pdfUrl: pdfUrl,
      filename: _asString(json['filename']),
      pagenum: _asInt(json['pagenum']),
    );
  }
}

/// One attachment's completion identity from the H5 card page's
/// `window.AttachmentSetting` (the `wxcard` response).
class ChaoxingDocumentJob {
  /// Creates a document job.
  const ChaoxingDocumentJob({
    required this.jobId,
    required this.jtoken,
    this.objectId = '',
    this.type = '',
  });

  /// `jobid` — the 任务点 job to report read.
  final String jobId;

  /// `jtoken` — the per-attachment token `job/document` requires.
  final String jtoken;

  /// `property.objectid` — the ananas object id.
  final String objectId;

  /// `type` — the attachment type (`document`, `video`, …).
  final String type;
}

/// Matches a whole `<iframe …>…</iframe>` (attributes may span the tag; the
/// embedded `data` JSON uses `&quot;`, never a raw quote).
final RegExp _iframePattern = RegExp(
  r'<iframe\b[^>]*>[\s\S]*?</iframe>',
  caseSensitive: false,
);

/// Extracts every `insertvideo` iframe from a card `description` HTML string
/// and returns its video identity, in document order.
///
/// The `data` attribute is HTML-entity-encoded JSON (`&quot;` for `"`), so it
/// is decoded before parsing. Malformed iframes are skipped, not thrown.
List<ChaoxingVideoEntry> parseVideoEntries(String description) => [
  for (final raw in _parseModuleEntries(description, 'insertvideo'))
    ChaoxingVideoEntry(
      objectId: raw.objectId,
      jobId: raw.jobId,
      mid: raw.mid,
      title: raw.title,
    ),
];

/// Extracts every `insertdoc` (PDF/document) iframe from a card `description`
/// HTML string, in document order. See [parseVideoEntries].
List<ChaoxingDocumentEntry> parseDocumentEntries(String description) => [
  for (final raw in _parseModuleEntries(description, 'insertdoc'))
    ChaoxingDocumentEntry(
      objectId: raw.objectId,
      jobId: raw.jobId,
      mid: raw.mid,
      title: raw.title,
    ),
];

/// Shared iframe scanner: returns the identity trio of every iframe whose tag
/// mentions [module].
List<({String objectId, String jobId, String mid, String title})>
    _parseModuleEntries(String description, String module) {
  final entries = <({String objectId, String jobId, String mid, String title})>[];
  for (final match in _iframePattern.allMatches(description)) {
    final tag = match.group(0)!;
    if (!tag.contains(module)) continue;
    final data = _htmlAttr(tag, 'data');
    if (data.isEmpty) continue;
    Map<String, dynamic> map;
    try {
      final decoded = jsonDecode(_htmlDecode(data));
      if (decoded is! Map) continue;
      map = decoded.cast<String, dynamic>();
    } on FormatException {
      continue;
    }
    final mid = _asString(map['mid']);
    final objectId = _asString(map['objectid'] ?? map['objectId']);
    final jobId = _asString(map['jobid'] ?? map['jobId'] ?? map['_jobid']);
    if (mid.isEmpty && objectId.isEmpty) continue;
    entries.add((
      objectId: objectId,
      jobId: jobId,
      mid: mid,
      title: _asString(map['name']),
    ));
  }
  return entries;
}

/// Pulls a double-quoted attribute value out of an HTML tag, or '' when the
/// attribute is absent or unquoted.
String _htmlAttr(String tag, String name) {
  final match = RegExp('$name="([^"]*)"', caseSensitive: false).firstMatch(tag);
  return match?.group(1) ?? '';
}

/// Decodes the HTML entities the `data` attribute uses for its JSON quotes.
String _htmlDecode(String input) => input
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

/// A course's whole chapter tree as returned by the student gear call.
///
/// Port of `Course2` (`chapter/detail/bean/Course2.java`): a *flat* node list
/// linked into a tree through `parentnodeid`, sorted by `indexorder`
/// (`Course2.sortKnowledge:114-146`), plus the class fields the show-status
/// cascade needs (`Course2.calShowStatus:70-107`).
class ChaoxingChapterData {
  /// Creates chapter data from an already-linked flat node list.
  const ChaoxingChapterData({
    required this.nodes,
    this.courseId = '',
    this.courseName = '',
    this.clazzId = '',
    this.clazzName = '',
    this.clazzState = 0,
    this.clazzIsFiled = 0,
  });

  /// Flat, depth-first ordered node list (parents before children).
  final List<ChaoxingKnowledgeNode> nodes;

  /// Course id the tree belongs to.
  final String courseId;

  /// Course display name.
  final String courseName;

  /// Class id the gear call was made with.
  final String clazzId;

  /// Class display name.
  final String clazzName;

  /// `Clazz.state` — 1 opens otherwise-locked nodes to alumni
  /// (`Course2.calShowStatus:77`).
  final int clazzState;

  /// `Clazz.isfiled` — the class is archived/graduated.
  final int clazzIsFiled;

  bool get _clazzOpen => clazzState == 1 || clazzIsFiled == 1;

  /// Root chapters (`parentnodeid == "0"`), in order.
  List<ChaoxingKnowledgeNode> get roots => [
    for (final node in nodes)
      if (node.parentNodeId == '0') node,
  ];

  /// Direct children of [parent], in order.
  List<ChaoxingKnowledgeNode> childrenOf(ChaoxingKnowledgeNode parent) => [
    for (final node in nodes)
      if (node.parentNodeId == parent.id) node,
  ];

  /// Recomputes every node's [ChaoxingKnowledgeNode.showStatus] with the
  /// official cascade and returns a copy of this data with the new statuses.
  ///
  /// Direct port of `Course2.calShowStatus` (`Course2.java:70-107`): a `task`
  /// node with unfinished jobs and `openlock == 0` locks every *later* node
  /// until the class is open to the student (`state`/`isfiled`).
  ChaoxingChapterData computeShowStatuses() {
    var cascadeLocked = false;
    final updated = <ChaoxingKnowledgeNode>[];
    for (final node in nodes) {
      if (!node.isKnowledge) {
        updated.add(node);
        continue;
      }
      final ChaoxingNodeShowStatus status;
      if (cascadeLocked) {
        status = _clazzOpen
            ? ChaoxingNodeShowStatus.open
            : ChaoxingNodeShowStatus.locked;
      } else if (node.status == 'close' || node.status == 'time') {
        status = _clazzOpen
            ? ChaoxingNodeShowStatus.open
            : ChaoxingNodeShowStatus.locked;
      } else if (node.status == 'open' || node.status == 'task') {
        if (node.jobUnfinishedCount > 0) {
          status = ChaoxingNodeShowStatus.jobNotOver;
          if (node.status == 'task' && node.openLock == 0) cascadeLocked = true;
        } else if (node.clickCount == 0) {
          status = ChaoxingNodeShowStatus.open;
          if (node.status == 'task' && node.openLock == 0) cascadeLocked = true;
        } else {
          status = ChaoxingNodeShowStatus.alreadyRead;
        }
      } else {
        // Unknown/absent status: stay permissive. The server enforces the real
        // gate when the node is opened; a parse miss must not lock the course.
        status = ChaoxingNodeShowStatus.open;
      }
      updated.add(node.copyWithShowStatus(status));
    }
    return ChaoxingChapterData(
      nodes: updated,
      courseId: courseId,
      courseName: courseName,
      clazzId: clazzId,
      clazzName: clazzName,
      clazzState: clazzState,
      clazzIsFiled: clazzIsFiled,
    );
  }

  /// Parses a `gas/clazz?id=…course.fields(…knowledge.fields(…))&view=json`
  /// response (`img6 defpackage/fii.java:44-56`, student branch).
  ///
  /// Lenient across the two envelope conventions the hosts use
  /// (`{status:0,data:…}` gear vs `{result:1,msg:…}` legacy).
  factory ChaoxingChapterData.fromGearJson(Map<String, dynamic> json) {
    final data = asGearRecord(json['data'] ?? json['msg'], fallback: json);
    final course = asGearRecord(data['course'], fallback: data);
    final clazz = asLooseMap(data['clazz']);
    final rawNodes = _asNodeList(course['knowledge'] ?? data['knowledge']);
    final nodes = <ChaoxingKnowledgeNode>[];
    for (final item in rawNodes) {
      if (item is Map) {
        nodes.add(
          ChaoxingKnowledgeNode.fromJson(item.cast<String, dynamic>()),
        );
      }
    }
    _linkAndSort(nodes);
    return ChaoxingChapterData(
      nodes: nodes,
      courseId: _asString(course['id'] ?? data['courseid']),
      courseName: _asString(course['name']),
      clazzId: _asString(data['id'] ?? clazz['id']),
      clazzName: _asString(data['name'] ?? clazz['name']),
      clazzState: _asInt(data['state'] ?? clazz['state']),
      clazzIsFiled: _asInt(data['isfiled'] ?? clazz['isfiled']),
    ).computeShowStatuses();
  }

  /// Sorts [nodes] by `indexorder` inside each parent and flattens the tree
  /// depth-first in place — `Course2.sortKnowledge:114-146`.
  static void _linkAndSort(List<ChaoxingKnowledgeNode> nodes) {
    nodes.sort((a, b) => a.indexOrder.compareTo(b.indexOrder));
    final byParent = <String, List<ChaoxingKnowledgeNode>>{};
    for (final node in nodes) {
      byParent.putIfAbsent(node.parentNodeId, () => []).add(node);
    }
    final flat = <ChaoxingKnowledgeNode>[];
    void walk(String parentId) {
      for (final child in byParent[parentId] ?? const []) {
        flat.add(child);
        walk(child.id);
      }
    }

    walk('0');
    // Orphans (parent missing from the response) keep their relative order at
    // the end rather than disappearing.
    if (flat.length < nodes.length) {
      final seen = {for (final n in flat) n.id};
      for (final node in nodes) {
        if (!seen.contains(node.id)) flat.add(node);
      }
    }
    nodes
      ..clear()
      ..addAll(flat);
  }
}

// =====================================================================
// Course video — `com.chaoxing.mobile.player.course.model.CourseVideo`
// parsed by `model/C19427d.m76745c` (`C19427d.java:77-142`)
// =====================================================================

/// One CDN line/quality of a course video (`C19427d.m76746d`, from the blob's
/// `cdn` array).
class ChaoxingVideoLine {
  /// Creates a CDN line entry.
  const ChaoxingVideoLine({
    required this.url,
    this.name = '',
    this.line = '',
    this.px = '',
    this.networkType = -1,
    this.resolution = -1,
    this.sourceType = 0,
  });

  /// Stream URL of this line.
  final String url;

  /// Display name (unicode-decoded by the official parser).
  final String name;

  /// Line identifier.
  final String line;

  /// Resolution label as text (e.g. `720p`).
  final String px;

  /// Network type hint; -1 when absent.
  final int networkType;

  /// Resolution rank; -1 when absent.
  final int resolution;

  /// Source type flag.
  final int sourceType;

  /// Parses one entry of the blob's `cdn` array.
  factory ChaoxingVideoLine.fromJson(Map<String, dynamic> json) {
    return ChaoxingVideoLine(
      url: _asString(json['url']),
      name: _asString(json['name']),
      line: _asString(json['line']),
      px: _asString(json['px']),
      networkType: _asInt(json['networkType'], fallback: -1),
      resolution: _asInt(json['resolution'], fallback: -1),
      sourceType: _asInt(json['sourcetype']),
    );
  }
}

/// The video-info blob the official player consumes.
///
/// The H5 card page hands this exact JSON to the native player through the
/// `CLIENT_OPEN_CHAPTER_VIDEO` bridge call or a `nativeapi:` navigation
/// (`jsprotocal/course/C21577c.java:101-127`,
/// `ChapterCardFragment.java:88-104,320-331`); `knowledge/getnextknowledgevideo`
/// returns the same shape as its `videoObject` field
/// (`player/course/model/InterfaceC19424a.java:55-57`). Field set and defaults
/// are `C19427d.m76745c`'s.
class ChaoxingCourseVideo {
  /// Creates a course-video descriptor.
  const ChaoxingCourseVideo({
    required this.httpUrl,
    required this.objectId,
    this.title = '',
    this.durationSeconds = 0,
    this.otherInfo = '',
    this.jobId = '',
    this.fastForward = false,
    this.vbeginSeconds = 0,
    this.vendSeconds = 0,
    this.headOffsetSeconds = 0,
    this.playTimeSeconds = 0,
    this.reportIntervalSeconds = 60,
    this.reportUrl = '',
    this.knowledgeId = '',
    this.courseId = '',
    this.clazzId = '',
    this.mid = '',
    this.initDataUrl = '',
    this.rt = 0,
    this.cardId = '',
    this.cpi = '',
    this.aid = '',
    this.doubleSpeed = '',
    this.captureConfig = '',
    this.faceRecConfig = '',
    this.danmu = 0,
    this.videoLines = const [],
    this.rawJson = '',
  });

  /// The blob's `http` field — direct media URL (mp4/m3u8), cookie-free.
  final String httpUrl;

  /// `objectid` — the ananas object identity, used in the report `enc`.
  final String objectId;

  /// `videoName` when present, else the caller's card title.
  final String title;

  /// Total duration in **seconds** (`C19427d.java:94`; the report multiplies
  /// by 1000 — `CourseViewModel.java:563`).
  final int durationSeconds;

  /// `otherInfo` — the jobid-as-string the report echoes back.
  final String otherInfo;

  /// `jobid` — empty for non-任务点 videos (then no completion is recorded).
  final String jobId;

  /// `fastforward` — false forbids seeking past the watched position.
  final bool fastForward;

  /// `vbegin` — teacher clip start, seconds; 0/absent = whole video.
  final int vbeginSeconds;

  /// `vend` — teacher clip end, seconds; 0/absent = whole video.
  final int vendSeconds;

  /// `headOffset` — intro skip in seconds; ≤0 = none (`C19427d.java:102-110`).
  final int headOffsetSeconds;

  /// `playTime` — server-remembered resume position, seconds.
  final int playTimeSeconds;

  /// `reportTimeInterval` — heartbeat period, seconds; official default 60
  /// (`C19427d.java:112-116`, `CourseViewModel.m76783E`).
  final int reportIntervalSeconds;

  /// `reportUrl` — absolute multimedia-log base the query is appended to.
  final String reportUrl;

  /// `knowledgeid` — the chapter node the video belongs to.
  final String knowledgeId;

  /// `courseid`.
  final String courseId;

  /// `clazzId` — part of the report `enc`.
  final String clazzId;

  /// `mid` — subtitle/media id (`richvideo/subtitle`).
  final String mid;

  /// `initDataUrl` — pop-quiz/face-rec payload source; non-empty means the
  /// video carries interactive anti-cheat the native player does not render.
  final String initDataUrl;

  /// `rt` — the required viewing ratio for the 任务点 to count as finished
  /// (`0.7` = watch 70% of the video; the report echoes it verbatim as the
  /// `rt=%s` slot and the server bakes it into `otherInfo` as `rt_0.7`).
  final double rt;

  /// `cardid` — the knowledge card the video sits on.
  final String cardId;

  /// `cpi` — the enrolment personid.
  final String cpi;

  /// `aid` — attachment id.
  final String aid;

  /// `doublespeed` — `"0"` disables the speed menu
  /// (`CourseViewModel.m76806k`), otherwise a comma list like `1,1.5,2`.
  final String doubleSpeed;

  /// `captureConfig` — random captcha anti-cheat configuration JSON string.
  final String captureConfig;

  /// `faceRecConfig` — face-recognition anti-cheat configuration JSON string.
  final String faceRecConfig;

  /// `danmu` — 1 enables the danmaku rail.
  final int danmu;

  /// `cdn` array — alternate lines/qualities.
  final List<ChaoxingVideoLine> videoLines;

  /// The blob exactly as received, kept for diagnostics parity with
  /// `CourseVideo.setJsonStr`.
  final String rawJson;

  /// True when the player can report progress at all
  /// (`CourseViewModel.m76805j`: a non-empty `reportUrl` gates every report).
  bool get canReport => reportUrl.trim().isNotEmpty;

  /// True when the video carries interactive anti-cheat (pop quizzes, face
  /// recognition) that only the official H5/native player implements. Callers
  /// should leave those videos to the WebView card page.
  bool get requiresInteractiveGuard =>
      captureConfig.trim().isNotEmpty ||
      faceRecConfig.trim().isNotEmpty ||
      initDataUrl.trim().isNotEmpty;

  /// Playback URL: [httpUrl] with the official `_rd` cache-buster appended
  /// (`C19427d.java:82-87`), falling back to the first CDN line.
  String playbackUrl({int? rd}) {
    var base = httpUrl.trim();
    if (base.isEmpty && videoLines.isNotEmpty) {
      base = videoLines.first.url;
    }
    if (base.isEmpty) return '';
    final stamp = rd ?? DateTime.now().millisecondsSinceEpoch;
    return base.contains('?') ? '$base&_rd=$stamp' : '$base?_rd=$stamp';
  }

  /// Speed choices for the player menu: `[1.0]` when `doublespeed` is absent
  /// or `"0"` (speed switching disabled), else the official fixed rate ladder
  /// (`videojs` `playbackRates`: `0.75 / 1 / 1.25 / 1.5 / 2`). `doublespeed` is
  /// a 0/1 gate, not a list; a comma-list (legacy captures) is still honoured
  /// when present.
  List<double> get speedOptions {
    if (!speedAdjustable) return const [1.0];
    final raw = doubleSpeed.trim();
    if (raw.contains(',')) {
      final parsed = [
        for (final part in raw.split(','))
          if ((double.tryParse(part.trim()) ?? 0) > 0)
            double.parse(part.trim()),
      ];
      if (parsed.isNotEmpty) {
        if (!parsed.contains(1.0)) parsed.insert(0, 1.0);
        return parsed;
      }
    }
    return const [0.75, 1.0, 1.25, 1.5, 2.0];
  }

  /// Whether the speed menu is offered at all (`CourseViewModel.m76806k`).
  bool get speedAdjustable => doubleSpeed.trim().isNotEmpty &&
      doubleSpeed.trim() != '0';

  /// Where playback should start, millis — port of `CourseViewModel.m76784F`
  /// + `m76820y`: resume from the server `playTime` unless that is within a
  /// second of the end (then restart), never before the intro `headOffset`,
  /// clamped into the clip window and the duration.
  int get initialPositionMillis {
    final durationMs = durationSeconds * 1000;
    var start = playTimeSeconds * 1000;
    if (durationMs > 0 && durationMs - start <= 1000) start = 0;
    final head = headOffsetSeconds > 0 ? headOffsetSeconds * 1000 : 0;
    if (head > start) start = head;
    final begin = vbeginSeconds > 0 ? vbeginSeconds * 1000 : 0;
    if (start < begin) start = begin;
    if (durationMs > 0 && start > durationMs) start = 0;
    return start;
  }

  /// Playback end boundary, millis: the teacher's `vend` clip when set,
  /// else the full duration (0 = unknown).
  int get endPositionMillis {
    final durationMs = durationSeconds * 1000;
    final vend = vendSeconds > 0 ? vendSeconds * 1000 : 0;
    if (vend > 0 && (durationMs == 0 || vend < durationMs)) return vend;
    return durationMs;
  }

  /// Parses the blob; returns null when it is not a usable video object
  /// (`type != "video"` is tolerated — the native api payload carries it,
  /// the bridge payload usually does not).
  static ChaoxingCourseVideo? tryParse(String json, {String fallbackTitle = ''}) {
    Map<String, dynamic> map;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return null;
      map = decoded.cast<String, dynamic>();
    } on FormatException {
      return null;
    }
    final objectId = _asString(map['objectid'] ?? map['objectId']);
    final httpUrl = _asString(map['http']);
    if (objectId.isEmpty && httpUrl.isEmpty) return null;
    final title = _asString(map['videoName']);
    final interval = _asInt(map['reportTimeInterval']);
    return ChaoxingCourseVideo(
      httpUrl: httpUrl,
      objectId: objectId,
      title: title.isNotEmpty ? title : fallbackTitle,
      durationSeconds: _asInt(map['duration']),
      otherInfo: _asString(map['otherInfo']),
      jobId: _asString(map['jobid'] ?? map['jobId']),
      fastForward: _asBool(map['fastforward']),
      vbeginSeconds: _asInt(map['vbegin']),
      vendSeconds: _asInt(map['vend']),
      headOffsetSeconds: _asInt(map['headOffset']),
      playTimeSeconds: _asInt(map['playTime']),
      reportIntervalSeconds: interval > 0 ? interval : 60,
      reportUrl: _asString(map['reportUrl']),
      knowledgeId: _asString(map['knowledgeid']),
      courseId: _asString(map['courseid']),
      clazzId: _asString(map['clazzId'] ?? map['clazzid']),
      mid: _asString(map['mid']),
      initDataUrl: _asString(map['initDataUrl']),
      rt: _asDouble(map['rt']),
      cardId: _asString(map['cardid']),
      cpi: _asString(map['cpi']),
      aid: _asString(map['aid']),
      doubleSpeed: _asString(map['doublespeed']),
      captureConfig: _asString(map['captureConfig']),
      faceRecConfig: _asString(map['faceRecConfig']),
      danmu: _asInt(map['danmu']),
      videoLines: [
        if (map['cdn'] is List)
          for (final item in map['cdn'] as List)
            if (item is Map) ChaoxingVideoLine.fromJson(item.cast<String, dynamic>()),
      ],
      rawJson: json,
    );
  }
}

// =====================================================================
// Video pop-quiz (弹题) — `richvideo/initdatawithviewerV2`
// =====================================================================

/// One answer option of a pop-quiz question (`options[]`).
class ChaoxingQuizOption {
  /// Creates a quiz answer option.
  const ChaoxingQuizOption({required this.name, required this.description});

  /// `name` — the option key (`A`/`B`/…) submitted back verbatim.
  final String name;

  /// `description` — the option text.
  final String description;

  /// Parses one `options[]` entry; null when it has no option key.
  static ChaoxingQuizOption? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<String, dynamic>();
    final name = _asString(map['name']);
    if (name.isEmpty) return null;
    return ChaoxingQuizOption(name: name, description: _asString(map['description']));
  }
}

/// One pop-quiz question — a `datas[]` item whose event `style` is
/// `InteractiveQuiz` in `initdatawithviewerV2`.
class ChaoxingQuizQuestion {
  /// Creates a pop-quiz question.
  const ChaoxingQuizQuestion({
    required this.resourceId,
    required this.startTime,
    this.endTime = 0,
    this.questionType = '',
    this.description = '',
    this.options = const [],
    this.memberinfo = '',
    this.interactiveQuestionCount = 0,
    this.errorBack = 0,
    this.errorMustBack = 0,
    this.errorContinue = 0,
    this.errorBackTime = 0,
    this.validationUrl = '',
  });

  /// `resourceId` — the `eventid` sent to `quiz-validation`/`quiz-rightcount`.
  final int resourceId;

  /// `startTime` — when (in **seconds**) the question pops up.
  final double startTime;

  /// `endTime` — 0/absent = a single point in time.
  final double endTime;

  /// `questionType` — 单选题 / 多选题 / 判断题.
  final String questionType;

  /// `description` — the question stem (题干).
  final String description;

  /// `options` — the selectable answers.
  final List<ChaoxingQuizOption> options;

  /// `memberinfo` — opaque per-question token required by validation.
  final String memberinfo;

  /// `interactiveQuestionCount` — total quiz questions in this video.
  final int interactiveQuestionCount;

  /// Wrong-answer behaviour: rewind `errorBackTime` seconds and/or stay blocked
  /// until the correct answer is given (`errorContinue == 0`/`errorMustBack`).
  final int errorBack;

  /// `errorMustBack` — 1 = playback is blocked until the answer is correct.
  final int errorMustBack;

  /// `errorContinue` — 1 = playback continues even after a wrong answer.
  final int errorContinue;

  /// `errorBackTime` — how many seconds to rewind on a wrong answer.
  final int errorBackTime;

  /// `validationUrl` (`/richvideo/qv`) — legacy relative validation endpoint.
  final String validationUrl;

  /// Whether a wrong answer blocks playback until the question is answered
  /// correctly (the official "答对才可继续观看" rule).
  bool get mustAnswerCorrectly => errorMustBack > 0 || errorContinue == 0;

  /// Parses one `InteractiveQuiz` `datas[]` entry; null when it has no id.
  static ChaoxingQuizQuestion? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<String, dynamic>();
    final resourceId = _asInt(map['resourceId']);
    if (resourceId <= 0) return null;
    final options = <ChaoxingQuizOption>[];
    final rawOptions = map['options'];
    if (rawOptions is List) {
      for (final item in rawOptions) {
        final option = ChaoxingQuizOption.tryParse(item);
        if (option != null) options.add(option);
      }
    }
    return ChaoxingQuizQuestion(
      resourceId: resourceId,
      startTime: _asDouble(map['startTime']),
      endTime: _asDouble(map['endTime']),
      questionType: _asString(map['questionType']),
      description: _asString(map['description']),
      options: options,
      memberinfo: _asString(map['memberinfo']),
      interactiveQuestionCount: _asInt(map['interactiveQuestionCount']),
      errorBack: _asInt(map['errorBack']),
      errorMustBack: _asInt(map['errorMustBack']),
      errorContinue: _asInt(map['errorContinue']),
      errorBackTime: _asInt(map['errorBackTime']),
      validationUrl: _asString(map['validationUrl']),
    );
  }
}

/// One non-question timed event (批注 annotation, image, PPT frame).
class ChaoxingQuizEvent {
  /// Creates a non-question timed event.
  const ChaoxingQuizEvent({
    required this.style,
    required this.resourceId,
    this.startTime = 0,
    this.endTime = 0,
    this.description = '',
    this.url = '',
    this.pageNo = 0,
    this.thumb = '',
  });

  /// `style` — `SyncAnnotationEvent` / `IMG` / `PPT`.
  final String style;

  /// `resourceId` — the event identity.
  final int resourceId;

  /// `startTime` — when (in seconds) the event fires.
  final double startTime;

  /// `endTime` — 0/absent = a single point in time.
  final double endTime;

  /// `description` — annotation text (批注), empty for image/PPT.
  final String description;

  /// `url` — the image/PPT resource URL.
  final String url;

  /// `pageNo` — PPT page index.
  final int pageNo;

  /// `thumb` — PPT thumbnail.
  final String thumb;
}

/// The parsed `initdatawithviewerV2` payload: every timed interactive event of
/// one video, split into pop-quiz questions and the other event kinds.
class ChaoxingVideoQuiz {
  /// Creates a parsed quiz/event payload.
  const ChaoxingVideoQuiz({this.questions = const [], this.events = const []});

  /// The pop-quiz questions, in `startTime` order.
  final List<ChaoxingQuizQuestion> questions;

  /// The non-question events (批注 / image / PPT), in `startTime` order.
  final List<ChaoxingQuizEvent> events;

  /// True when the video carries no interactive events at all.
  bool get isEmpty => questions.isEmpty && events.isEmpty;

  /// Parses the `initdatawithviewerV2` JSON array.
  static ChaoxingVideoQuiz parse(Object? raw) {
    final questions = <ChaoxingQuizQuestion>[];
    final events = <ChaoxingQuizEvent>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final map = item.cast<String, dynamic>();
        final style = _asString(map['style']);
        final datas = map['datas'];
        if (datas is! List || datas.isEmpty) continue;
        final first = datas.first;
        if (first is! Map) continue;
        if (style == 'InteractiveQuiz') {
          final question = ChaoxingQuizQuestion.tryParse(first);
          if (question != null) questions.add(question);
        } else {
          final firstMap = first.cast<String, dynamic>();
          events.add(
            ChaoxingQuizEvent(
              style: style,
              resourceId: _asInt(firstMap['resourceId']),
              startTime: _asDouble(firstMap['startTime']),
              endTime: _asDouble(firstMap['endTime']),
              description: _asString(firstMap['description']),
              url: _asString(firstMap['url']),
              pageNo: _asInt(firstMap['pageNo']),
              thumb: _asString(firstMap['thumb']),
            ),
          );
        }
      }
    }
    return ChaoxingVideoQuiz(questions: questions, events: events);
  }
}

/// The verdict of `question/quiz-validation`.
class ChaoxingQuizValidation {
  /// Creates a quiz validation verdict.
  const ChaoxingQuizValidation({
    required this.isRight,
    this.status = false,
    this.msg = '',
    this.rightAnswerCount = 0,
    this.rightContent = '',
    this.showAnswer = 0,
    this.percent = 0,
    this.testAnalysis = '',
  });

  /// `isRight` — whether the submitted answer was correct.
  final bool isRight;

  /// `status` — the server accepted the request.
  final bool status;

  /// `msg` — 通过 (pass) or the failure reason.
  final String msg;

  /// `rightAnswerCount` — cumulative correct count so far.
  final int rightAnswerCount;

  /// `rightContent` — the correct answer (e.g. `A`), shown when [showAnswer].
  final String rightContent;

  /// `showAnswer` — 1 = the teacher allows showing the answer after submit.
  final int showAnswer;

  /// `percent` — 100.0 on a correct answer.
  final double percent;

  /// `testAnalysis` — optional explanation.
  final String testAnalysis;

  /// Parses the `quiz-validation` JSON; null on a non-map payload.
  static ChaoxingQuizValidation? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<String, dynamic>();
    return ChaoxingQuizValidation(
      isRight: map['isRight'] == true,
      status: map['status'] == true,
      msg: _asString(map['msg']),
      rightAnswerCount: _asInt(map['rightAnswerCount']),
      rightContent: _asString(map['rightContent']),
      showAnswer: _asInt(map['showAnswer']),
      percent: _asDouble(map['percent']),
      testAnalysis: _asString(map['testAnalysis']),
    );
  }
}

// =====================================================================
// Progress reporting — `CourseViewModel.m76797S`
// (`player/course/viewmodel/CourseViewModel.java:534-564`)
// =====================================================================

/// The `isdrag` wire values — ordinals of `CommiteProgressType`
/// (`player/course/model/CommiteProgressType.java`).
enum ChaoxingVideoProgressType {
  /// Periodic heartbeat while playing (`CoursePlayerFragment.m76429ia`).
  playing,

  /// After a seek; `playingTime` becomes `from-to` seconds.
  drag,

  /// Playback paused or the player backgrounded.
  pause,

  /// Playback (re)started.
  start,

  /// Watched to the end (`CoursePlayerFragment:576`).
  complete,
}

/// Builder for one multimedia-log report GET.
///
/// Query template `InterfaceC19424a.f74485a` (`model/InterfaceC19424a.java:21`,
/// the runtime-dump variant that also carries `rt`), `enc` recipe
/// `CourseViewModel.java:563`. The mobile salt `d_yHJ!$pdA~5` is *not* the H5
/// player's `d_yHJW$XHF_4SmmD_2M9`+dtoken scheme; the two must not be mixed.
abstract final class ChaoxingVideoReport {
  /// The mobile-client `enc` salt (`CourseViewModel.java:563`).
  static const encSalt = 'd_yHJ!\$pdA~5';

  /// The `clipTime` parameter: the teacher's clip window, else `0_duration`
  /// (`CourseViewModel.java:555-560`).
  static String clipTimeOf(ChaoxingCourseVideo video) {
    if (video.vbeginSeconds < 0 || video.vendSeconds <= 0) {
      return '0_${video.durationSeconds}';
    }
    return '${video.vbeginSeconds}_${video.vendSeconds}';
  }

  /// The `playingTime` parameter: plain seconds, or `from-to` for a drag
  /// (`CourseViewModel.java:551-554`).
  static String playingTimeOf(
    ChaoxingVideoProgressType type,
    int progressMillis,
    int startDragTimeMillis,
  ) {
    final sec = progressMillis < 0 ? 0 : progressMillis ~/ 1000;
    if (type != ChaoxingVideoProgressType.drag) return '$sec';
    final from = startDragTimeMillis < 0 ? 0 : startDragTimeMillis ~/ 1000;
    return '$from-$sec';
  }

  /// The `enc` digest — `md5("[clazzId][uid][jobid][objectid]
  /// [playingTimeSec*1000][salt][durationSec*1000][clipTime]")`
  /// (`CourseViewModel.java:563`, MD5 via `u00/C37361j.m154966d`).
  static String computeEnc({
    required String clazzId,
    required String puid,
    required String jobId,
    required String objectId,
    required int playingTimeSeconds,
    required int durationSeconds,
    required String clipTime,
  }) {
    return ChaoxingSignCrypto.md5Hex(
      '[$clazzId][$puid][$jobId][$objectId]'
      '[${playingTimeSeconds * 1000}][$encSalt]'
      '[${durationSeconds * 1000}][$clipTime]',
    );
  }

  /// Builds the full report GET uri: `reportUrl` + the official query
  /// (`CourseViewModel.java:563` + `InterfaceC19424a.java:21`).
  ///
  /// Returns null when [video] carries no [ChaoxingCourseVideo.reportUrl].
  static Uri? buildUri({
    required ChaoxingCourseVideo video,
    required String puid,
    required int progressMillis,
    required ChaoxingVideoProgressType type,
    int startDragTimeMillis = 0,
  }) {
    final base = video.reportUrl.trim();
    if (base.isEmpty) return null;
    final progressSec = progressMillis < 0 ? 0 : progressMillis ~/ 1000;
    final clipTime = clipTimeOf(video);
    final enc = computeEnc(
      clazzId: video.clazzId,
      puid: puid,
      jobId: video.jobId,
      objectId: video.objectId,
      playingTimeSeconds: progressSec,
      durationSeconds: video.durationSeconds,
      clipTime: clipTime,
    );
    final uri = Uri.parse(base);
    return uri.replace(
      queryParameters: {
        ...uri.queryParameters,
        'otherInfo': video.otherInfo,
        'playingTime': playingTimeOf(type, progressMillis, startDragTimeMillis),
        'duration': '${video.durationSeconds}',
        'akid': 'null',
        'jobid': video.jobId,
        'clipTime': clipTime,
        'clazzId': video.clazzId,
        'objectId': video.objectId,
        'userid': puid,
        'isdrag': '${type.index}',
        'enc': enc,
        'rt': _formatRt(video.rt),
        'dtype': 'Video',
        // The mobile `view=json` report path is WAF-gated behind the native
        // client's device fingerprint and returns `code=3` without it; the web
        // `view=pc` path accepts the same `enc` digest with no device context
        // (verified live against mooc1.chaoxing.com, 2026-09-27).
        'view': 'pc',
      },
    );
  }

  /// Java `Double.toString` parity for the `rt=%s` slot: whole values keep
  /// their `.0` (`String.format("%s", Double.valueOf(1.0))` → `1.0`).
  static String _formatRt(double rt) {
    if (rt == rt.roundToDouble() && rt.abs() < 1e15) {
      return rt.toStringAsFixed(1);
    }
    return '$rt';
  }
}

// =====================================================================
// Helpers
// =====================================================================

/// Coerces a decoded JSON [value] to a loose map (empty when not a map).
Map<String, dynamic> asLooseMap(dynamic value) =>
    value is Map ? value.cast<String, dynamic>() : const <String, dynamic>{};

/// Reduces a gear payload to a single record map.
///
/// Live gear hosts wrap the record inconsistently — bare map, `[map]`, or
/// `{data:[map]}` / `{data:map}` (measured on `gas/clazz`, 2026-09). Returns
/// [fallback] when [value] carries no record.
Map<String, dynamic> asGearRecord(
  dynamic value, {
  required Map<String, dynamic> fallback,
}) {
  if (value is List) {
    for (final item in value) {
      final record = asGearRecord(item, fallback: const <String, dynamic>{});
      if (record.isNotEmpty) return record;
    }
    return fallback;
  }
  final map = asLooseMap(value);
  if (map.isEmpty) return fallback;
  if (map.length == 1 && map.containsKey('data')) {
    return asGearRecord(map['data'], fallback: fallback);
  }
  return map;
}

/// The gear `knowledge` field arrives either as a bare array or wrapped in
/// another gear object (`{"data":[…]}`) — measured live on `gas/clazz`.
List<dynamic> _asNodeList(dynamic value) {
  var v = value;
  while (v is Map) {
    v = asLooseMap(v)['data'];
  }
  return v is List ? v : const <dynamic>[];
}

String _asString(dynamic value, {String fallback = ''}) {
  if (value == null) return fallback;
  final text = '$value'.trim();
  return text.isEmpty ? fallback : text;
}

int _asInt(dynamic value, {int fallback = 0}) => switch (value) {
  final int n => n,
  final num n => n.toInt(),
  _ => int.tryParse('$value') ?? fallback,
};

double _asDouble(dynamic value) => switch (value) {
  final double d => d,
  final num n => n.toDouble(),
  _ => double.tryParse('$value') ?? 0,
};

/// The wire carries booleans inconsistently: `fastforward` is a JSON string
/// `"true"`/`"false"` in the live `wxcard`/`videoObject` payloads (verified
/// against a capture), while other fields use real booleans or 0/1. Accept all.
bool _asBool(dynamic value) {
  if (value is bool) return value;
  final text = '$value'.trim().toLowerCase();
  return text == 'true' || text == '1';
}
