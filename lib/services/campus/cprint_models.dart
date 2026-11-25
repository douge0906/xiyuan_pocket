/// 云打印扫描件的数据模型。
///
/// 字段名与站点接口保持一致（`szDisplayName` / `dwJobId` …），是为了让
/// 「字段对不上时一眼能看出是哪一层错了」—— 站点是 2022 年的老系统，
/// 不会有文档同步给我们，保留原名比改成 Dart 风格更有维护价值。
///
/// 解析入口只有一个：[CprintScanItem.fromJson]。站点偶发返回 `result: null`
/// （账号下没有扫描件时是 `null` 而不是 `[]`），这层必须把它当空列表，
/// 不能当成解析失败。
library;

import 'dart:convert';

/// 文件类型推导 —— 复刻站点 `Cprint.getDocType`（`cprint_common.js:359-388`）。
///
/// 为什么要复刻：接口只回 `szDisplayName`（原文件名），`x_doctype` 是站点
/// **前端当场算出来的**派生字段，服务端根本没有。App 要显示类型图标就得自己算，
/// 而且规则必须与站点一致，否则同一份文件在网页版和 App 里会显示成两种类型。
class CprintDocType {
  const CprintDocType(this.type, this.classType);

  /// 展示用的扩展名，最长 5 字符（站点 `Common.cut(type, 5)`）。
  final String type;

  /// 归一后的类别：`img` / `pdf` / `txt` / `word` / `excel` / `ppt` / `other`。
  final String classType;

  static const CprintDocType unknown = CprintDocType('', 'other');

  /// 与站点逐分支对齐（含它自己的拼写错误 `xslx`，以及 `dotm` 同时出现在
  /// word 和 excel 两组里——后者命中 word 分支，因为判断顺序在前）。
  static CprintDocType fromName(String name) {
    if (name.isEmpty) return unknown;
    final parts = name.split('.');
    if (parts.length < 2) return unknown;
    var type = parts.last.toLowerCase();
    // 站点对「a.pdf[1]」这种浏览器重复下载产生的文件名做了截断。
    final bracket = type.indexOf('[');
    if (bracket >= 0) type = type.substring(0, bracket);
    if (type.isEmpty) return unknown;
    final shown = type.length > 5 ? type.substring(0, 5) : type;

    if (type == 'jpg' || type == 'png' || type == 'jpeg' || type == 'dif') {
      return CprintDocType(shown, 'img');
    }
    if (type == 'pdf') return CprintDocType(shown, 'pdf');
    if (type == 'txt' ||
        type == 'xml' ||
        type == 'mht' ||
        type == 'mhtml' ||
        type == 'html' ||
        type == 'htm') {
      return CprintDocType(shown, 'txt');
    }
    if (type == 'doc' ||
        type == 'docx' ||
        type == 'dotx' ||
        type == 'docm' ||
        type == 'wps' ||
        type == 'wpt' ||
        type == 'dot' ||
        type == 'dotm' ||
        type == 'odt' ||
        type == 'csv') {
      return CprintDocType(shown, 'word');
    }
    if (type == 'xls' ||
        type == 'xslx' ||
        type == 'xlsx' ||
        type == 'xlsm' ||
        type == 'xlsb' ||
        type == 'ods') {
      return CprintDocType(shown, 'excel');
    }
    if (type == 'ppt' ||
        type == 'pptx' ||
        type == 'pps' ||
        type == 'pptm' ||
        type == 'ppsm' ||
        type == 'potm' ||
        type == 'pot') {
      return CprintDocType(shown, 'ppt');
    }
    return CprintDocType(shown, 'other');
  }
}

/// 一份扫描件。
class CprintScanItem {
  const CprintScanItem({
    required this.jobId,
    required this.displayName,
    required this.fileSize,
    required this.submitDate,
    required this.submitTime,
    required this.status,
  });

  /// `dwJobId` —— 下载与删除的唯一句柄。
  final String jobId;

  /// `szDisplayName` —— 打印店代扫时上传的原始文件名。
  final String displayName;

  /// `dwFileSize` —— 字节。
  final int fileSize;

  /// `dwSubmitDate` —— 站点格式 `2026.11.24`。
  final String submitDate;

