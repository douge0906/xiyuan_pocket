import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

/// 一个极简的 PDF 读取器 —— **只做「取出带坐标的文字」这一件事**。
///
/// 为什么不用 pdfrx / syncfusion：
///   · pdfrx 是 PDFium 的 FFI 绑定，pub 缓存里那份 `android/.lib/` 是空的，
///     构建时要联网下 4 个 ABI 的 `libpdfium.so`（本机 `storage.flutter-io.cn`
///     可达但速度只有几十 KB/s，且 CI 无网），风险远大于收益。
///   · 我们只需要「文字 + 坐标」，不需要渲染、不需要表单、不需要加密。
///     而教务导出的课表 PDF 结构极简单：FlateDecode 内容流 + 一种字体。
///
/// 支持范围（够用即止，遇到不支持的情况**明确报错**而不是静默给空白）：
///   · 未压缩 / FlateDecode 的内容流
///   · `Tm` 定位 + `Tj` 单个字符串，以及 `TJ` 数组
///   · 编码：UniGB-UCS2-H / UniGB-UTF16-H（教务课表用的就是这种），
///     以及带 `/ToUnicode` 映射表的子集字体
///   · 拒绝加密 PDF
///
/// 不支持：扫描件（无文字层）、Type3 字体、LZW/ASCII85 以外的特殊滤镜。
/// 遇到这些会抛 [PdfUnsupportedException]，界面据此提示「请上传官网导出
/// 的课表 PDF，不要用扫描件/截图转的 PDF」。
class PdfUnsupportedException implements Exception {
  const PdfUnsupportedException(this.message);
  final String message;

  @override
  String toString() => 'PdfUnsupportedException: $message';
}

/// 一段带坐标的文字。
class PdfTextItem {
  const PdfTextItem({
    required this.text,
    required this.x,
    required this.y,
  });

  final String text;

  /// 页面坐标系下的起点（单位 pt，左上角为原点由调用方自行约定）。
  final double x;
  final double y;

  @override
  String toString() => 'PdfTextItem($x, $y, "$text")';
}

/// 一页的文字。
class PdfPageText {
  const PdfPageText({
    required this.width,
    required this.height,
    required this.items,
    this.rotate = 0,
  });

  /// MediaBox 的宽（未按 [rotate] 交换）。
  final double width;

  /// MediaBox 的高（未按 [rotate] 交换）。
  final double height;

  /// 页面 `/Rotate` 值（0 / 90 / 180 / 270）。
  final int rotate;

  final List<PdfTextItem> items;
}

/// 极简 PDF 解析器。用法：
/// ```dart
/// final doc = MiniPdf.parse(bytes);
/// final pages = doc.extractText();
/// ```
class MiniPdf {
  MiniPdf._(this._bytes);

  final Uint8List _bytes;

  static MiniPdf parse(Uint8List bytes) {
    if (bytes.length < 8) {
      throw const PdfUnsupportedException('文件太小，不像 PDF');
    }
    // 头部允许前面有垃圾字节（有些导出工具会塞 BOM），在头 1KB 内找 %PDF-。
    final head = String.fromCharCodes(
      bytes.take(bytes.length < 1024 ? bytes.length : 1024),
    );
    if (!head.contains('%PDF-')) {
      throw const PdfUnsupportedException('不是有效的 PDF 文件');
    }
    // 加密标志：有 /Encrypt 就直接拒绝，我们不做解密。
    if (head.contains('/Encrypt') ||
        _latin1(bytes).contains('/Encrypt')) {
      throw const PdfUnsupportedException('这个 PDF 被加密了，无法读取文字');
    }
    return MiniPdf._(bytes);
  }

  static String _latin1(Uint8List b) => latin1.decode(b, allowInvalid: true);

