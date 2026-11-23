import 'dart:convert';

import 'package:charset/charset.dart';
import 'package:dio/dio.dart';

import 'chaoxing_knowledge_models.dart';
import 'chaoxing_models.dart';
import 'chaoxing_sign_crypto.dart';
import 'chaoxing_sign_models.dart';

/// Student-facing 学习通 API surface beyond sign-in: notifications, grades,
/// homework, live classes, course content, and schedule.
///
/// Every endpoint below was recovered from the decompiled 7.0.2 client; inline
/// citations give the exact `file:line`. Two transport flavours exist:
///
/// - **cookie-only**: plain GET/POST with the session cookie jar (majority).
/// - **inf_enc**: query-string signature via [ChaoxingSignCrypto.signedQuery]
///   (notice, kb, learn, specie, groupyd hosts).
///
/// Response envelopes follow the official convention:
/// `{result:1, msg/errorMsg, data|channelList|…}` — `result:1` = success.
class ChaoxingApiService {
  /// Creates the API client, optionally injecting a [dio] and a [userAgent].
  /// Pass [ChaoxingUserAgent.build] to emit the official-format header carrying
  /// the device [uniqueId].
  ChaoxingApiService({Dio? dio, String? userAgent})
    : userAgent = userAgent ?? _defaultUserAgent,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              followRedirects: false,
              validateStatus: (status) => status != null && status < 500,
            ),
          );

  final Dio _dio;

  /// The `User-Agent` header sent on every request.
  final String userAgent;

  // -------------------------------------------------------------------
  // Base URLs — `p616jb/C32348b.java` + `ke/C32761m.java:76-181`
  // -------------------------------------------------------------------

  static const _moocBase = 'https://mooc1-api.chaoxing.com';
  static const _moocWebBase = 'https://mooc1.chaoxing.com';
  static const _learnBase = 'https://mobilelearn.chaoxing.com';
  static const _noticeBase = 'https://notice.chaoxing.com';
  static const _liveBase = 'https://live.chaoxing.com';
  static const _kbBase = 'https://kb.chaoxing.com';
  static const _learnApiBase = 'https://learn.chaoxing.com';
  static const _specieBase = 'https://specie.chaoxing.com';
  static const _fystatBase = 'https://fystat-ans.chaoxing.com';

  static const _defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 9 Pro) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  // ===================================================================
  // 1. Notifications — `com/chaoxing/mobile/notify/InterfaceC18005a.java`
  //    Base: notice.chaoxing.com, signing: inf_enc (`be.s.m4145f`)
  // ===================================================================

  /// `ke/C32761m.java:184` + `InterfaceC18005a.java:220`.
  /// Returns `{result:1, data:{noticeList:[…], totalCount, …}}`.
  Future<ChaoxingNoticeList> fetchNotices(
    ChaoxingSession session, {
    int page = 1,
    int pageSize = 20,
    String type = '',
    String folderId = '',
    String keyword = '',
  }) async {
    _requireSession(session);
    final names = [
      'puid',
      'lastGetId',
      'type',
      'notice_type',
      'from',
      'folderId',
      'read',
      'kw',
      'tag',
      'pageSize',
      'page',
      'mMaxW',
      'contSize',
    ];
    final values = [
      session.puid,
      '',
      type,
      '',
      '',
      folderId,
      '',
      keyword,
      '',
      pageSize.toString(),
      page.toString(),
      '',
      '',
    ];
    final signed = ChaoxingSignCrypto.signedQuery(
      names,
      values,
      timeMillis: DateTime.now().millisecondsSinceEpoch,
    );
    final uri = Uri.parse('$_noticeBase/apis/notice/myNotices_v2?$signed');
    final body = await _getJson(session, uri);
    return ChaoxingNoticeList.fromJson(asMap(body));
  }

  /// `ke/C32761m.java:4341`. Unread notice count for the badge.
  Future<int> fetchUnreadNoticeCount(ChaoxingSession session) async {
    _requireSession(session);
    final names = ['puid', 'version', 'sign', 'red_dots'];
    final values = [session.puid, '', '', '1'];
    final signed = ChaoxingSignCrypto.signedQuery(
      names,
      values,
      timeMillis: DateTime.now().millisecondsSinceEpoch,
    );
    final uri = Uri.parse('$_noticeBase/apis/notice/getNoReadCount?$signed');
    final body = asMap(await _getJson(session, uri));
    if (body['result'] != 1) return 0;
    final data = asMap(body['data']);
    return (data['count'] ?? data['noReadCount'] ?? 0) as int? ?? 0;
  }

  /// `InterfaceC18005a.java:182`. Single notice detail.
  Future<Map<String, dynamic>> fetchNoticeDetail(
    ChaoxingSession session, {
    required String noticeId,
    String sid = '',
  }) async {
    _requireSession(session);
    final names = ['id', 'sid', 's_noticeId', 'maxW', 'puid'];
    final values = [noticeId, sid, '', '', session.puid];
    final signed = ChaoxingSignCrypto.signedQuery(
      names,
      values,
      timeMillis: DateTime.now().millisecondsSinceEpoch,
    );
    final uri = Uri.parse('$_noticeBase/apis/notice/getNotice?$signed');
    return asMap(await _getJson(session, uri));
  }

  // ===================================================================
  // 2. Task status / red dots — cookie-only, mooc1-api
  // ===================================================================

  /// `p649kb/C32662a.java:170`. Combined work+exam pending status.
  /// Response: `{result:1, data:{work:{…}, exam:{…}}}` or similar.
  Future<Map<String, dynamic>> fetchTaskStatus(
    ChaoxingSession session, {
    required String classId,
    String qtype = 'work,exam',
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocBase/api/task-status').replace(
      queryParameters: {'classId': classId, 'qtype': qtype, 'view': 'json'},
    );
    return asMap(await _getJson(session, uri));
  }

  /// `p985wg/InterfaceC37958c.java:61`. Red-dot badge count for new work/exam.
  /// Response: `{result:1, msg, data:{redpoint:int}}`.
  Future<int> fetchWorkExamRedPoint(
    ChaoxingSession session, {
    required String courseId,
    required String classId,
    String cpi = '',
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocBase/api/workexam/redpoint').replace(
      queryParameters: {'courseId': courseId, 'classId': classId, 'cpi': cpi},
    );
    final body = asMap(await _getJson(session, uri));
    if (body['result'] != 1) return 0;
    return (asMap(body['data'])['redpoint'] ?? 0) as int? ?? 0;
  }

  // ===================================================================
  // 3. Grades / scores — cookie-only, mooc1-api
  // ===================================================================

  /// `p985wg/C37957b.java:80`. Student's own score breakdown (JSON/H5).
  Future<Map<String, dynamic>> fetchSelfScoreDetail(
    ChaoxingSession session, {
    required String classId,
    required String courseId,
    String cpi = '',
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocBase/phone/moocanalysis/selfscoredetail')
        .replace(
          queryParameters: {
            'classId': classId,
            'courseId': courseId,
            'cpi': cpi,
          },
        );
    return asMap(await _getJson(session, uri));
  }

  /// `p649kb/C32662a.java:778`. Exam list for a course, parsed from the
  /// `examList` H5 page. The native JSON feed (`gas/taskmsg`) is WAF-blocked
  /// off the official app's network, so the cookie-authed HTML page — the same
  /// one the client's own WebView loads — is the reliable source.
  Future<List<ChaoxingCourseTask>> fetchExamList(
    ChaoxingSession session, {
    required String courseId,
    required String classId,
  }) async {
    _requireSession(session);
    final uri = Uri.parse(
      '$_moocBase/phone/moocAnalysis/examList',
    ).replace(queryParameters: {'courseId': courseId, 'classId': classId});
    return parseExamList(await _getText(session, uri), base: _moocBase);
  }

  /// `p649kb/C32662a.java:803`. Homework list for a course, parsed from the
  /// `workList` H5 page. See [fetchExamList] for why this is HTML, not JSON.
  Future<List<ChaoxingCourseTask>> fetchWorkList(
    ChaoxingSession session, {
    required String courseId,
    required String classId,
  }) async {
    _requireSession(session);
    final uri = Uri.parse(
      '$_moocBase/phone/moocAnalysis/workList',
    ).replace(queryParameters: {'courseId': courseId, 'classId': classId});
    return parseWorkList(await _getText(session, uri), base: _moocBase);
  }

  /// Homework + exams for one course/class, merged (homework first). Each
  /// source is best-effort: if one page fails or is WAF-blocked, the other still
  /// comes back, so a course never loses its whole task list to one bad call.
  Future<List<ChaoxingCourseTask>> fetchCourseTasks(
    ChaoxingSession session, {
    required String courseId,
    required String classId,
  }) async {
    final work = await fetchWorkList(
      session,
      courseId: courseId,
      classId: classId,
    ).catchError((_) => const <ChaoxingCourseTask>[]);
    final exam = await fetchExamList(
      session,
      courseId: courseId,
      classId: classId,
    ).catchError((_) => const <ChaoxingCourseTask>[]);
    return [...work, ...exam];
  }

  /// Parses the `workList` H5 page. Each row is a
  /// `<dt data="<do-task path>" status="n"><h3>title</h3><p>date</p>…<b>action</b>`.
  /// [base] is prepended to the relative `data` path to form an absolute URL.
  static List<ChaoxingCourseTask> parseWorkList(String html, {String base = ''}) {
    final tasks = <ChaoxingCourseTask>[];
    for (final m in RegExp(r'<dt\b[^>]*>(.*?)</dt>', dotAll: true).allMatches(html)) {
      final tag = m.group(0)!;
      final inner = m.group(1)!;
      final data = _htmlAttr(tag, 'data');
      if (data == null || data.isEmpty) continue;
      tasks.add(
        ChaoxingCourseTask(
          title: _cleanText(_innerTag(inner, 'h3')),
          url: _absoluteUrl(base, data),
          type: ChaoxingCourseTask.work,
          statusText: _cleanText(_innerTag(inner, 'b')),
          detail: _cleanText(_innerTag(inner, 'p')),
          status: int.tryParse(_htmlAttr(tag, 'status') ?? '') ?? 0,
        ),
      );
    }
    return tasks;
  }

  /// Parses the `examList` H5 page. Each row is a
  /// `<tr data="<do-task path>" title="…" status="n">` followed by
  /// `<td>`cells: title, score, status text. The header `<tr>` has no `data`
  /// attribute and is skipped.
  static List<ChaoxingCourseTask> parseExamList(String html, {String base = ''}) {
    final tasks = <ChaoxingCourseTask>[];
    final rowRe = RegExp(r'<tr\b[^>]*\bdata="[^"]*"[^>]*>(.*?)</tr>', dotAll: true);
    for (final m in rowRe.allMatches(html)) {
      final tag = m.group(0)!;
      final inner = m.group(1)!;
      final data = _htmlAttr(tag, 'data');
      if (data == null || data.isEmpty) continue;
      final cells = [
        for (final td in RegExp(r'<td\b[^>]*>(.*?)</td>', dotAll: true).allMatches(inner))
          _cleanText(td.group(1)!),
      ];
      var title = _decodeEntities(_htmlAttr(tag, 'title') ?? '');
      if (title.isEmpty && cells.isNotEmpty) title = cells[0];
      tasks.add(
        ChaoxingCourseTask(
          title: title,
          url: _absoluteUrl(base, data),
          type: ChaoxingCourseTask.exam,
          statusText: cells.length > 2 ? cells[2] : '',
          detail: cells.length > 1 ? cells[1] : '',
          status: int.tryParse(_htmlAttr(tag, 'status') ?? '') ?? 0,
        ),
      );
    }
    return tasks;
  }

  static String? _htmlAttr(String tag, String name) {
    final m = RegExp('$name="([^"]*)"').firstMatch(tag);
    return m == null ? null : _decodeEntities(m.group(1)!);
  }

  static String _innerTag(String html, String tag) =>
      RegExp('<$tag\\b[^>]*>(.*?)</$tag>', dotAll: true)
          .firstMatch(html)
          ?.group(1) ??
      '';

  static String _cleanText(String s) => _decodeEntities(
    s.replaceAll(RegExp(r'<[^>]+>'), ''),
  ).replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _decodeEntities(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ');

  static String _absoluteUrl(String base, String path) {
    final p = path.trim();
    if (p.startsWith('http://') || p.startsWith('https://')) return p;
    if (base.isEmpty) return p;
    return '$base${p.startsWith('/') ? '' : '/'}$p';
  }

  /// `p649kb/C32662a.java:733` + `p985wg/InterfaceC37959d.java:101`.
  /// Student course-progress and grade detail page data.
  Future<Map<String, dynamic>> fetchCourseDetailStd(
    ChaoxingSession session, {
    required String courseId,
    required String classId,
    String cpi = '',
  }) async {
    _requireSession(session);
    final uri =
        Uri.parse(
          '$_moocBase/phone/moocAnalysis/coursedetails-std-client',
        ).replace(
          queryParameters: {
            'courseId': courseId,
            'classId': classId,
            'cpi': cpi,
            'view': 'json',
          },
        );
    return asMap(await _getJson(session, uri));
  }

  /// `p684lo/InterfaceC34105d.java:314`. Score weight configuration.
  Future<Map<String, dynamic>> fetchScoreWeights(
    ChaoxingSession session, {
    required String classId,
    required String courseId,
  }) async {
    _requireSession(session);
    final uri = Uri.parse(
      '$_learnBase/scoreAnalysis/phone/getweights',
    ).replace(queryParameters: {'classId': classId, 'courseId': courseId});
    return asMap(await _getJson(session, uri));
  }

  // ===================================================================
  // 4. Homework / task feed — cookie-only, mooc1-api
  // ===================================================================

  /// `p649kb/C32662a.java:713,738`. **Native HW/exam feed** — the richest
  /// task list in the client. Each item carries `dotaskurl` (the do-homework
  /// URL), `title`, `coursename`, `taskopentime`, `taskendtime`, `status`,
  /// `type` (work/exam), `finishstandard`.
  ///
  /// GAS query DSL: `fields` selects the columns; `order=time` sorts by
  /// creation time descending.
  Future<List<ChaoxingTaskItem>> fetchTaskFeed(
    ChaoxingSession session, {
    required String userid,
    String type = '',
    int limit = 20,
    int offset = 0,
    String order = 'time',
    String orderway = 'desc',
  }) async {
    _requireSession(session);
    const fields =
        'id,userid,taskrefid,classid,courseid,taskcreatetime,taskopentime,'
        'taskendtime,status,type,coursename,coursecover,title,dotaskurl,'
        'clientexam,finishstandard';
    final uri = Uri.parse('$_moocBase/gas/taskmsg').replace(
      queryParameters: {
        'id': '',
        'userid': userid,
        'type': type,
        'limit': limit.toString(),
        'offset': offset.toString(),
        'order': order,
        'orderway': orderway,
        'fields': fields,
        'view': 'json',
      },
    );
    final body = asMap(await _getJson(session, uri));
    if (body['result'] != 1) return const [];
    final list = body['data'];
    if (list is! List) return const [];
    return [
      for (final item in list)
        if (item is Map)
          ChaoxingTaskItem.fromJson(item.cast<String, dynamic>()),
    ];
  }

  /// `p649kb/C32662a.java:595`. Unfinished jobs in a knowledge point.
  Future<Map<String, dynamic>> fetchUnfinishedJobs(
    ChaoxingSession session, {
    required String courseid,
    required String clazzid,
    String knowledgeid = '',
    String jobid = '',
    int page = 1,
    int pageSize = 20,
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocBase/api/phone/jobunfinishedList').replace(
      queryParameters: {
        'courseid': courseid,
        'clazzid': clazzid,
        'knowledgeid': knowledgeid,
        'jobid': jobid,
        'page': page.toString(),
        'pageSize': pageSize.toString(),
        'view': 'json',
      },
    );
    return asMap(await _getJson(session, uri));
  }

  /// `p649kb/C32662a.java:330`. Finished jobs.
  Future<Map<String, dynamic>> fetchFinishedJobs(
    ChaoxingSession session, {
    required String courseid,
    required String clazzid,
    String knowledgeid = '',
    String jobid = '',
    int page = 1,
    int pageSize = 20,
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocBase/api/phone/jobfinishedList').replace(
      queryParameters: {
        'courseid': courseid,
        'clazzid': clazzid,
        'knowledgeid': knowledgeid,
        'jobid': jobid,
        'page': page.toString(),
        'pageSize': pageSize.toString(),
        'view': 'json',
      },
    );
    return asMap(await _getJson(session, uri));
  }

  // ===================================================================
  // 5. Live class — cookie-only, live.chaoxing.com
  //    `p654kk/InterfaceC32797a.java`
  // ===================================================================

  /// `InterfaceC32797a.java:75` + `ke/C32761m.java:3882`.
  /// Returns live status JSON (`{status, title, …}`).
  Future<Map<String, dynamic>> fetchLiveStatus(
    ChaoxingSession session, {
    required String streamName,
    String vdoid = '',
  }) async {
    _requireSession(session);
    final uri = Uri.parse(
      '$_liveBase/liveAPI/getlivestatus',
    ).replace(queryParameters: {'streamName': streamName, 'vdoid': vdoid});
    return asMap(await _getJson(session, uri));
  }

  /// `InterfaceC32797a.java:87` + `ke/C32761m.java:4300`.
  /// Full live detail including stream URLs (flv/hls/rtmp).
  Future<Map<String, dynamic>> fetchLiveDetail(
    ChaoxingSession session, {
    required String streamName,
    String vdoid = '',
  }) async {
    _requireSession(session);
    final uri = Uri.parse(
      '$_liveBase/liveAPI/newLiveDetail',
    ).replace(queryParameters: {'streamName': streamName, 'vdoid': vdoid});
    return asMap(await _getJson(session, uri));
  }

  /// `p684lo/InterfaceC34105d.java:172` + `ke/C32761m.java:727`.
  /// Whether any live class is currently ongoing (banner trigger).
  Future<Map<String, dynamic>> fetchOngoingLive(ChaoxingSession session) async {
    _requireSession(session);
    final uri = Uri.parse(
      '$_learnBase/apis/live/whetherExistNoClassRoomLiving',
    );
    return asMap(await _getJson(session, uri));
  }

  /// `ke/C32761m.java:337` + `af/InterfaceC0147a.java:95`.
  /// All live rooms for a chat group.
  Future<Map<String, dynamic>> fetchLivesByChatId(
    ChaoxingSession session, {
    required String chatId,
  }) async {
    _requireSession(session);
    final uri = Uri.parse(
      '$_liveBase/liveAPI/allLivingByChatId',
    ).replace(queryParameters: {'chatId': chatId});
    return asMap(await _getJson(session, uri));
  }

  // ===================================================================
  // 6. Course content — cookie-only, mooc1-api
  // ===================================================================

  /// `p649kb/C32662a.java:683`. Chapter tree (catalog) for a course.
  /// `ut=s` for student, `ut=t` for teacher.
  Future<Map<String, dynamic>> fetchChapterTree(
    ChaoxingSession session, {
    required String courseId,
    String classId = '',
    String ut = 's',
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocBase/phone/data').replace(
      queryParameters: {
        'courseId': courseId,
        if (classId.isNotEmpty) 'classId': classId,
        'ut': ut,
      },
    );
    return asMap(await _getJson(session, uri));
  }

  /// `p649kb/C32662a.java:102,641`. Knowledge-point cards (attachments,
  /// jobs, videos inside a chapter node).
  Future<Map<String, dynamic>> fetchKnowledgeCards(
    ChaoxingSession session, {
    required String clazzid,
    required String courseid,
    required String knowledgeid,
    String num = '',
    String cpi = '',
    int isPhone = 1,
    String control = '',
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocBase/knowledge/cards').replace(
      queryParameters: {
        'clazzid': clazzid,
        'courseid': courseid,
        'knowledgeid': knowledgeid,
        'num': num,
        'isPhone': isPhone.toString(),
        'control': control,
        'cpi': cpi,
      },
    );
    return asMap(await _getJson(session, uri));
  }

  /// `ke/C32761m.java:602`. Semester list for the course picker.
  Future<Map<String, dynamic>> fetchSemesterList(
    ChaoxingSession session,
  ) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocBase/mycourse/getsemesterlist');
    return asMap(await _getJson(session, uri));
  }

  /// `p649kb/C32662a.java:615,698`. GAS class detail (bbsid, chatid, score…).
  Future<Map<String, dynamic>> fetchClassDetail(
    ChaoxingSession session, {
    required String classId,
  }) async {
    _requireSession(session);
    const fields =
        'id,bbsid,classscore,isstart,chatid,name,state,isfiled,'
        'course.fields(id,name,imageurl,teacherfactor,fid)';
    final uri = Uri.parse('$_moocBase/gas/clazz').replace(
      queryParameters: {'id': classId, 'fields': fields, 'view': 'json'},
    );
    return asMap(await _getJson(session, uri));
  }

  /// `p684lo/C34104c.java:20,25`. GAS course detail with clazz sub-fields.
  Future<Map<String, dynamic>> fetchCourseDetail(
    ChaoxingSession session, {
    required String courseId,
    required String userid,
    String personid = '',
  }) async {
    _requireSession(session);
    const fields =
        'role,personid,bbsid,isteacher,knowledge.fields(id,name,createtime),'
        'clazz.fields(id,name,chatid,bbsid,studentcount,invitecode)';
    final uri = Uri.parse('$_moocBase/gas/course').replace(
      queryParameters: {
        'id': courseId,
        'userid': userid,
        'personid': personid,
        'fields': fields,
        'isteachcourse': 'true',
        'view': 'json',
      },
    );
    return asMap(await _getJson(session, uri));
  }

  // ===================================================================
  // 6b. Chapters / knowledge points / video study — cookie-only,
  //     mooc1-api. Chapter tree: student gear call of
  //     `img6 defpackage/fii.java:44-56`; card page URL:
  //     `p649kb/C32662a.java:639-644`; video blob:
  //     `player/course/model/InterfaceC19424a.java:55-57`; progress log:
  //     `player/course/viewmodel/CourseViewModel.java:534-564`.
  // ===================================================================

  /// The `gas/clazz` gear `fields` the official student chapter list requests
  /// (`fii.java:56`): clazz header + course + every node with its per-user
  /// study state, `card` stubs excluded (fetched per node by
  /// [fetchKnowledgeNode]).
  static const chapterFields =
      'id,name,state,isstart,isfiled,chatid,bbsid,studentcount,invitecode,'
      'course.fields(id,name,bbsid,imageurl,teacherfactor,mappingcourseid,'
      'bulletformat,knowledge.fields(id,name,indexOrder,optype,parentnodeid,'
      'label,layer,status,begintime,endtime,clickcount,finishcount,openlock,'
      'unfinishcount,newchapterrule).type(video))';

  /// Fetches a class's whole chapter tree with per-user study state.
  ///
  /// [cpi] is the enrolment's `personid`; the official client omits the
  /// parameter entirely when it is empty (`fii.java:47-52`).
  Future<ChaoxingChapterData> fetchChapterData(
    ChaoxingSession session, {
    required String clazzId,
    String cpi = '',
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocBase/gas/clazz').replace(
      queryParameters: {
        'id': clazzId,
        if (cpi.isNotEmpty) 'personid': cpi,
        'fields': chapterFields,
        'view': 'json',
      },
    );
    final json = asMap(await _getJson(session, uri));
    return ChaoxingChapterData.fromGearJson(json);
  }

  /// One knowledge node with its card list — the `gas/knowledge` gear call of
  /// `fii.java:21-31` (`card.fields(…).contentcard(all)` included so card
  /// titles/types render without opening the H5 page).
  Future<ChaoxingKnowledgeNode?> fetchKnowledgeNode(
    ChaoxingSession session, {
    required String knowledgeId,
    required String courseId,
  }) async {
    _requireSession(session);
    const fields =
        'id,optype,parentnodeid,indexorder,label,layer,name,begintime,'
        'createtime,lastmodifytime,status,jobUnfinishedCount,clickcount,'
        'openlock,card.fields(id,knowledgeid,title,knowledgeTitile,'
        'description,cardorder,usetp).contentcard(all)';
    final uri = Uri.parse('$_moocBase/gas/knowledge').replace(
      queryParameters: {
        'id': knowledgeId,
        'courseid': courseId,
        'fields': fields,
        'view': 'json',
      },
    );
    final json = asMap(await _getJson(session, uri));
    final data = asGearRecord(json['data'] ?? json['msg'], fallback: json);
    if (data.isEmpty || !data.containsKey('id')) return null;
    return ChaoxingKnowledgeNode.fromJson(data);
  }

  /// Per-user 任务点 state refresh for [nodeIds] (comma-joined on the wire) —
  /// `job/myjobsnodesmap`, `p477eb/C30065g.m120462c` +
  /// `p477eb/InterfaceC30059a.java:42-45` (POST, form-encoded, cookie-only).
  Future<List<ChaoxingKnowledgeNode>> fetchNodeJobStatus(
    ChaoxingSession session, {
    required Iterable<String> nodeIds,
    required String clazzId,
    required String courseId,
    String cpi = '',
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocBase/job/myjobsnodesmap');
    final body = await _postFormPlain(session, uri, {
      'nodes': nodeIds.join(','),
      if (cpi.isNotEmpty) 'cpi': cpi,
      'userid': session.puid,
      'clazzid': clazzId,
      'courseid': courseId,
      'view': 'json',
    });
    final json = asMap(body);
    final raw = json['data'] ?? json['msg'] ?? json;
    // Live shape: an object keyed by node id (`{"<id>":{unfinishcount,…}}`);
    // older captures used a list of node maps.
    if (raw is Map) {
      return [
        for (final entry in raw.entries)
          if (entry.value is Map)
            ChaoxingKnowledgeNode.fromJson(<String, dynamic>{
              'id': '${entry.key}',
              ...asLooseMap(entry.value),
            }),
      ];
    }
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) ChaoxingKnowledgeNode.fromJson(item.cast<String, dynamic>()),
    ];
  }

  /// The video blob for a card, exactly what the H5 card page hands the
  /// official native player — `knowledge/getnextknowledgevideo`
  /// (`InterfaceC19424a.java:55-57`). Null when the node/card has no video.
  Future<ChaoxingCourseVideo?> fetchKnowledgeVideo(
    ChaoxingSession session, {
    required String clazzId,
    required String courseId,
    required String knowledgeId,
    String cardId = '',
    String cpi = '',
    String attachmentId = '',
    String fallbackTitle = '',
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocBase/knowledge/getnextknowledgevideo').replace(
      queryParameters: {
        'clazzId': clazzId,
        'courseId': courseId,
        'knowledgeId': knowledgeId,
        'cardId': cardId,
        'cpi': cpi,
        'attachmentId': attachmentId,
        'isPhone': '1',
      },
    );
    final json = asMap(await _getJson(session, uri));
    final data = asMap(json['data'] ?? json['msg']);
    final blob = data['videoObject'];
    final blobJson = switch (blob) {
      final String s => s,
      final Map m => jsonEncode(m),
      _ => '',
    };
    if (blobJson.isEmpty) return null;
    return ChaoxingCourseVideo.tryParse(blobJson, fallbackTitle: fallbackTitle);
  }

  /// The video blob for one specific `mid` — `knowledge/getknowledgecurvideo`
  /// (`InterfaceC19424a.m76706e`, POST, form-encoded). Unlike
  /// [fetchKnowledgeVideo] (the "next video" iterator), this resolves a single
  /// attachment by its media id, which is how a multi-video card is played
  /// non-sequentially. Null when the node/card has no video.
  Future<ChaoxingCourseVideo?> fetchKnowledgeCurVideo(
    ChaoxingSession session, {
    required String clazzId,
    required String courseId,
    required String knowledgeId,
    required String mid,
    String cpi = '',
    String fallbackTitle = '',
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocBase/knowledge/getknowledgecurvideo');
    final body = await _postFormPlain(session, uri, {
      'courseid': courseId,
      'clazzid': clazzId,
      'knowledgeid': knowledgeId,
      if (cpi.isNotEmpty) 'cpi': cpi,
      'mid': mid,
    });
    final json = asMap(body);
    final data = asMap(json['data'] ?? json['msg']);
    final blob = data['videoObject'];
    final blobJson = switch (blob) {
      final String s => s,
      final Map m => jsonEncode(m),
      _ => '',
    };
    if (blobJson.isEmpty) return null;
    return ChaoxingCourseVideo.tryParse(blobJson, fallbackTitle: fallbackTitle);
  }

  /// The pop-quiz/annotation/image/PPT events of one video —
  /// `richvideo/initdatawithviewerV2` (GET, cookie-only, `mooc1.chaoxing.com`).
  Future<ChaoxingVideoQuiz> fetchVideoQuiz(
    ChaoxingSession session, {
    required String mid,
    required String clazzId,
    required String courseId,
    String cpi = '',
  }) async {
    _requireSession(session);
    final uri = Uri.parse(
      '$_moocWebBase/mooc-ans/richvideo/initdatawithviewerV2',
    ).replace(
      queryParameters: {
        'mid': mid,
        'classid': clazzId,
        'courseid': courseId,
        if (cpi.isNotEmpty) 'cpi': cpi,
      },
    );
    return ChaoxingVideoQuiz.parse(await _getJsonGbk(session, uri));
  }

  /// Validates one pop-quiz answer — `question/quiz-validation` (GET).
  /// [answerContent] is the option key (`A`) or a comma list (`A,B,C`).
  Future<ChaoxingQuizValidation?> validateQuizAnswer(
    ChaoxingSession session, {
    required String clazzId,
    required String cpi,
    required String objectId,
    required int eventId,
    required String memberinfo,
    required String answerContent,
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocWebBase/mooc-ans/question/quiz-validation')
        .replace(
          queryParameters: {
            'classid': clazzId,
            'cpi': cpi,
            'objectid': objectId,
            'eventid': '$eventId',
            'memberinfo': memberinfo,
            'answerContent': answerContent,
          },
        );
    return ChaoxingQuizValidation.tryParse(await _getJsonGbk(session, uri));
  }

  /// The running correct-answer count for a question — `question/quiz-rightcount`
  /// (GET). Called before the question is answered.
  Future<int> fetchQuizRightCount(
    ChaoxingSession session, {
    required String clazzId,
    required String cpi,
    required int eventId,
    required String memberinfo,
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocWebBase/mooc-ans/question/quiz-rightcount')
        .replace(
          queryParameters: {
            'classid': clazzId,
            'cpi': cpi,
            'eventid': '$eventId',
            'memberinfo': memberinfo,
          },
        );
    final json = asMap(await _getJsonGbk(session, uri));
    final count = json['rightAnswerCount'];
    return count is num ? count.toInt() : (int.tryParse('$count') ?? 0);
  }

  /// The PDF status for one ananas object — `ananas/status/<objectid>` (the
  /// same endpoint the H5 PDF viewer reads). The returned `pdf` URL is served
  /// by the document CDN anonymously (no cookie needed).
  Future<ChaoxingPdfStatus?> fetchPdfStatus(
    ChaoxingSession session, {
    required String objectId,
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocWebBase/ananas/status/$objectId');
    final json = asMap(await _getJson(session, uri));
    return ChaoxingPdfStatus.tryParse(json);
  }

  /// The completion identities of every attachment of one card, parsed from the
  /// H5 card page's `wxcard` response (`window.AttachmentSetting`). Each entry
  /// carries the `jtoken` the document-read report requires.
  Future<List<ChaoxingDocumentJob>> fetchDocumentJobs(
    ChaoxingSession session, {
    required String cardId,
    required String courseId,
    required String clazzId,
    required String knowledgeId,
    String cpi = '',
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocWebBase/mooc-ans/phone/wxcard').replace(
      queryParameters: {
        'cardid': cardId,
        'courseid': courseId,
        'knowledgeid': knowledgeId,
        'clazzid': clazzId,
        if (cpi.isNotEmpty) 'cpi': cpi,
        'ut': 's',
        'isMicroCourse': 'false',
      },
    );
    final text = await _getText(session, uri);
    final setting = _parseAttachmentSetting(text);
    final raw = setting?['attachments'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          ChaoxingDocumentJob(
            jobId: '${asMap(item)['jobid'] ?? ''}',
            jtoken: '${asMap(item)['jtoken'] ?? ''}',
            objectId: '${asMap(asMap(item)['property'])['objectid'] ?? ''}',
            type: '${asMap(item)['type'] ?? ''}',
          ),
    ];
  }

  /// Marks one document 任务点 read — `mooc-ans/job/document` (the H5 PDF
  /// viewer's completion ping). Returns true when the server accepted it.
  Future<bool> reportDocumentRead(
    ChaoxingSession session, {
    required String jobId,
    required String jtoken,
    required String knowledgeId,
    required String courseId,
    required String clazzId,
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocWebBase/mooc-ans/job/document').replace(
      queryParameters: {
        'jobid': jobId,
        'knowledgeid': knowledgeId,
        'courseid': courseId,
        'clazzid': clazzId,
        'jtoken': jtoken,
        'checkMicroTopic': 'true',
        'microTopicId': 'undefined',
        'courseEngineInfo': 'false',
      },
    );
    final json = asMap(await _getJson(session, uri));
    return json['status'] == true;
  }

  /// Extracts the `window.AttachmentSetting = {…}` JSON object out of a
  /// `wxcard` HTML response, or null when it is absent.
  Map<String, dynamic>? _parseAttachmentSetting(String html) {
    const marker = 'window.AttachmentSetting';
    final start = html.indexOf(marker);
    if (start < 0) return null;
    final eq = html.indexOf('=', start);
    if (eq < 0) return null;
    final brace = html.indexOf('{', eq);
    if (brace < 0) return null;
    // The JSON is emitted on a single line and closed with `};`.
    final semi = html.indexOf(';', brace);
    if (semi < 0) return null;
    try {
      final decoded = jsonDecode(html.substring(brace, semi));
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } on FormatException {
      return null;
    }
  }

  /// Sends one video progress report (heartbeat, drag, pause, start, complete)
  /// and returns the server's JSON answer — `CourseViewModel.m76797S` +
  /// `C19425b.m76716g` (plain GET on [ChaoxingCourseVideo.reportUrl]).
  ///
  /// The caller decides dedupe policy; the official client skips a report
  /// whose (playingTime-seconds, type) pair equals the previous one
  /// (`CourseViewModel.java:546-550`). Returns an empty map when the video
  /// carries no reportUrl.
  Future<Map<String, dynamic>> reportVideoProgress(
    ChaoxingSession session, {
    required ChaoxingCourseVideo video,
    required int progressMillis,
    required ChaoxingVideoProgressType type,
    int startDragTimeMillis = 0,
  }) async {
    _requireSession(session);
    final uri = ChaoxingVideoReport.buildUri(
      video: video,
      puid: session.puid,
      progressMillis: progressMillis,
      type: type,
      startDragTimeMillis: startDragTimeMillis,
    );
    if (uri == null) return const {};
    return asMap(await _getJson(session, uri));
  }

  /// Builds the official H5 card-page URL the WebView opens for one knowledge
  /// node — `p649kb/C32662a.m128670Y0` (`C32662a.java:639-644`), H5 base
  /// `mooc1.chaoxing.com`. Pure builder: no session, no network.
  static String buildKnowledgeCardPageUrl({
    required String clazzId,
    required String courseId,
    required String knowledgeId,
    int num = 0,
    String cpi = '',
    String control = '',
    int pageState = 0,
  }) {
    final params = <String, String>{
      'clazzid': clazzId,
      'courseid': courseId,
      'knowledgeid': knowledgeId,
      'num': '$num',
      'isPhone': '1',
      'control': control,
      'cpi': cpi,
      'pagestate': '$pageState',
      'isMicroCourse': 'false',
    };
    return Uri.parse(
      'https://mooc1.chaoxing.com/knowledge/cards',
    ).replace(queryParameters: params).toString();
  }

  // ===================================================================
  // 7. Schedule / timetable — inf_enc, kb.chaoxing.com
  //    `gh/InterfaceC30809b.java`
  // ===================================================================

  /// `InterfaceC30809b.java:57`. Fetch a lesson entry from the timetable.
  /// Response: `TMsg<Curriculum>` → `{result:1, data:{…}}`.
  Future<Map<String, dynamic>> fetchLesson(
    ChaoxingSession session, {
    required String lessonConfigUuid,
    String lessonId = '',
    String curriculumId = '',
  }) async {
    _requireSession(session);
    final names = ['puid', 'lessonConfigUuid', 'lessonId', 'curriculumId'];
    final values = [session.puid, lessonConfigUuid, lessonId, curriculumId];
    final signed = ChaoxingSignCrypto.signedQuery(
      names,
      values,
      timeMillis: DateTime.now().millisecondsSinceEpoch,
    );
    final uri = Uri.parse('$_kbBase/apis/curriculum/getLesson?$signed');
    return asMap(await _getJson(session, uri));
  }

  /// `InterfaceC30809b.java:40`. Whether a live-class room is active for a
  /// scheduled lesson.
  Future<Map<String, dynamic>> fetchZhiboktStatus(
    ChaoxingSession session, {
    required String lessonConfigUuid,
    required String lessonId,
    required String curriculumId,
  }) async {
    _requireSession(session);
    final names = ['lessonConfigUuid', 'lessonId', 'curriculumId'];
    final values = [lessonConfigUuid, lessonId, curriculumId];
    final signed = ChaoxingSignCrypto.signedQuery(
      names,
      values,
      timeMillis: DateTime.now().millisecondsSinceEpoch,
    );
    final uri = Uri.parse('$_kbBase/apis/curriculum/getZhiboktStatus?$signed');
    return asMap(await _getJson(session, uri));
  }

  // ===================================================================
  // 8. Messages / interactions — inf_enc
  // ===================================================================

  /// `af/InterfaceC0147a.java:175`. Message category list (species).
  /// Response: `TDataList<MessageSpecies>`.
  Future<Map<String, dynamic>> fetchMessageSpecies(
    ChaoxingSession session,
  ) async {
    _requireSession(session);
    final names = ['puid', 'sign', 'version', 'fid'];
    final values = [session.puid, '', '', session.fid];
    final signed = ChaoxingSignCrypto.signedQuery(
      names,
      values,
      timeMillis: DateTime.now().millisecondsSinceEpoch,
    );
    final uri = Uri.parse('$_learnApiBase/apis/message/getSpecies');
    return asMap(await _postForm(session, uri, signed));
  }

  /// `ke/C32761m.java:2335`. Unread praise/interaction count.
  Future<int> fetchUnreadPraiseCount(ChaoxingSession session) async {
    _requireSession(session);
    final names = ['puid'];
    final values = [session.puid];
    final signed = ChaoxingSignCrypto.signedQuery(
      names,
      values,
      timeMillis: DateTime.now().millisecondsSinceEpoch,
    );
    final uri = Uri.parse(
      '$_specieBase/apis/message/getUnreadPraiseCount?$signed',
    );
    final body = asMap(await _getJson(session, uri));
    if (body['result'] != 1) return 0;
    return (body['data'] ?? 0) as int? ?? 0;
  }

  /// `ke/C32761m.java:4121`. Interaction message news list.
  Future<Map<String, dynamic>> fetchMessageNews(
    ChaoxingSession session, {
    int page = 1,
    int pageSize = 20,
  }) async {
    _requireSession(session);
    final names = ['puid', 'page', 'pageSize'];
    final values = [session.puid, page.toString(), pageSize.toString()];
    final signed = ChaoxingSignCrypto.signedQuery(
      names,
      values,
      timeMillis: DateTime.now().millisecondsSinceEpoch,
    );
    final uri = Uri.parse(
      '$_specieBase/apis/message/getMessageNewsList?$signed',
    );
    return asMap(await _getJson(session, uri));
  }

  // ===================================================================
  // 9. User profile — inf_enc, learn.chaoxing.com
  // ===================================================================

  /// `cw/InterfaceC29499a.java:74` + `ke/C32761m.java:692`.
  /// User object: name, nick, pic, school, etc.
  Future<Map<String, dynamic>> fetchUser(
    ChaoxingSession session, {
    String? puid,
  }) async {
    _requireSession(session);
    final targetPuid = puid ?? session.puid;
    final names = ['puid'];
    final values = [targetPuid];
    final signed = ChaoxingSignCrypto.signedQuery(
      names,
      values,
      timeMillis: DateTime.now().millisecondsSinceEpoch,
    );
    final uri = Uri.parse('$_learnApiBase/apis/user/getUser?$signed');
    return asMap(await _getJson(session, uri));
  }

  /// `ke/C32761m.java:1042` + `p824qk/InterfaceC36047b.java:89`.
  /// Extended profile: school, dept, studentcode. Cookie-only.
  Future<Map<String, dynamic>> fetchExtendedUserInfo(
    ChaoxingSession session,
  ) async {
    _requireSession(session);
    final uri =
        Uri.parse(
          'https://passport2-api.chaoxing.com/api/extenduserinfo',
        ).replace(
          queryParameters: {
            'uid': session.uid,
            'enc': ChaoxingSignCrypto.md5Hex('${session.uid}dke#hjHU&32'),
            'last': '1',
          },
        );
    return asMap(await _getJson(session, uri));
  }

  // ===================================================================
  // 10. Activity panel — cookie-only, mobilelearn
  // ===================================================================

  /// `p985wg/InterfaceC37958c.java:191`. Course bottom panel (active types
  /// available in a course: sign, vote, discuss, etc.).
  Future<Map<String, dynamic>> fetchActivePanel(
    ChaoxingSession session, {
    required String courseId,
    required String classId,
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_learnBase/v2/apis/active/activePanel').replace(
      queryParameters: {
        'newVersion': '1',
        'courseId': courseId,
        'classId': classId,
      },
    );
    return asMap(await _getJson(session, uri));
  }

  /// `p649kb/C32662a.java:933` + `ke/C32761m.java:3939`.
  /// Activity timeline (history of all activities in a course).
  Future<Map<String, dynamic>> fetchActivityTimeline(
    ChaoxingSession session, {
    required String courseId,
    required String classId,
    int from = 0,
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_learnBase/phoneactivehistory/phonetimelist')
        .replace(
          queryParameters: {
            'courseId': courseId,
            'classId': classId,
            'from': from.toString(),
          },
        );
    return asMap(await _getJson(session, uri));
  }

  // ===================================================================
  // 11. Score API (fystat-ans) — inf_enc POST
  //     `p592ii/C31382b.java:97-136`
  // ===================================================================

  /// `ke/C32761m.java:697`. Fetch score list for a class.
  /// POST form with `data=<JSON MoocParam>`. Response:
  /// `{result:1, data:{<uid>:[{id,addScore,score,type,uid,classId}]}}`.
  Future<Map<String, dynamic>> fetchScoreList(
    ChaoxingSession session, {
    required String classId,
    required String courseId,
  }) async {
    _requireSession(session);
    final paramJson = jsonEncode({
      'data': [
        {'classId': classId, 'courseId': courseId},
      ],
    });
    final uri = Uri.parse('$_fystatBase/scoreApi/findScoreList');
    return asMap(await _postFormSigned(session, uri, {'data': paramJson}));
  }

  // ===================================================================
  // 12. Discussion / topics — inf_enc, groupyd.chaoxing.com
  //     `p987wi/InterfaceC37968b.java`
  // ===================================================================

  /// `ke/C32761m.java:205-212` + `InterfaceC37968b.java:458`.
  /// Topic list for a course discussion board (bbsid from GAS course detail).
  Future<Map<String, dynamic>> fetchTopicList(
    ChaoxingSession session, {
    required String bbsid,
    int pageSize = 20,
    String lastValue = '',
    String keyword = '',
    String folderId = '',
  }) async {
    _requireSession(session);
    final names = [
      'bbsid',
      'folderId',
      'puid',
      'kw',
      'maxW',
      'lastValue',
      'pageSize',
      'tags',
      'order',
      'searchType',
    ];
    final values = [
      bbsid,
      folderId,
      session.puid,
      keyword,
      '',
      lastValue,
      pageSize.toString(),
      '',
      '',
      '',
    ];
    final signed = ChaoxingSignCrypto.signedQuery(
      names,
      values,
      timeMillis: DateTime.now().millisecondsSinceEpoch,
    );
    final uri = Uri.parse(
      'https://groupyd.chaoxing.com/apis/topic/getTopicListWithPoff?$signed',
    );
    return asMap(await _getJson(session, uri));
  }

  // ===================================================================
  // 13. Course message list — cookie-only, mooc1-api
  // ===================================================================

  /// `ke/C32761m.java:1721-1723` + `af/InterfaceC0147a.java:266`.
  /// Course-scoped message list (unsigned).
  Future<Map<String, dynamic>> fetchCourseMessages(
    ChaoxingSession session, {
    required String clazzid,
    int limit = 20,
    int offset = 0,
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_moocBase/courseapi/msg-list').replace(
      queryParameters: {
        'clazzid': clazzid,
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
    );
    return asMap(await _getJson(session, uri));
  }

  // ===================================================================
  // 14. Study info / integral — cookie-only
  // ===================================================================

  /// `p649kb/C32662a.java:883`. Study info card (progress, points).
  Future<Map<String, dynamic>> fetchStudyInfo(
    ChaoxingSession session, {
    required String classId,
    required String courseId,
    String ut = 's',
    String cpi = '',
  }) async {
    _requireSession(session);
    final uri = Uri.parse('$_learnBase/widget/userStudyInfo/studyInfo').replace(
      queryParameters: {
        'classId': classId,
        'courseId': courseId,
        'uid': session.puid,
        'ut': ut,
        'cpi': cpi,
      },
    );
    return asMap(await _getJson(session, uri));
  }

  /// `p649kb/C32662a.java:858`. Points/integral detail.
  Future<Map<String, dynamic>> fetchIntegralDetail(
    ChaoxingSession session, {
    required String classId,
  }) async {
    _requireSession(session);
    final uri = Uri.parse(
      '$_learnBase/integral/getIntegraldetail',
    ).replace(queryParameters: {'classId': classId, 'uid': session.puid});
    return asMap(await _getJson(session, uri));
  }

  // ===================================================================
  // Transport plumbing (same pattern as ChaoxingSignService)
  // ===================================================================

  /// Coerces a decoded JSON [value] to a `Map<String, dynamic>`, returning an
  /// empty map for anything else.
  static Map<String, dynamic> asMap(dynamic value) =>
      value is Map ? value.cast<String, dynamic>() : const {};

  void _requireSession(ChaoxingSession session) {
    if (!session.isValid) {
      throw const ChaoxingSessionExpired('no valid Chaoxing session');
    }
  }

  Map<String, String> _headers(ChaoxingSession session) => {
    'User-Agent': userAgent,
    'Accept': '*/*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    'Cookie': session.cookieHeader,
  };

  Future<dynamic> _getJson(ChaoxingSession session, Uri uri) async {
    final text = await _getText(session, uri);
    try {
      return jsonDecode(text);
    } on FormatException {
      throw ChaoxingSignRejected(
        'non-JSON response from ${uri.path}: '
        '${text.substring(0, text.length.clamp(0, 120))}',
      );
    }
  }

  /// Fetches a JSON body that is GBK-encoded despite declaring
  /// `charset=utf-8` — the `richvideo/initdatawithviewerV2` and
  /// `question/quiz-*` pop-quiz endpoints. Fetches raw bytes and decodes them
  /// with the `gbk` codec before JSON parsing.
  Future<dynamic> _getJsonGbk(ChaoxingSession session, Uri uri) async {
    Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        uri.toString(),
        options: Options(
          headers: _headers(session),
          responseType: ResponseType.bytes,
        ),
      );
    } on Object catch (error) {
      throw ChaoxingSignNetworkFailure(error.toString());
    }
    final code = response.statusCode ?? 0;
    if (code == 301 || code == 302 || code == 303 || code == 307) {
      throw const ChaoxingSessionExpired(
        'Chaoxing endpoint redirected; session likely expired',
      );
    }
    final data = response.data;
    final text = data is List<int> ? gbk.decode(data) : '$data';
    if (text.contains('passport2.chaoxing.com/login') ||
        text.contains('<title>登录')) {
      throw const ChaoxingSessionExpired(
        'Chaoxing endpoint returned the login page; session expired',
      );
    }
    try {
      return jsonDecode(text);
    } on FormatException {
      throw ChaoxingSignRejected(
        'non-JSON response from ${uri.path}: '
        '${text.substring(0, text.length.clamp(0, 120))}',
      );
    }
  }

  Future<String> _getText(ChaoxingSession session, Uri uri) async {
    Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        uri.toString(),
        options: Options(
          headers: _headers(session),
          responseType: ResponseType.plain,
        ),
      );
    } on Object catch (error) {
      throw ChaoxingSignNetworkFailure(error.toString());
    }
    return _handleResponse(response, uri);
  }

  /// POST with inf_enc-signed query string appended to the URL.
  Future<dynamic> _postForm(
    ChaoxingSession session,
    Uri uri,
    String signedQuery,
  ) async {
    final fullUri = Uri.parse('${uri.toString()}?$signedQuery');
    Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        fullUri.toString(),
        options: Options(
          headers: _headers(session),
          responseType: ResponseType.plain,
        ),
      );
    } on Object catch (error) {
      throw ChaoxingSignNetworkFailure(error.toString());
    }
    final text = _handleResponse(response, fullUri);
    try {
      return jsonDecode(text);
    } on FormatException {
      return text;
    }
  }

  /// POST form-encoded body, cookie-only (no inf_enc) — the mooc1-api gear
  /// hosts authenticate with the session jar alone.
  Future<dynamic> _postFormPlain(
    ChaoxingSession session,
    Uri uri,
    Map<String, String> formFields,
  ) async {
    Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        uri.toString(),
        data: formFields,
        options: Options(
          headers: {
            ..._headers(session),
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          responseType: ResponseType.plain,
        ),
      );
    } on Object catch (error) {
      throw ChaoxingSignNetworkFailure(error.toString());
    }
    final text = _handleResponse(response, uri);
    try {
      return jsonDecode(text);
    } on FormatException {
      return text;
    }
  }

  /// POST form-encoded body with inf_enc signing on the query string.
  Future<dynamic> _postFormSigned(
    ChaoxingSession session,
    Uri uri,
    Map<String, String> formFields,
  ) async {
    final names = formFields.keys.toList();
    final values = formFields.values.toList();
    final signed = ChaoxingSignCrypto.signedQuery(
      names,
      values,
      timeMillis: DateTime.now().millisecondsSinceEpoch,
    );
    final fullUri = Uri.parse('${uri.toString()}?$signed');
    Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        fullUri.toString(),
        data: formFields,
        options: Options(
          headers: {
            ..._headers(session),
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          responseType: ResponseType.plain,
        ),
      );
    } on Object catch (error) {
      throw ChaoxingSignNetworkFailure(error.toString());
    }
    final text = _handleResponse(response, fullUri);
    try {
      return jsonDecode(text);
    } on FormatException {
      return text;
    }
  }

  String _handleResponse(Response<dynamic> response, Uri uri) {
    final code = response.statusCode ?? 0;
    if (code == 301 || code == 302 || code == 303 || code == 307) {
      throw const ChaoxingSessionExpired(
        'Chaoxing endpoint redirected; session likely expired',
      );
    }
    final raw = response.data;
    final text = raw is String ? raw : jsonEncode(raw ?? '');
    if (text.contains('passport2.chaoxing.com/login') ||
        text.contains('<title>登录')) {
      throw const ChaoxingSessionExpired(
        'Chaoxing endpoint returned the login page; session expired',
      );
    }
    return text;
  }
}