  /// `dwSubmitTime` —— 站点格式 `11:22:33`。
  final String submitTime;

  /// `dwStatus` 位标记。**只有 bit 256 是已知语义**（文件已过期，站点模板
  /// 里就这一处判断），其余位见过非 0 但语义不明，不要瞎解释。
  final int status;

  static const int expiredBit = 256;

  /// 站点 `scanDoc.html` 的唯一过期判据：`(dwStatus & 256) == 0` 才可选中/下载。
  bool get isExpired => (status & expiredBit) != 0;

  CprintDocType get docType => CprintDocType.fromName(displayName);

  /// 字节数转可读大小 —— 与站点 `scanDoc.js:188-195` 同样的三级换算
  /// （B / KB / MB，取整不保留小数），保证与网页版显示一致。
  String get sizeLabel {
    if (fileSize < 1024) return '${fileSize}B';
    if (fileSize < 1048576) return '${fileSize ~/ 1024}KB';
    return '${fileSize ~/ 1024 ~/ 1024}MB';
  }

  /// 提交时间。站点把日期与时间拆成两个字符串返回，这里合成一个 DateTime
  /// 供列表排序；解析不出来返回 null（**不要猜当前时间**，那会让坏数据排到最前）。
  DateTime? get submittedAt {
    final d = submitDate.trim().replaceAll('/', '.').replaceAll('-', '.');
    final t = submitTime.trim();
    if (d.isEmpty || t.isEmpty) return null;
    final dm = RegExp(r'^(\d{4})\.(\d{1,2})\.(\d{1,2})$').firstMatch(d);
    final tm = RegExp(r'^(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?$').firstMatch(t);
    if (dm == null || tm == null) return null;
    return DateTime(
      int.parse(dm.group(1)!),
      int.parse(dm.group(2)!),
      int.parse(dm.group(3)!),
      int.parse(tm.group(1)!),
      int.parse(tm.group(2)!),
      int.tryParse(tm.group(3) ?? '') ?? 0,
    );
  }

  /// 站点 `x_sorttime` 的口径（`dwSubmitDate + dwSubmitTime` 拼数字）—— 排序用。
  int get sortKey {
    final digits = '${submitDate.replaceAll(RegExp(r'[^0-9]'), '')}'
        '${submitTime.replaceAll(RegExp(r'[^0-9]'), '')}';
    return int.tryParse(digits) ?? 0;
  }

  /// 落盘用的安全文件名（用户设备上不能出现 `:` `/` 这类保留字符）。
  String get safeFileName {
    final cleaned = displayName
        .replaceAll(RegExp(r'[\/:*?"<>|\x00-\x1F]'), '_')
        .trim();
    if (cleaned.isEmpty) return 'scan_$jobId';
    // Android 单段文件名上限 255 字节；中文按 UTF-8 占 3 字节，留足余量。
    if (cleaned.length <= 80) return cleaned;
    final dot = cleaned.lastIndexOf('.');
    if (dot <= 0 || dot == cleaned.length - 1) return cleaned.substring(0, 80);
    final ext = cleaned.substring(dot);
    final keep = 80 - ext.length;
    return '${cleaned.substring(0, keep < 1 ? 1 : keep)}$ext';
  }

  Map<String, dynamic> toJson() => {
        'dwJobId': jobId,
        'szDisplayName': displayName,
        'dwFileSize': fileSize,
        'dwSubmitDate': submitDate,
        'dwSubmitTime': submitTime,
        'dwStatus': status,
      };

