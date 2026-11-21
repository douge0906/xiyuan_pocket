import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../../constants/control_config.dart';
import '../control_service.dart';
import '../labs/lab_room_resolver.dart';
import 'recognized_course.dart';

/// 图片识别结果。
class OcrRecognition {
  const OcrRecognition({
    required this.courses,
    required this.supported,
    this.message,
    this.autoConverted = 0,
  });

  /// 解析出的候选课程（未编辑，待用户在面板里勾选/修改）。
  final List<RecognizedCourse> courses;

  /// 当前环境是否具备识别能力。控制端地址未配置时为 false，UI 层据此静默降级。
  final bool supported;

  /// 失败或无结果时给用户看的说明。
  final String? message;

  /// 已按实验室对照表自动换掉的教室数（去重后的原值个数）。
  final int autoConverted;
}

/// 图片识别导入（T3）的服务端实现。
///
/// 识别与字段抽取全部在服务端完成（`POST /api/v1/campus/ocr/course-table`），
/// 客户端只负责三件事：
/// 1. 把相册图片**压缩**到长边 1600px 以内再上传 —— 手机原图动辄 5~10MB，
///    传输和识别都慢，而课表截图缩到 1600px 对识别精度没有损失；
/// 2. 提交 base64，拿回已经分好字段的候选课程（name/teacher/classroom/
///    weekday/startSlot/endSlot/weeks），不需要在端上再解析文本；
/// 3. 失败时给出人话提示，不抛异常。
///
/// 与旧实现（ML Kit 本地识别 + Dart 规则解析）相比：规则只有服务端一份，
/// 安卓/Web 给同样的结果；也不再把 10MB 图片在端上解码跑模型。
Future<OcrRecognition> recognizeImageBytes(
  Uint8List bytes, {
  String filename = 'course_table.jpg',
}) async {
  if (!ControlConfig.enabled) {
    return const OcrRecognition(
      courses: [],
      supported: false,
      message: '当前环境未配置识别服务',
    );
  }

  final payload = _shrink(bytes);
  final uri =
      Uri.parse('${ControlConfig.baseUrl}/api/v1/campus/ocr/course-table');
  // OCR 现在要求设备令牌：匿名脚本不能拿它当免费算力。
  final deviceToken = await ControlService.ensureDevice();

  http.Response resp;
  try {
    resp = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            if (deviceToken != null && deviceToken.isNotEmpty)
              'Authorization': 'Device $deviceToken',
          },
          body: jsonEncode({
            'image_b64': base64Encode(payload),
            'filename': filename,
          }),
        )
        .timeout(const Duration(seconds: 40));
  } on TimeoutException {
    return const OcrRecognition(
      courses: [],
      supported: true,
      message: '识别超时，请检查网络后重试',
    );
  } catch (_) {
    return const OcrRecognition(
      courses: [],
      supported: true,
      message: '识别服务连不上，请检查网络后重试',
    );
  }

  if (resp.statusCode != 200) {
    return OcrRecognition(
      courses: const [],
      supported: true,
      message: resp.statusCode == 413
          ? '图片太大，请换一张更小的截图'
          : resp.statusCode == 401
              ? '设备身份校验失败，请重启 App 后再试'
              : '识别失败（HTTP ${resp.statusCode}），请稍后重试',
    );
  }

  Map<String, dynamic> data;
  try {
    data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  } catch (_) {
    return const OcrRecognition(
      courses: [],
      supported: true,
      message: '识别服务返回了无法解析的内容',
    );
  }

  final raw = data['courses'];
  final courses = <RecognizedCourse>[];
  if (raw is List) {
    for (final item in raw) {
      if (item is! Map) continue;
      final name = (item['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      courses.add(RecognizedCourse(
        name: name,
        teacher: (item['teacher'] ?? '').toString().trim(),
        classroom: (item['classroom'] ?? '').toString().trim(),
        className: _normalizeClassName(item['className']),
        academicYear: (item['academicYear'] ?? '').toString().trim(),
        academicTerm: (item['academicTerm'] ?? '').toString().trim(),
        weekday: _int(item['weekday'], 0, 7),
        startSlot: _int(item['startSlot'], 0, 12),
        endSlot: _int(item['endSlot'], 0, 12),
        weeks: (item['weeks'] ?? '').toString().trim(),
      ));
    }
  }

  // 服务端老版本已经把「班级名称」识别进 blocks，却没放进 courses。
  // 这里做一层兼容回填：单个班/合班只有一个唯一值时全量回填；多个值且
  // 数量与课程数一一对应时按顺序回填。服务端升级后 item 里直接带字段，
  // 这一步不会覆盖已有值。
  final fallbackClasses =
      _blockFieldValues(data['blocks'], const ['班级名称', '班级']);
  final fallbackTerms = _blockAcademicTerms(data['blocks']);
  for (var i = 0; i < courses.length; i++) {
    if (courses[i].className.isEmpty) {
      courses[i].className = _pickFallback(fallbackClasses, i, courses.length);
    }
    if (courses[i].academicYear.isEmpty || courses[i].academicTerm.isEmpty) {
      final term = _pickFallback(fallbackTerms, i, courses.length);
      if (term.isNotEmpty) {
        final parts = term.split('|');
        if (courses[i].academicYear.isEmpty && parts.isNotEmpty) {
          courses[i].academicYear = parts[0];
        }
        if (courses[i].academicTerm.isEmpty && parts.length > 1) {
          courses[i].academicTerm = parts[1];
        }
      }
    }
  }

  // 实验室名 → 标准教室（楼栋+房号）。命中不了就保持服务端原值。
  final converted = <String>{};
  try {
    final resolver = await LabRoomResolver.instance();
    for (final c in courses) {
      final res = resolver.resolvePlace(c.classroom);
      if (!res.changed) continue;
      converted.add(res.original!);
      c.classroom = res.value;
    }
  } catch (_) {
    // 对照表加载失败不影响识别结果，教室保持原值。
  }

  return OcrRecognition(
    courses: courses,
    supported: true,
    autoConverted: converted.length,
    message: courses.isEmpty
        ? (data['message']?.toString() ?? '未从图片里识别出课程，请换一张更清晰的截图')
        : null,
  );
}