  /// 提取所有页的文字（带坐标）。
  List<PdfPageText> extractText() {
    final src = _latin1(_bytes);
    final pages = <PdfPageText>[];

    // 逐个 Page 对象处理。顺序按出现顺序，对课表够用。
    //
    // 🔴 必须容忍 `/Type/Page` 与 `/Type /Page` 两种写法：
    //    教务导出的是紧凑写法（`<</Type/Page/MediaBox[...]>>`），
    //    早期只认带空格的写法 → 一个页面都找不到，报「没有可读的页面」。
    for (final pageObj in _findObjectsByRegex(src, _rePageType)) {
      pages.add(_readPage(src, pageObj));
    }
    if (pages.isEmpty) {
      throw const PdfUnsupportedException('这份 PDF 里没有可读的页面');
    }
    // 一页都抽不到文字 → 大概率是扫描件
    final total = pages.fold<int>(0, (a, p) => a + p.items.length);
    if (total == 0) {
      throw const PdfUnsupportedException(
        '这份 PDF 没有文字层（可能是扫描件或图片转的），无法自动识别课表。\n'
        '请改用教务系统导入，或上传官网「导出课表」生成的 PDF。',
      );
    }
    return pages;
  }

  // ---------------------------------------------------------------- 页面

  PdfPageText _readPage(String src, _PdfObject page) {
    final mediabox = _parseNumbers(page.body, '/MediaBox');
    var width = mediabox.length >= 4 ? mediabox[2] - mediabox[0] : 595.0;
    var height = mediabox.length >= 4 ? mediabox[3] - mediabox[1] : 842.0;
    final rotate = _parseInt(page.body, '/Rotate') ?? 0;

    // 内容流：可能是 /Contents 5 0 R，也可能是 /Contents [5 0 R 6 0 R]
    final contentsRefs = _contentRefs(page.body);
    final toUnicode = _toUnicodeMaps(src, page.body);

    final items = <PdfTextItem>[];
    for (final ref in contentsRefs) {
      final raw = _streamOf(src, ref);
      if (raw == null) continue;
      items.addAll(_decodeContentStream(raw, toUnicode));
    }

    // 🔴 坐标**原样返回内容流里的 Tm 值，不做 cm / Rotate 变换**。
    //
    //    教务导出的 PDF 内容流开头有 `0 1 -1 0 595 0 cm`（把整页旋转 90°），
    //    所以 Tm 里的 x 其实落在 0..842、y 落在 0..595 —— 与 MediaBox
    //    [0 0 595 842] 不是同一套坐标。上层的课表解析只需要**相对位置**
    //    （哪一列、哪一行），不需要绝对坐标，所以把 raw 值原样给出去，
    //    再用 [rotate] 告诉调用方「哪个轴是星期、哪个轴是节次」。
    return PdfPageText(
      width: width,
      height: height,
      rotate: rotate,
      items: items,
    );
  }

  List<int> _contentRefs(String body) {
    // /Contents 5 0 R
    final single = RegExp(r'/Contents\s+(\d+)\s+\d+\s+R').firstMatch(body);
    if (single != null) return [int.parse(single.group(1)!)];
    // /Contents [ 5 0 R 6 0 R ]
    final arr = RegExp(r'/Contents\s*\[([^\]]*)\]').firstMatch(body);
    if (arr != null) {
      return [
        for (final m in RegExp(r'(\d+)\s+\d+\s+R').allMatches(arr.group(1)!))
          int.parse(m.group(1)!),
      ];
    }
    return const [];
  }

  // ------------------------------------------------------- 字体 / 编码