  /// 容错解析：单条坏掉返回 null，调用方 `whereType` 过滤掉，不影响其它条。
  ///
  /// 为什么这么宽：这接口没有版本号、没有 schema，字段缺失/类型漂移只能靠
  /// 「缺什么给什么默认值」扛住。`dwJobId` 是唯一下载句柄，没有它就完全没用，
  /// 所以只有这一项缺失才整条丢弃。
  static CprintScanItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final jobId = (m['dwJobId'] ?? '').toString().trim();
    if (jobId.isEmpty) return null;
    final name = (m['szDisplayName'] ?? '').toString();
    final size = m['dwFileSize'];
    return CprintScanItem(
      jobId: jobId,
      displayName: name.isEmpty ? '未命名文件' : name,
      fileSize: size is num ? size.toInt() : int.tryParse('$size') ?? 0,
      submitDate: (m['dwSubmitDate'] ?? '').toString(),
      submitTime: (m['dwSubmitTime'] ?? '').toString(),
      status: m['dwStatus'] is num
          ? (m['dwStatus'] as num).toInt()
          : int.tryParse('${m['dwStatus']}') ?? 0,
    );
  }

  /// 解析 `Scan/Get` 的整个响应体。
  ///
  /// 三种情况都要能走：
  ///  - `{"code":0,"result":[...]}`   正常
  ///  - `{"code":0,"result":null}`    该账号下没有扫描件（**实测过的真实返回**）
  ///  - `{"code":4,...}`              会话失效 → 由调用方看 [CprintScanResult.errorCode]
  static CprintScanResult parseList(Object? decoded) {
    if (decoded is! Map) {
      return const CprintScanResult(errorCode: -1, message: '返回格式无法识别');
    }
    final code = decoded['code'];
    final codeInt = code is num ? code.toInt() : int.tryParse('$code') ?? -1;
    final message = (decoded['message'] ?? '').toString();
    if (codeInt != 0) {
      return CprintScanResult(errorCode: codeInt, message: message);
    }
    final result = decoded['result'];
    if (result == null) {
      return const CprintScanResult(errorCode: 0, items: <CprintScanItem>[]);
    }
    if (result is! List) {
      return const CprintScanResult(errorCode: -1, message: '扫描件列表格式无法识别');
    }
    final items = <CprintScanItem>[];
    for (final raw in result) {
      final item = CprintScanItem.fromJson(raw);
      if (item != null) items.add(item);
    }
    return CprintScanResult(errorCode: 0, items: items);
  }
}

/// `Scan/Get` 的解析结果。
class CprintScanResult {
  const CprintScanResult({
    required this.errorCode,
    this.message = '',
    this.items = const <CprintScanItem>[],
  });

  /// 0 = 成功；4 = 会话失效（要重新授权）；其它 = 未预期的服务端错误。
  final int errorCode;
  final String message;
  final List<CprintScanItem> items;

  bool get ok => errorCode == 0;

  /// 会话过期 —— 这是唯一「重登就能好」的错误码（站点全站统一用它）。
  bool get needReauth => errorCode == 4;

  CprintScanResult copyWith({List<CprintScanItem>? items}) => CprintScanResult(
        errorCode: errorCode,
        message: message,
        items: items ?? this.items,
      );
}

/// 云打印接口的错误码（站点自己的约定，见设计文档 §2）。
class CprintError {
  CprintError._();

  /// 未登录 / 会话无效。
  static const int notLoggedIn = 4;

  /// 云打印系统里没有这个学生 —— 不是 App 的错，只能引导去图书馆技术部。
  static const int noAccount = 16777228;

  /// 删除失败。
  static const int deleteFailed = 16777231;

  /// 凭据失败（`UniLogin` 的固定返回，该接口确认是红鲱鱼）。
  static const int badCredential = 33558534;
}

// ignore_for_file: prefer_single_quotes
// （本文件由 D:/tmp/append_models.py 追加到 lib/services/campus/cprint_models.dart 末尾）

/// 一份待打印的文档（网页版「打印文档」列表的一行）。
class CprintPrintJob {
  final String jobId;
  final String fileName;
  final String submitDate;
  final String submitTime;
  final int copies;
  final int pages;
  final int status;
  final int fee;
  final String attribute;
  final String memo;
  final List<CprintPaperSheet> papers;

  const CprintPrintJob({
    required this.jobId,
    required this.fileName,
    required this.submitDate,
    required this.submitTime,
    required this.copies,
    required this.pages,
    required this.status,
    required this.fee,
    required this.attribute,
    required this.memo,
    required this.papers,
  });

  /// 原文件名（站点字段就叫 `szJobName`，但它是文件名不是「任务名」）。
  String get displayName => fileName.isEmpty ? '未命名文档' : fileName;

  CprintDocType get docType => CprintDocType.fromName(fileName);