/// 班级原值规范化：合班列 `25电气1,25电气2,25电气3` 统一成中文顿号，
/// 同时把 OCR 带进来的残缺尾项（如 `25电气2.25` 里的 `25`）丢掉。
String _normalizeClassName(Object? raw) {
  final text = (raw ?? '').toString().trim();
  if (text.isEmpty) return '';
  final parts = text
      .split(RegExp(r'[，,、;；.．/]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  final looksLikeClass = RegExp(
    r'^\d{2,4}(?:级)?[一-龥]{1,12}\d{0,2}(?:班)?$',
  );
  final kept = parts.where(looksLikeClass.hasMatch).toList();
  if (kept.length >= 2) return kept.join('、');
  return text;
}

/// 从服务端 `blocks` 里取某一行字段（以 `班级名称 25微电子1 ...` 这种
/// 「标签 + 空格分隔值」的形态返回）。只兼容旧服务端，新服务端直接给字段。
List<String> _blockFieldValues(Object? blocks, List<String> labels) {
  if (blocks is! List) return const [];
  for (final block in blocks) {
    final line = (block ?? '').toString().trim();
    for (final label in labels) {
      if (!line.startsWith(label)) continue;
      final rest = line.substring(label.length).trim();
      final values = rest
          .split(RegExp(r'\s+'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (values.isNotEmpty) return values;
    }
  }
  return const [];
}

/// 从 blocks 中的 8 位日期推学年/学期，供旧服务端兼容回填。
List<String> _blockAcademicTerms(Object? blocks) {
  if (blocks is! List) return const [];
  final out = <String>[];
  for (final block in blocks) {
    final text = (block ?? '').toString();
    for (final m in RegExp(r'20\d{6}').allMatches(text)) {
      final raw = m.group(0)!;
      final year = int.tryParse(raw.substring(0, 4));
      final month = int.tryParse(raw.substring(4, 6));
      if (year == null || month == null || month < 1 || month > 12) continue;
      final startYear = month >= 8 ? year : year - 1;
      final term = (month >= 8 || month == 1) ? '第一学期' : '第二学期';
      out.add('$startYear-${startYear + 1}|$term');
    }
  }
  return out;
}

/// 单个唯一值 → 全量；数量与课程数一致 → 按下标。
String _pickFallback(List<String> values, int index, int total) {
  if (values.isEmpty) return '';
  final unique = values.toSet();
  if (unique.length == 1) return unique.first;
  if (values.length == total) return values[index];
  return '';
}

int _int(Object? v, int fallback, int max) {
  final n = v is int ? v : int.tryParse('${v ?? ''}');
  if (n == null || n < 0 || n > max) return fallback;
  return n;
}

/// 上传前压缩：长边压到 1600px、转 JPEG。
///
/// 服务端会把小于 1200px 的图放大后再识别，所以这里保持 1600 不会损失精度，
/// 同时把常见 8~12MB 的手机原图压到 300~600KB。解码失败（格式不认识）就原样上传，
/// 由服务端返回「图片解码失败」的提示，避免客户端把可用图片误判成坏图。
Uint8List _shrink(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final longest =
        decoded.width > decoded.height ? decoded.width : decoded.height;
    final resized = longest > 1600
        ? img.copyResize(
            decoded,
            width: decoded.width >= decoded.height ? 1600 : null,
            height: decoded.height > decoded.width ? 1600 : null,
            interpolation: img.Interpolation.average,
          )
        : decoded;
    return Uint8List.fromList(img.encodeJpg(resized, quality: 88));
  } catch (_) {
    return bytes;
  }
}