  /// 从页面资源里找出所有字体对象号 → 编码方案。
  ///
  /// 只区分两类：
  ///   · `UCS2`（UniGB-UCS2-H 等）→ 双字节大端即 Unicode
  ///   · 有 `/ToUnicode` 流 → 查映射表
  Map<String, _FontSpec> _toUnicodeMaps(String src, String pageBody) {
    final fonts = <String, _FontSpec>{};
    // 页面自己可能不写 /Resources /Font，而是继承；简化处理：全文档扫字体，
    // 用资源名（F1/F2…）做 key。课表 PDF 每页都是同一套字体，够用。
    for (final f in _findObjectsByRegex(src, _reFontType)) {
      final resName = _resourceName(f.body);
      if (resName == null) continue;
      final base = RegExp(r'/BaseFont\s*/([^\s/>\]]+)').firstMatch(f.body)?.group(1) ?? '';
      final encoding = RegExp(r'/Encoding\s*/([^\s/>\]]+)').firstMatch(f.body)?.group(1) ?? '';
      Map<int, String>? map;
      final tu = RegExp(r'/ToUnicode\s+(\d+)\s+\d+\s+R').firstMatch(f.body);
      if (tu != null) {
        final stream = _streamOf(src, int.parse(tu.group(1)!));
        if (stream != null) map = _parseToUnicode(stream);
      }
      fonts[resName] = _FontSpec(
        resourceName: resName,
        baseFont: base,
        encoding: encoding,
        toUnicode: map,
      );
    }
    return fonts;
  }

  String? _resourceName(String body) {
    // 字体对象本身不带资源名；退而求其次用 BaseFont 当 key。
    final base = RegExp(r'/BaseFont\s*/([^\s/>\]]+)').firstMatch(body)?.group(1);
    return base;
  }