  /// 纸型汇总：`A4` / `A3` / `A4、A3`，无数据时给空串。
  String get paperLabel {
    final seen = <String>[];
    for (final p in papers) {
      final t = p.paperType;
      if (t.isNotEmpty && !seen.contains(t)) seen.add(t);
    }
    return seen.join('、');
  }

  /// 站点用 `szAttribe` 这个逗号串表达属性：`color` / `vdup` / `single`。
  bool get isColor => attribute.contains('color');

  String get colorLabel => isColor ? '彩色' : '黑白';

  String get duplexLabel {
    if (attribute.contains('vdup')) return '双面长边';
    if (attribute.contains('single')) return '单面';
    return '双面短边';
  }

  /// 页数：优先用站点算好的 `dwPages`，为 0 时按纸张明细累加。
  int get totalPages {
    if (pages > 0) return pages;
    var n = 0;
    for (final p in papers) {
      n += p.bwPages + p.colorPages;
    }
    return n;
  }

  String get sizeLabel => '$totalPages 页 × ${copies > 0 ? copies : 1} 份';

  /// 提交时间 `2026.11.24 15:48`；解析不出来时返回空串（界面不显示）。
  String get submittedAtLabel {
    if (submitDate.length != 8) return '';
    final d = '${submitDate.substring(0, 4)}.${submitDate.substring(4, 6)}.'
        '${submitDate.substring(6, 8)}';
    if (submitTime.length != 6) return d;
    return '$d ${submitTime.substring(0, 2)}:${submitTime.substring(2, 4)}';
  }

  /// `dwCreateTime` 是 6 位整数，预览接口要原样传回。
  String get rawCreateTime => submitTime;

  static CprintPrintJob? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = '${raw['dwJobId'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    return CprintPrintJob(
      jobId: id,
      fileName: '${raw['szJobName'] ?? ''}',
      submitDate: '${raw['dwCreateDate'] ?? ''}',
      submitTime: '${raw['dwCreateTime'] ?? ''}',
      copies: _i(raw['dwCopies']),
      pages: _i(raw['dwPages']),
      status: _i(raw['dwStatus']),
      fee: _i(raw['dwFee']),
      attribute: '${raw['szAttribe'] ?? ''}',
      memo: '${raw['szMemo'] ?? ''}',
      papers: CprintPaperSheet.parseDetail(raw['szPaperDetail']),
    );
  }

  static List<CprintPrintJob> parseList(Object? decoded) {
    if (decoded is! Map) return const [];
    final result = decoded['result'];
    if (result is! List) return const [];
    final out = <CprintPrintJob>[];
    for (final e in result) {
      final j = fromJson(e);
      if (j != null) out.add(j);
    }
    return out;
  }
}

/// `szPaperDetail` 里的一格纸：A4 黑白 3 页 + 彩色 1 页 = 4 页。
///
/// ⚠️ 站点给的是**字符串**（`'[{"dwPaperID":9,...}]'`），不是数组，
/// 必须先 `jsonDecode` 再读。这一点在 Dart 里很容易漏，漏了就全是空页数。
class CprintPaperSheet {
  final int paperId;
  final int bwPages;
  final int colorPages;
  final int paperNum;

  const CprintPaperSheet({
    required this.paperId,
    required this.bwPages,
    required this.colorPages,
    required this.paperNum,
  });

  /// 站点规则：`9` → A4，其它一律 A3（与网页版 `dwPaperID == 9 ? "A4" : "A3"` 一致）。
  String get paperType => paperId == 9 ? 'A4' : 'A3';

  static List<CprintPaperSheet> parseDetail(Object? raw) {
    Object? data = raw;
    if (data is String) {
      final text = data.trim();
      if (text.isEmpty) return const [];
      try {
        data = jsonDecode(text);
      } catch (_) {
        return const [];
      }
    }
    if (data is! List) return const [];
    final out = <CprintPaperSheet>[];
    for (final e in data) {
      if (e is! Map) continue;
      out.add(CprintPaperSheet(
        paperId: _i(e['dwPaperID']),
        bwPages: _i(e['dwBWPages']),
        colorPages: _i(e['dwColorPages']),
        paperNum: _i(e['dwPaperNum']),
      ));
    }
    return out;
  }
}

