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