// =====================================================================
// Lightweight response models
// =====================================================================

/// A single notice from `myNotices_v2`.
class ChaoxingNotice {
  /// Creates a notice model.
  const ChaoxingNotice({
    required this.id,
    required this.title,
    required this.content,
    required this.senderName,
    required this.sendTime,
    this.isRead = false,
    this.type = '',
    this.attachments = const [],
  });

  /// Server-side notice id.
  final String id;

  /// Notice title.
  final String title;

  /// Notice body (HTML or plain text, as sent).
  final String content;

  /// Display name of the sender.
  final String senderName;

  /// When the notice was published.
  final DateTime sendTime;

  /// Whether the current user has read it.
  final bool isRead;

  /// Notice type/category code.
  final String type;

  /// Raw attachment descriptors, when present.
  final List<Map<String, dynamic>> attachments;

  /// Parses one entry of the `noticeList` array.
  factory ChaoxingNotice.fromJson(Map<String, dynamic> json) {
    return ChaoxingNotice(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      content: (json['content'] ?? json['noticeContent'] ?? '').toString(),
      senderName: (json['senderName'] ?? json['uname'] ?? '').toString(),
      sendTime: _parseTime(json['sendTime'] ?? json['completeTime']),
      isRead: json['read'] == true || json['isRead'] == true,
      type: (json['type'] ?? '').toString(),
      attachments: json['attachments'] is List
          ? (json['attachments'] as List)
                .whereType<Map>()
                .map((e) => e.cast<String, dynamic>())
                .toList()
          : const [],
    );
  }