/// 一台打印点（网页版「打印点」列表的一行）。
class CprintStation {
  final int devSn;
  final String name;
  final int property;
  final int status;
  final String statusInfo;
  final String driver;
  final List<int> trays;

  const CprintStation({
    required this.devSn,
    required this.name,
    required this.property,
    required this.status,
    required this.statusInfo,
    required this.driver,
    required this.trays,
  });

  /// 状态：空闲 / 忙碌 / 不可用 / 未开放。
  ///
  /// 逐位照抄网页版 `backState()`（`cp_printDev.js`）。注意其中 `20`、`400`、
  /// `800`、`1000`、`2000`、`10000` 在站点源码里是**十进制写法**却是十六进制
  /// 常量（0x20/0x400/…）的本意 —— 这里照抄十进制，才能和网页版显示一致。
  String get stateLabel {
    if (status == 0) return '未开放';
    var state = '';
    if (status & 1 != 0) state = '空闲';
    if (status & 2 != 0) state = '忙碌';
    final fault = status & 20 != 0 ||
        status & 400 != 0 ||
        status & 800 != 0 ||
        status & 1000 != 0 ||
        status & 2000 != 0 ||
        status & 10000 != 0;
    if (fault || status & 200 != 0) {
      state = statusInfo.isEmpty ? '不可用' : _beforeDash(statusInfo);
    }
    return state.isEmpty ? '不可用' : state;
  }

  /// 1=忙碌 2=空闲 3=不可用（决定颜色）。
  int get stateFlag {
    if (status == 0) return 3;
    var flag = 0;
    if (status & 1 != 0) flag = 2;
    if (status & 2 != 0) flag = 1;
    final fault = status & 20 != 0 ||
        status & 400 != 0 ||
        status & 800 != 0 ||
        status & 1000 != 0 ||
        status & 2000 != 0 ||
        status & 10000 != 0;
    if (fault || status & 200 != 0) flag = 3;
    return flag == 0 ? 3 : flag;
  }

  /// 支持的纸型：`A4、A3`。
  ///
  /// 🔴 网页版这里有个 bug（`data.dwTrayPaper3` 少了下标），会把第 3 个纸盒
  /// 永远漏掉。**这里不复刻**：四个纸盒一视同仁。
  String get paperLabel {
    final seen = <String>[];
    for (final t in trays) {
      final label = t == 9 ? 'A4' : (t == 8 ? 'A3' : '');
      if (label.isNotEmpty && !seen.contains(label)) seen.add(label);
    }
    return seen.join('、');
  }

  /// 可用功能：打印 / 复印 / 扫描 / 支持彩色。
  String get functionLabel {
    final out = <String>[];
    if (property & 1 != 0) out.add('打印');
    if (property & 2 != 0) out.add('复印');
    if (property & 4 != 0) out.add('扫描');
    if (property & 8 != 0) out.add('彩色');
    return out.join(' · ');
  }

  static String _beforeDash(String s) {
    final i = s.indexOf('-');
    return i <= 0 ? s : s.substring(0, i);
  }

  static CprintStation? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final sn = _i(raw['dwDevSN']);
    if (sn == 0) return null;
    final trays = <int>[];
    for (final k in const [
      'dwTrayPaper1',
      'dwTrayPaper2',
      'dwTrayPaper3',
      'dwTrayPaper4'
    ]) {
      final v = _i(raw[k]);
      if (v != 0) trays.add(v);
    }
    return CprintStation(
      devSn: sn,
      name: '${raw['szName'] ?? ''}',
      property: _i(raw['dwProperty']),
      status: _i(raw['dwStatus']),
      statusInfo: '${raw['szStatInfo'] ?? ''}',
      driver: '${raw['szPrtDriver'] ?? ''}',
      trays: trays,
    );
  }

  static List<CprintStation> parseList(Object? decoded) {
    if (decoded is! Map) return const [];
    final result = decoded['result'];
    if (result is! List) return const [];
    final out = <CprintStation>[];
    for (final e in result) {
      final s = fromJson(e);
      if (s != null) out.add(s);
    }
    return out;
  }
}