  Map<int, String>? _parseToUnicode(Uint8List stream) {
    final text = latin1.decode(stream, allowInvalid: true);
    final map = <int, String>{};
    for (final block in RegExp(r'beginbfchar(.*?)endbfchar', dotAll: true)
        .allMatches(text)) {
      for (final m in RegExp(r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>')
          .allMatches(block.group(1)!)) {
        map[int.parse(m.group(1)!, radix: 16)] = _hexToUtf16(m.group(2)!);
      }
    }
    for (final block in RegExp(r'beginbfrange(.*?)endbfrange', dotAll: true)
        .allMatches(text)) {
      for (final m in RegExp(
              r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>')
          .allMatches(block.group(1)!)) {
        final lo = int.parse(m.group(1)!, radix: 16);
        final hi = int.parse(m.group(2)!, radix: 16);
        final dst = int.parse(m.group(3)!, radix: 16);
        for (var c = lo; c <= hi && c - lo < 4096; c++) {
          map[c] = String.fromCharCode(dst + (c - lo));
        }
      }
    }
    return map.isEmpty ? null : map;
  }

  String _hexToUtf16(String hex) {
    final buf = <int>[];
    for (var i = 0; i + 3 < hex.length + 1 && i + 4 <= hex.length; i += 4) {
      buf.add(int.parse(hex.substring(i, i + 4), radix: 16));
    }
    return String.fromCharCodes(buf);
  }

  // ------------------------------------------------------- 内容流解码

  /// 把内容流解成「文字 + 坐标」。
  ///
  /// 🔴 必须用**顺序扫描器**，不能用一个大正则：
  ///   UCS2 编码的文字串长得像 `(\x002Th)` —— 高字节 0x00、低字节就是 ASCII
  ///   字母。早期版本用 `[^A-Za-z]` 划界，一进字符串就被 'T'/'h' 截断，
  ///   结果一个 Tj 都匹配不到、整页被当「没有文字层」。
  List<PdfTextItem> _decodeContentStream(
      Uint8List stream, Map<String, _FontSpec> fonts) {
    final tokens = _tokenize(latin1.decode(stream, allowInvalid: true));
    final items = <PdfTextItem>[];
    var currentFont = _FontSpec.identity;
    double tx = 0, ty = 0;
    // 操作数栈：遇到操作符时消费
    final stack = <Object>[];

    for (final t in tokens) {
      if (!t.isOperator) {
        final v = t.value;
        if (v != null) stack.add(v);
        continue;
      }
      switch (t.operator) {
        case 'Tf':
          // /F1 12 Tf —— 第一个操作数是字体资源名
          for (final o in stack) {
            if (o is String && o.startsWith('/')) {
              final name = o.substring(1);
              currentFont = fonts[name] ?? currentFont;
              break;
            }
          }
        case 'Tm':
          final n = _numsOf(stack);
          if (n.length >= 6) {
            tx = n[4];
            ty = n[5];
          }
        case 'Td':
        case 'TD':
          final n = _numsOf(stack);
          if (n.length >= 2) {
            tx += n[0];
            ty += n[1];
          }
        case 'BT':
          tx = 0;
          ty = 0;
        case 'Tj':
        case "'":
        case '"':
          final bytes = _bytesOf(stack);
          if (bytes != null) {
            final text = currentFont.decode(bytes);
            if (text.trim().isNotEmpty) {
              items.add(PdfTextItem(text: text, x: tx, y: ty));
            }
          }
        case 'TJ':
          // [(A) -20 (B)] TJ —— 数组里的所有字符串拼起来
          final buf = StringBuffer();
          for (final o in stack) {
            if (o is Uint8List) buf.write(currentFont.decode(o));
          }
          if (buf.isNotEmpty && buf.toString().trim().isNotEmpty) {
            items.add(PdfTextItem(text: buf.toString(), x: tx, y: ty));
          }
        case 'ET':
          break;
      }
      stack.clear();
    }
    return items;
  }

  List<double> _numsOf(List<Object> stack) => [
        for (final o in stack)
          if (o is double) o,
      ];

  Uint8List? _bytesOf(List<Object> stack) {
    for (final o in stack) {
      if (o is Uint8List) return o;
    }
    return null;
  }

  /// 把内容流切成 token（操作符 / 数字 / 名字 / 字符串 / 数组分隔符）。
  ///
  /// 字符串用括号配对 + 反斜杠转义解析；`<hex>` 解析成字节。
  /// 数组 `[` `]` 只当作透明分隔符 —— 我们只在 TJ 时把栈里的字符串拼起来。
  List<_Token> _tokenize(String s) {
    final out = <_Token>[];
    var i = 0;
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      // 空白
      if (c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C) {
        i++;
        continue;
      }
      // 注释 % 到行尾
      if (c == 0x25) {
        while (i < s.length && s.codeUnitAt(i) != 0x0A) {
          i++;
        }
        continue;
      }
      // 字符串 ( ... ) —— 支持嵌套括号与转义
      if (c == 0x28) {
        final start = i + 1;
        var depth = 1;
        i++;
        while (i < s.length && depth > 0) {
          final ch = s.codeUnitAt(i);
          if (ch == 0x5C) {
            i += 2;
            continue;
          }
          if (ch == 0x28) depth++;
          if (ch == 0x29) depth--;
          if (depth == 0) break;
          i++;
        }
        final raw = s.substring(start, i);
        out.add(_Token.bytes(_unescapePdfString(raw)));
        i++;
        continue;
      }
      // 十六进制串 < ... >
      if (c == 0x3C) {
        final end = s.indexOf('>', i);
        if (end < 0) break;
        final hex = s.substring(i + 1, end).replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
        final padded = hex.length.isEven ? hex : '${hex}0';
        final buf = Uint8List(padded.length ~/ 2);
        for (var k = 0; k < buf.length; k++) {
          buf[k] = int.parse(padded.substring(k * 2, k * 2 + 2), radix: 16);
        }
        out.add(_Token.bytes(buf));
        i = end + 1;
        continue;
      }
      // 数组分隔符：透明
      if (c == 0x5B || c == 0x5D) {
        i++;
        continue;
      }
      // 字典 << >> —— 跳过
      if (c == 0x3E) {
        i += (i + 1 < s.length && s.codeUnitAt(i + 1) == 0x3E) ? 2 : 1;
        continue;
      }
      // 名字 /F1
      if (c == 0x2F) {
        final start = i;
        i++;
        while (i < s.length && !_isDelim(s.codeUnitAt(i))) {
          i++;
        }
        out.add(_Token.op('')); // 占位，下面替换
        out[out.length - 1] = _Token.name(s.substring(start, i));
        continue;
      }
      // 数字
      if (c == 0x2B || c == 0x2D || c == 0x2E || (c >= 0x30 && c <= 0x39)) {
        final start = i;
        i++;
        while (i < s.length &&
            (s.codeUnitAt(i) == 0x2E ||
                s.codeUnitAt(i) == 0x2D ||
                s.codeUnitAt(i) == 0x2B ||
                (s.codeUnitAt(i) >= 0x30 && s.codeUnitAt(i) <= 0x39))) {
          i++;
        }
        final v = double.tryParse(s.substring(start, i));
        if (v != null) out.add(_Token.number(v));
        continue;
      }
      // 操作符
      final start = i;
      while (i < s.length && !_isDelim(s.codeUnitAt(i))) {
        i++;
      }
      if (i == start) i++;
      final word = s.substring(start, i);
      if (word.isNotEmpty) out.add(_Token.op(word));
    }
    return out;
  }

  bool _isDelim(int c) =>
      c == 0x20 ||
      c == 0x0A ||
      c == 0x0D ||
      c == 0x09 ||
      c == 0x0C ||
      c == 0x28 ||
      c == 0x29 ||
      c == 0x3C ||
      c == 0x3E ||
      c == 0x5B ||
      c == 0x5D ||
      c == 0x7B ||
      c == 0x7D ||
      c == 0x2F ||
      c == 0x25;

  Uint8List _unescapePdfString(String s) {
    final out = BytesBuilder();
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c != 0x5C) {
        out.addByte(c & 0xFF);
        continue;
      }
      i++;
      if (i >= s.length) break;
      final n = s.codeUnitAt(i);
      switch (n) {
        case 0x6E: // \n
          out.addByte(10);
        case 0x72:
          out.addByte(13);
        case 0x74:
          out.addByte(9);
        case 0x62:
          out.addByte(8);
        case 0x66:
          out.addByte(12);
        case 0x28:
          out.addByte(0x28);
        case 0x29:
          out.addByte(0x29);
        case 0x5C:
          out.addByte(0x5C);
        default:
          if (n >= 0x30 && n <= 0x37) {
            var oct = n - 0x30;
            var count = 1;
            while (i + 1 < s.length && count < 3) {
              final d = s.codeUnitAt(i + 1);
              if (d < 0x30 || d > 0x37) break;
              oct = oct * 8 + (d - 0x30);
              i++;
              count++;
            }
            out.addByte(oct & 0xFF);
          } else {
            out.addByte(n & 0xFF);
          }
      }
    }
    return out.toBytes();
  }

  // -------------------------------------------------------------- 对象

  /// `/Type /Page`（注意 `/Pages` 也以 `/Page` 开头，正则里排除掉）。
  static final RegExp _rePageType = RegExp(r'/Type\s*/Page(?![s])');
  static final RegExp _reFontType = RegExp(r'/Type\s*/Font(?![s])');

  List<_PdfObject> _findObjectsByRegex(String src, RegExp marker) {
    final out = <_PdfObject>[];
    for (final m in RegExp(r'(\d+)\s+(\d+)\s+obj\b').allMatches(src)) {
      final start = m.end;
      final end = src.indexOf('endobj', start);
      if (end < 0) continue;
      final body = src.substring(start, end);
      if (!marker.hasMatch(body)) continue;
      out.add(_PdfObject(
        num: int.parse(m.group(1)!),
        body: body,
        offset: m.start,
      ));
    }
    return out;
  }

  /// 取对象号对应的**解码后**流数据。
  Uint8List? _streamOf(String src, int objNum) {
    final re = RegExp(r'(?<![0-9])' + objNum.toString() + r'\s+0\s+obj\b');
    final m = re.firstMatch(src);
    if (m == null) return null;
    final start = m.end;
    // 找 stream
    final sIdx = src.indexOf('stream', start);
    if (sIdx < 0) return null;
    final dict = src.substring(start, sIdx);
    var dataStart = sIdx + 'stream'.length;
    if (dataStart < src.length && src.codeUnitAt(dataStart) == 0x0D) dataStart++;
    if (dataStart < src.length && src.codeUnitAt(dataStart) == 0x0A) dataStart++;
    final eIdx = src.indexOf('endstream', dataStart);
    if (eIdx < 0) return null;
    // 🔴 两个下标都要夹：`indexOf('stream')` 可能命中字符串字面量里的
    //    "stream"（比如内容流里的注释），此时 dataStart 可以越过文件末尾
    //    或越过 eIdx，`sublist` 会抛 RangeError —— 那不是
    //    PdfUnsupportedException，会一路穿到页面，用户读到
    //    「读取 PDF 失败：RangeError: Invalid value…」，
    //    把「文件损坏」说成了程序 bug。
    final safeStart = dataStart.clamp(0, _bytes.length);
    final safeEnd = eIdx.clamp(safeStart, _bytes.length);
    if (safeEnd <= safeStart) return null;
    final raw = Uint8List.fromList(_bytes.sublist(safeStart, safeEnd));
    if (dict.contains('/FlateDecode')) {
      try {
        return Uint8List.fromList(ZLibDecoder().convert(raw));
      } catch (_) {
        return null;
      }
    }
    if (dict.contains('/Filter')) {
      // LZW / ASCII85 等 —— 明确不支持
      return null;
    }
    return raw;
  }

  List<double> _numbers(String s) => [
        for (final m in RegExp(r'-?\d+(?:\.\d+)?').allMatches(s))
          double.parse(m.group(0)!),
      ];

  List<double> _parseNumbers(String body, String key) {
    final m = RegExp(RegExp.escape(key) + r'\s*\[([^\]]*)\]').firstMatch(body);
    if (m == null) return const [];
    return _numbers(m.group(1)!);
  }

  int? _parseInt(String body, String key) {
    final m = RegExp(RegExp.escape(key) + r'\s+(-?\d+)').firstMatch(body);
    return m == null ? null : int.parse(m.group(1)!);
  }
}