  static DateTime _parseTime(dynamic value) {
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is String) {
      final ms = int.tryParse(value);
      if (ms != null) return DateTime.fromMillisecondsSinceEpoch(ms);
      return DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}

/// Paged notice list response.
class ChaoxingNoticeList {
  /// Creates an empty or populated notice page.
  const ChaoxingNoticeList({
    this.notices = const [],
    this.totalCount = 0,
    this.hasMore = false,
  });

  /// The notices on this page.
  final List<ChaoxingNotice> notices;

  /// Total number of notices matching the query.
  final int totalCount;

  /// Whether another page is available.
  final bool hasMore;

  /// Parses the `{result:1, data:{noticeList,…}}` envelope.
  factory ChaoxingNoticeList.fromJson(Map<String, dynamic> json) {
    if (json['result'] != 1) return const ChaoxingNoticeList();
    final data = ChaoxingApiService.asMap(json['data']);
    final list = data['noticeList'] ?? data['list'];
    final notices = <ChaoxingNotice>[];
    if (list is List) {
      for (final item in list) {
        if (item is Map) {
          notices.add(ChaoxingNotice.fromJson(item.cast<String, dynamic>()));
        }
      }
    }
    return ChaoxingNoticeList(
      notices: notices,
      totalCount: (data['totalCount'] ?? notices.length) as int? ?? 0,
      hasMore: data['hasMore'] == true,
    );
  }
}

/// A homework or exam row parsed from the course-level `workList` / `examList`
/// H5 pages.
///
/// These are the tasks a course shows under 作业 / 考试. They are *not* in the
/// `taskactivelist` activity feed (which only carries sign-ins, notices, votes,
/// …), and the native JSON feed `gas/taskmsg` is WAF-blocked off the official
/// app's network, so the cookie-authed HTML pages are the reliable source.
class ChaoxingCourseTask {
  /// Creates a course task.
  const ChaoxingCourseTask({
    required this.title,
    required this.url,
    required this.type,
    this.statusText = '',
    this.detail = '',
    this.status = 0,
  });