/// 一个打印服务商（`Station/GetSrvList`），用来给打印点分组。
class CprintSrv {
  final int sn;
  final String name;

  const CprintSrv({required this.sn, required this.name});

  static List<CprintSrv> parseList(Object? decoded) {
    if (decoded is! Map) return const [];
    final result = decoded['result'];
    if (result is! List) return const [];
    final out = <CprintSrv>[];
    for (final e in result) {
      if (e is! Map) continue;
      final sn = _i(e['dwSN']);
      if (sn == 0) continue;
      out.add(CprintSrv(sn: sn, name: '${e['szName'] ?? ''}'));
    }
    return out;
  }
}

/// 一条使用记录（打印 / 扫描 / 复印）。
class CprintRecord {
  final String date;
  final String time;
  final int paperId;
  final int pages;
  final int settleType;
  final int cardMoney;
  final int freeMoney;
  final int cashMoney;

  const CprintRecord({
    required this.date,
    required this.time,
    required this.paperId,
    required this.pages,
    required this.settleType,
    required this.cardMoney,
    required this.freeMoney,
    required this.cashMoney,
  });

  String get paperLabel => paperId == 9 ? 'A4' : (paperId == 8 ? 'A3' : '');

  /// 金额单位是「分」，三项相加再除 100（与网页版 `x_money` 一致）。
  String get moneyLabel {
    final fen = cardMoney + freeMoney + cashMoney;
    if (fen == 0) return '0 元';
    return '${(fen / 100).toStringAsFixed(2)} 元';
  }

  /// 同 [moneyLabel] 的数值形态，给「本页合计」这类需要相加的地方用。
  double get moneyYuan => (cardMoney + freeMoney + cashMoney) / 100;

  /// `(dwSettleType & 0xff) == 4` → 手工收费，其余自助收费。
  String get settleLabel => (settleType & 0xff) == 4 ? '手工收费' : '自助收费';

  String get dateLabel {
    if (date.length != 8) return date;
    return '${date.substring(0, 4)}.${date.substring(4, 6)}.${date.substring(6, 8)}';
  }

  String get timeLabel {
    // `dwTime` 是整数，实际有两种宽度：`1548`（= 15:48）和 `154800`（= 15:48:00）。
    // 直接按 6 位补 0 会把 1548 变成 00:15 —— 那不是这条记录的时间。
    if (time.isEmpty) return '';
    final t = time.length <= 4 ? time.padLeft(4, '0') : time.padLeft(6, '0');
    return '${t.substring(0, 2)}:${t.substring(2, 4)}';
  }

  static CprintRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return CprintRecord(
      date: '${raw['dwDate'] ?? ''}',
      time: '${raw['dwTime'] ?? ''}',
      paperId: _i(raw['dwPaperID']),
      pages: _i(raw['dwPageNo']),
      settleType: _i(raw['dwSettleType']),
      cardMoney: _i(raw['dwUsedCardMoney']),
      freeMoney: _i(raw['dwUsedFreeMoney']),
      cashMoney: _i(raw['dwUsedMoney']),
    );
  }
}

/// 「使用记录」一页的结果。
class CprintRecordPage {
  final List<CprintRecord> items;
  final int pageNo;
  final int totalPage;
  final int errorCode;
  final String message;

  const CprintRecordPage({
    required this.items,
    required this.pageNo,
    required this.totalPage,
    required this.errorCode,
    required this.message,
  });

  bool get ok => errorCode == 0;
  bool get needReauth => errorCode == CprintError.notLoggedIn;

  static const CprintRecordPage empty = CprintRecordPage(
    items: [],
    pageNo: 1,
    totalPage: 0,
    errorCode: 0,
    message: '',
  );

  static CprintRecordPage parse(Object? decoded) {
    if (decoded is! Map) {
      return const CprintRecordPage(
        items: [],
        pageNo: 1,
        totalPage: 0,
        errorCode: -1,
        message: '使用记录返回的内容看不懂，请稍后重试。',
      );
    }
    final result = decoded['result'];
    final items = <CprintRecord>[];
    if (result is List) {
      for (final e in result) {
        final r = CprintRecord.fromJson(e);
        if (r != null) items.add(r);
      }
    }
    return CprintRecordPage(
      items: items,
      pageNo: _i(decoded['dwPageNo']) == 0 ? 1 : _i(decoded['dwPageNo']),
      totalPage: _i(decoded['dwTotalPage']),
      errorCode: _i(decoded['code']),
      message: '${decoded['message'] ?? ''}',
    );
  }
}