class _PdfObject {
  _PdfObject({required this.num, required this.body, required this.offset});
  final int num;
  final String body;
  final int offset;
}

/// 一个字体的解码规则。
class _FontSpec {
  const _FontSpec({
    required this.resourceName,
    required this.baseFont,
    required this.encoding,
    this.toUnicode,
  });

  final String resourceName;
  final String baseFont;
  final String encoding;
  final Map<int, String>? toUnicode;

  static const _FontSpec identity = _FontSpec(
    resourceName: '',
    baseFont: '',
    encoding: '',
  );

  bool get isUcs2 =>
      encoding.toUpperCase().contains('UCS2') ||
      encoding.toUpperCase().contains('UTF16') ||
      baseFont.toUpperCase().contains('UCS2') ||
      baseFont.toUpperCase().contains('UTF16');

  String decode(Uint8List bytes) {
    if (toUnicode != null) {
      final buf = StringBuffer();
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        final code = (bytes[i] << 8) | bytes[i + 1];
        buf.write(toUnicode![code] ?? '');
      }
      if (buf.isNotEmpty) return buf.toString();
    }
    if (isUcs2 || bytes.length.isEven) {
      return String.fromCharCodes([
        for (var i = 0; i + 1 < bytes.length; i += 2)
          (bytes[i] << 8) | bytes[i + 1],
      ]);
    }
    return latin1.decode(bytes, allowInvalid: true);
  }
}

/// 内容流里的一个 token。
class _Token {
  _Token._({
    required this.isOperator,
    this.operator = '',
    this.value,
  });

  factory _Token.op(String w) => _Token._(isOperator: true, operator: w);

  factory _Token.name(String n) =>
      _Token._(isOperator: false, value: n); // '/F1'

  factory _Token.number(double v) => _Token._(isOperator: false, value: v);

  factory _Token.bytes(Uint8List b) => _Token._(isOperator: false, value: b);

  final bool isOperator;
  final String operator;

  /// String（名字）/ double（数字）/ Uint8List（字符串字节）
  final Object? value;
}