  /// [type] value for homework.
  static const work = 'work';

  /// [type] value for an exam.
  static const exam = 'exam';

  /// Task title (the homework/exam name).
  final String title;

  /// Absolute URL of the do-task H5 page (`/work/phone/task-work` or
  /// `/exam/phone/task-exam`), opened in a WebView with the session primed.
  final String url;

  /// [work] or [exam].
  final String type;

  /// The server's own status label, e.g. `做作业` / `已过期` / `已完成`.
  final String statusText;

  /// Secondary line: the publish date for homework, the score for an exam.
  final String detail;

  /// Raw `status` attribute (page-specific encoding; not normalized).
  final int status;

  /// True when this is an exam.
  bool get isExam => type == exam;
}

/// A single task/homework/exam item from `gas/taskmsg`.
class ChaoxingTaskItem {
  /// Creates a task feed item.
  const ChaoxingTaskItem({
    required this.id,
    required this.title,
    required this.courseName,
    required this.type,
    required this.status,
    required this.openTime,
    required this.endTime,
    this.doTaskUrl = '',
    this.courseCover = '',
    this.classId = '',
    this.courseId = '',
    this.finishStandard = '',
  });

  /// Server-side task id.
  final String id;

  /// Task title.
  final String title;

  /// Name of the course the task belongs to.
  final String courseName;