/// 上传（去打印）的结果。
///
/// 站点这个接口不返回 JSON，而是 **302 到 `result.html?code=0&fee=20&message=`**，
/// 所以只能从 `Location` 的 query 里读结果 —— 网页版也是这么做的
/// （`oReq.responseURL.split("?")[1]`）。
class CprintUploadResult {
  final int code;
  final int feeFen;
  final String message;

  const CprintUploadResult({
    required this.code,
    required this.feeFen,
    required this.message,
  });

  bool get ok => code == 0;

  /// 预估费用：`fee` 单位是分。
  String get feeLabel => feeFen <= 0 ? '' : '${(feeFen / 100).toStringAsFixed(2)} 元';

  static const CprintUploadResult failed = CprintUploadResult(
    code: -1,
    feeFen: 0,
    message: '上传失败，请稍后再试。',
  );

  static CprintUploadResult parseLocation(String location) {
    if (location.isEmpty) return failed;
    final q = Uri.tryParse(location)?.queryParameters ?? const {};
    // 🔴 没有 `code` 就不是云打印的结果页。网关/门户会把 302 改写成别的地址，
    //    那种 Location 里同样没有 code —— 不能把「被改写」当成「上传成功」。
    if (!q.containsKey('code')) return failed;
    final code = _i(q['code']);
    final fee = _i(q['fee']);
    final raw = (q['message'] ?? '').trim();
    var msg = raw;
    if (raw.isNotEmpty) {
      try {
        msg = Uri.decodeComponent(raw);
      } catch (_) {
        msg = raw;
      }
    }
    return CprintUploadResult(code: code, feeFen: fee, message: msg);
  }
}

/// 打印任务列表的结果（网页版「打印文档」页）。
class CprintJobResult {
  final List<CprintPrintJob> jobs;
  final int errorCode;
  final String message;

  const CprintJobResult({
    required this.errorCode,
    required this.message,
    this.jobs = const [],
  });

  bool get ok => errorCode == 0;
  bool get needReauth => errorCode == CprintError.notLoggedIn;
}

/// 打印点的结果（网页版「打印点」页）。
class CprintStationResult {
  final List<CprintSrv> srvs;
  final List<CprintStation> stations;
  final int errorCode;
  final String message;

  const CprintStationResult({
    required this.errorCode,
    required this.message,
    this.srvs = const [],
    this.stations = const [],
  });

  bool get ok => errorCode == 0;
  bool get needReauth => errorCode == CprintError.notLoggedIn;

  /// 按服务商分组的机器（网页版顶部下拉的效果）。
  ///
  /// 站点用 `parseInt(dwDevSN / 1000) == dwSN` 判定归属，这里照抄。
  /// 服务商列表为空时，把所有机器归到一个「全部」分组，避免整页空白。
  Map<CprintSrv, List<CprintStation>> get grouped {
    final out = <CprintSrv, List<CprintStation>>{};
    if (srvs.isEmpty) {
      out[CprintSrv(sn: 0, name: '全部打印点')] = stations;
      return out;
    }
    for (final srv in srvs) {
      final mine = stations
          .where((s) => s.devSn ~/ 1000 == srv.sn)
          .toList(growable: false);
      if (mine.isNotEmpty) out[srv] = mine;
    }
    // 归属算不出来（sn 不匹配）的机器不能吞掉 —— 用户会以为打印机没了。
    final listed = <int>{};
    for (final v in out.values) {
      for (final s in v) {
        listed.add(s.devSn);
      }
    }
    final rest = stations.where((s) => !listed.contains(s.devSn)).toList(growable: false);
    if (rest.isNotEmpty) out[CprintSrv(sn: 0, name: '其他打印点')] = rest;
    return out;
  }
}

int _i(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('${v ?? ''}') ?? 0;
}
