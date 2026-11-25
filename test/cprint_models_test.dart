import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/campus/cprint_models.dart';

/// 云打印扫描件的解析回归。
///
/// 两件事必须钉死：
/// 1. **`result: null` 是正常返回**（2026-11-25 实测该账号名下无扫描件时后端
///    就是这么回的），不是错误，更不能让页面崩；
/// 2. **过期只看 `dwStatus & 256`**，站点前端 `scanDoc.html` 用这一个位判定，
///    另加任何「30 天自动清理」都是设计稿的示意图，接口里没有这个字段。
void main() {
  group('云打印 · 扫描件解析', () {
    test('result 为 null 当空列表（真实后端返回）', () {
      final r = CprintScanItem.parseList({
        'code': 0,
        'message': '',
        'result': null,
      });
      expect(r.ok, isTrue);
      expect(r.items, isEmpty);
      expect(r.needReauth, isFalse);
    });

    test('result 为空数组同样是空列表', () {
      final r = CprintScanItem.parseList({
        'code': 0,
        'message': '',
        'result': <dynamic>[],
      });
      expect(r.ok, isTrue);
      expect(r.items, isEmpty);
    });

    test('code 4 = 会话失效，必须要求重新授权', () {
      final r = CprintScanItem.parseList({
        'code': CprintError.notLoggedIn,
        'message': '无效会话，未登录',
        'result': null,
      });
      expect(r.ok, isFalse);
      expect(r.needReauth, isTrue);
      expect(r.message, '无效会话，未登录');
    });

    test('正常条目：字段映射、大小换算、过期位', () {
      final r = CprintScanItem.parseList({
        'code': 0,
        'message': '',
        'result': [
          {
            'dwJobId': '20261124112233445566',
            'szDisplayName': '成绩单.pdf',
            'dwFileSize': 2048,
            'dwSubmitDate': '2026.11.24',
            'dwSubmitTime': '11:22:33',
            'dwStatus': 1,
          },
          {
            'dwJobId': '20261001000000000001',
            'szDisplayName': '旧作业.jpg',
            'dwFileSize': 600,
            'dwSubmitDate': '2026.10.01',
            'dwSubmitTime': '08:00:00',
            'dwStatus': 257, // 1 | 256 → 已过期
          },
        ],
      });
      expect(r.items.length, 2);
      final first = r.items.first;
      expect(first.jobId, '20261124112233445566');
      expect(first.displayName, '成绩单.pdf');
      expect(first.sizeLabel, '2KB');
      expect(first.isExpired, isFalse);
      expect(first.docType.classType, 'pdf');
      expect(first.submittedAt, DateTime(2026, 11, 24, 11, 22, 33));
      final second = r.items[1];
      expect(second.isExpired, isTrue, reason: 'dwStatus & 256 != 0 才是过期');
      expect(second.sizeLabel, '600B');
      expect(second.docType.classType, 'img');
    });

    test('缺 dwJobId 的条目整条丢弃，其余字段缺就取默认值', () {
      final r = CprintScanItem.parseList({
        'code': 0,
        'result': [
          {'szDisplayName': '没有 id 的行.pdf'},
          {'dwJobId': 'ok-1'},
        ],
      });
      expect(r.items.length, 1);
      expect(r.items.first.jobId, 'ok-1');
      expect(r.items.first.displayName, '未命名文件',
          reason: '后端没给文件名时落盘不能是空名字，模型层给了兜底');
      expect(r.items.first.fileSize, 0);
      expect(r.items.first.isExpired, isFalse);
    });

    test('sortKey 复刻站点的「日期拼时间再转数字」，可按提交时间倒序', () {
      CprintScanItem make(String date, String time) {
        final r = CprintScanItem.parseList({
          'code': 0,
          'result': [
            {
              'dwJobId': 'j-$date-$time',
              'szDisplayName': 'a.pdf',
              'dwFileSize': 1,
              'dwSubmitDate': date,
              'dwSubmitTime': time,
            }
          ],
        });
        return r.items.first;
      }

      final older = make('2026.10.01', '08:00:00');
      final newer = make('2026.11.24', '11:22:33');
      expect(newer.sortKey, greaterThan(older.sortKey));
    });
  });

  group('云打印 · 文件类型推导', () {
    // 站点 cprint_common.js 的 Cprint.getDocType 逐分支复刻，
    // 包括它把 xlsx 写成了 xslx：真实文件扩展名就是 xslx 时也要认。
    test('常见类型', () {
      expect(CprintDocType.fromName('a.pdf').classType, 'pdf');
      expect(CprintDocType.fromName('a.PNG').classType, 'img');
      expect(CprintDocType.fromName('a.docx').classType, 'word');
      expect(CprintDocType.fromName('a.xlsx').classType, 'excel');
      expect(CprintDocType.fromName('a.xslx').classType, 'excel', reason: '站点拼写错误也要兼容');
      expect(CprintDocType.fromName('a.docx').classType, 'word');
      expect(CprintDocType.fromName('a.csv').classType, 'word');
      expect(CprintDocType.fromName('a.pptx').classType, 'ppt');
      expect(CprintDocType.fromName('a.html').classType, 'txt');
      expect(CprintDocType.fromName('a.7z').classType, 'other');
    });

    test('浏览器重复下载产生的 a.pdf[1] 要截断方括号', () {
      final t = CprintDocType.fromName('扫描件.pdf[1]');
      expect(t.classType, 'pdf');
      expect(t.type, 'pdf');
    });

    test('没有扩展名 / 空文件名不猜类型', () {
      expect(CprintDocType.fromName('没有扩展名').classType, 'other');
      expect(CprintDocType.fromName('').classType, 'other');
    });
  });

  group('云打印 · 落盘文件名', () {
    test('safeFileName 换掉路径分隔符等非法字符', () {
      final r = CprintScanItem.parseList({
        'code': 0,
        'result': [
          {
            'dwJobId': 'x',
            'szDisplayName': 'a/b:c*d?.pdf',
            'dwFileSize': 1,
            'dwSubmitDate': '2026.11.24',
            'dwSubmitTime': '10:00:00',
          }
        ],
      });
      final name = r.items.first.safeFileName;
      expect(name.contains('/'), isFalse);
      expect(name.contains(':'), isFalse);
      expect(name.contains('*'), isFalse);
      expect(name.contains('?'), isFalse);
      expect(name.endsWith('.pdf'), isTrue);
    });

    test('超长文件名截断但保留扩展名', () {
      final long = '${'很长的名字' * 40}.pdf';
      final r = CprintScanItem.parseList({
        'code': 0,
        'result': [
          {
            'dwJobId': 'x',
            'szDisplayName': long,
            'dwFileSize': 1,
            'dwSubmitDate': '2026.11.24',
            'dwSubmitTime': '10:00:00',
          }
        ],
      });
      final name = r.items.first.safeFileName;
      expect(name.length, lessThanOrEqualTo(80));
      expect(name.endsWith('.pdf'), isTrue);
    });
  });

  group('云打印 · 日期解析', () {
    test('2026.11.24 + 11:22:33 合成 DateTime', () {
      final r = CprintScanItem.parseList({
        'code': 0,
        'result': [
          {
            'dwJobId': 'x',
            'szDisplayName': 'a.pdf',
            'dwFileSize': 1,
            'dwSubmitDate': '2026.11.24',
            'dwSubmitTime': '11:22:33',
          }
        ],
      });
      expect(r.items.first.submittedAt, DateTime(2026, 11, 24, 11, 22, 33));
    });

    test('解析不出来返回 null，不猜当前时间', () {
      final r = CprintScanItem.parseList({
        'code': 0,
        'result': [
          {
            'dwJobId': 'x',
            'szDisplayName': 'a.pdf',
            'dwFileSize': 1,
            'dwSubmitDate': '',
            'dwSubmitTime': '',
          }
        ],
      });
      expect(r.items.first.submittedAt, isNull);
    });
  });

  group('云打印 · toJson 往返', () {
    test('item 可以 JSON 往返（本地索引要靠它）', () {
      final r = CprintScanItem.parseList({
        'code': 0,
        'result': [
          {
            'dwJobId': 'job-1',
            'szDisplayName': '成绩单.pdf',
            'dwFileSize': 4096,
            'dwSubmitDate': '2026.11.24',
            'dwSubmitTime': '11:22:33',
            'dwStatus': 3,
          }
        ],
      });
      final back = jsonDecode(jsonEncode(r.items.first.toJson()));
      final again = CprintScanItem.fromJson(back);
      expect(again, isNotNull);
      expect(again!.jobId, 'job-1');
      expect(again.displayName, '成绩单.pdf');
      expect(again.fileSize, 4096);
      expect(again.status, 3);
    });
  });
}