  /// `work` or `exam`.
  final String type;

  /// 0=pending, 1=submitted, 2=graded, etc.
  final int status;

  /// When the task opens.
  final DateTime openTime;

  /// When the task closes.
  final DateTime endTime;

  /// The URL to open for doing the task (WebView).
  final String doTaskUrl;

  /// Course cover image URL.
  final String courseCover;

  /// Class id the task was published to.
  final String classId;

  /// Course id the task belongs to.
  final String courseId;

  /// Completion criterion text, when the publisher set one.
  final String finishStandard;

  /// True when [endTime] is set and already past.
  bool get isOverdue =>
      endTime.millisecondsSinceEpoch > 0 && DateTime.now().isAfter(endTime);

  /// True when nothing has been submitted yet.
  bool get isPending => status == 0;

  /// Parses one entry of the `gas/taskmsg` data array.
  factory ChaoxingTaskItem.fromJson(Map<String, dynamic> json) {
    return ChaoxingTaskItem(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      courseName: (json['coursename'] ?? '').toString(),
      type: (json['type'] ?? '').toString(),
      status: _parseInt(json['status']),
      openTime: _parseTime(json['taskopentime']),
      endTime: _parseTime(json['taskendtime']),
      doTaskUrl: (json['dotaskurl'] ?? '').toString(),
      courseCover: (json['coursecover'] ?? '').toString(),
      classId: (json['classid'] ?? '').toString(),
      courseId: (json['courseid'] ?? '').toString(),
      finishStandard: (json['finishstandard'] ?? '').toString(),
    );
  }

  static int _parseInt(dynamic v) => switch (v) {
    final int n => n,
    final num n => n.toInt(),
    _ => int.tryParse('$v') ?? 0,
  };

  static DateTime _parseTime(dynamic v) {
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    if (v is String) {
      final ms = int.tryParse(v);
      if (ms != null) return DateTime.fromMillisecondsSinceEpoch(ms);
      return DateTime.tryParse(v) ?? DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}
