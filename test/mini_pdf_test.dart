import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/pdf/mini_pdf.dart';

/// 用真实教务导出的课表 PDF 做回归：
/// `test/fixtures/course_table_sample.pdf`（7,393 B，3 页，每页 /Rotate 90，
/// 字体 STSong-Light-UniGB-UCS2-H）
void main() {
  late Uint8List bytes;

  setUpAll(() {
    bytes = File('test/fixtures/course_table_sample.pdf').readAsBytesSync();
  });

  test('能读出三页，且每页都有文字', () {
    final doc = MiniPdf.parse(bytes);
    final pages = doc.extractText();
    expect(pages.length, 3);
    for (final p in pages) {
      expect(p.items, isNotEmpty, reason: '每页都应抽到文字');
    }
  });

  test('抽出的是中文而非乱码（UCS2 解码正确）', () {
    final pages = MiniPdf.parse(bytes).extractText();
    final all = pages.expand((p) => p.items).map((e) => e.text).join('\n');
    // 页眉
    expect(all, contains('2026-2027学年第1学期'));
    expect(all, contains('车雷课表'));
    expect(all, contains('学号：25350103'));
    // 表头
    for (final d in ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日']) {
      expect(all, contains(d), reason: '应含星期表头 $d');
    }
  });

  test('课程格子里的字段能完整还原（含场地与教师）', () {
    final pages = MiniPdf.parse(bytes).extractText();
    final all = pages.expand((p) => p.items).map((e) => e.text).join('');
    expect(all, contains('模拟电子技术基础'));
    expect(all, contains('C5科教中心124'));
    expect(all, contains('闫纪源'));
    expect(all, contains('(1-2节)1-15周(单)'));
  });

  test('/Rotate 90 原样上报，坐标不做变换（上层按 rotate 自行取轴）', () {
    final pages = MiniPdf.parse(bytes).extractText();
    final p = pages.first;
    // MediaBox 原值：595×842
    expect(p.width, 595);
    expect(p.height, 842);
    expect(p.rotate, 90);
    // 内容流里有 `0 1 -1 0 595 0 cm`，所以 Tm 的 x 落在 0..842、y 落在 0..595
    expect(p.items.every((it) => it.x >= -1 && it.x <= 843), isTrue);
    expect(p.items.every((it) => it.y >= -1 && it.y <= 596), isTrue);
  });

  test('非 PDF 文件抛明确异常，不静默返回空', () {
    expect(
      () => MiniPdf.parse(Uint8List.fromList(List.filled(64, 65))),
      throwsA(isA<PdfUnsupportedException>()),
    );
  });
}
