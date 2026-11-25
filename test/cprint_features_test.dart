import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/campus/cprint_models.dart';

/// 云打印「打印文档 / 打印点 / 使用记录 / 上传」四块的数据解析回归。
///
/// 这四个功能的接口返回形状完全不统一：
/// - `PrintJob/Get` 的 `szPaperDetail` 是**字符串形式的 JSON**（要再 parse 一次）；
/// - `Station/GetList` 的 `dwStatus` 是**位掩码**，`dwTrayPaper1..4` 是四个独立字段；
/// - `Report/DetailPageEx` 的金额是**分**，要除 100；
/// - `CloudPrint/Upload` **永远不返回 JSON**，结果藏在 302 的 Location query 里。
///
/// 任何一条解析错都会让用户看到错误的信息（或直接空列表），所以逐条钉住。
void main() {
  group('打印文档', () {
    test('真实返回样本：文件名、时间、纸型、单双面', () {
      // 2026-11-25 实测该账号队列里的那一条，字段一字未改。
      final jobs = CprintPrintJob.parseList({
        'result': [
          {
            'dwJobId': 2496108,
          'dwOldJobId': 0,
          'dwProperty': 16777216,
          'dwCreateDate': 20261124,
          'dwCreateTime': 154847,
          'dwStatus': 1,
          'dwCopies': 1,
          'dwPages': 1,
          'dwFee': 0,
          'szAttribe': 'single,',
          'szPaperDetail':
              '[{"dwPaperID":9,"dwBWPages":1,"dwColorPages":0,"dwPaperNum":1}]',
          'szJobName':
              'Screenshot_2026-11-24-15-56-55-35_8b7aa5be40a89c6a7df806c347da652a.jpg',
          }
        ]});
      expect(jobs, hasLength(1));
      final j = jobs.first;
      expect(j.jobId, '2496108');
      expect(j.docType.classType, 'img');
      expect(j.submittedAtLabel, '2026.11.24 15:48');
      expect(j.rawCreateTime, '154847');
      expect(j.paperLabel, 'A4');
      expect(j.isColor, isFalse);
      expect(j.colorLabel, '黑白');
      expect(j.duplexLabel, '单面');
      expect(j.totalPages, 1);
      expect(j.sizeLabel, '1 页 × 1 份');
    });

    test('szPaperDetail 是字符串要二次解析；坏 JSON 不能让整条任务消失', () {
      final jobs = CprintPrintJob.parseList({
        'result': [
          {
            'dwJobId': 1,
          'szJobName': 'a.pdf',
          'dwCreateDate': 20260101,
          'dwCreateTime': 90000,
            'szPaperDetail': 'not json at all',
          }
        ]});
      expect(jobs, hasLength(1), reason: '纸型解析失败不能把这条任务丢掉');
      expect(jobs.first.papers, isEmpty);
      expect(jobs.first.paperLabel, isEmpty, reason: '解析不出来就不显示纸型');
    });

    test('彩色 + 双面长边', () {
      final jobs = CprintPrintJob.parseList({
        'result': [
          {
            'dwJobId': 2,
          'szJobName': 'b.docx',
          'dwCreateDate': 20260101,
          'dwCreateTime': 90000,
          'dwCopies': 3,
          'dwPages': 5,
          'szAttribe': 'vdup,color',
          'szPaperDetail':
                '[{"dwPaperID":9,"dwBWPages":5,"dwColorPages":2,"dwPaperNum":1}]',
          }
        ]});
      final j = jobs.first;
      expect(j.isColor, isTrue);
      expect(j.colorLabel, '彩色');
      expect(j.duplexLabel, '双面长边');
      expect(j.sizeLabel, '5 页 × 3 份');
    });

    test('没有 dwJobId 的条目丢掉', () {
      expect(CprintPrintJob.parseList([
        {'szJobName': 'x.pdf'}
      ]), isEmpty);
    });

    test('result 为 null / 空数组 / 非数组都当空列表', () {
      expect(CprintPrintJob.parseList(null), isEmpty);
      expect(CprintPrintJob.parseList(<dynamic>[]), isEmpty);
      expect(CprintPrintJob.parseList({'a': 1}), isEmpty);
    });
  });

  group('打印点', () {
    test('真实样本：空闲 / A4+A3 / 打印复印扫描彩色', () {
      final list = CprintStation.parseList({
        'result': [
          {
            'dwDevSN': 1001,
          'dwProperty': 95,
          'dwStatus': 1,
          'dwTrayPaper1': 9,
          'dwTrayPaper2': 8,
          'dwTrayPaper3': 0,
          'dwTrayPaper4': 0,
          'szName': '四楼彩色打印',
          'szStatInfo': '系统空闲',
            'szPrtDriver': 'TOSHIBA Universal PS3',
          }
        ]});
      final s = list.single;
      expect(s.name, '四楼彩色打印');
      expect(s.stateLabel, '空闲');
      expect(s.stateFlag, 2);
      expect(s.paperLabel, 'A4、A3');
      expect(s.functionLabel, '打印 · 复印 · 扫描 · 彩色');
    });

    test('dwStatus == 0 是「未开放」，不是「空闲」', () {
      final s = CprintStation.fromJson({'dwDevSN': 1001, 'dwStatus': 0})!;
      expect(s.stateLabel, '未开放');
      expect(s.stateFlag, 3);
    });

    test('忙碌位：dwStatus & 2', () {
      final s = CprintStation.fromJson({'dwDevSN': 1001, 'dwStatus': 2})!;
      expect(s.stateLabel, '忙碌');
      expect(s.stateFlag, 1);
    });

    test('故障位优先取 szStatInfo 里 "-" 前那段', () {
      final s = CprintStation.fromJson({
        'dwDevSN': 1001,
        'dwStatus': 200,
        'szStatInfo': '缺纸-请补充 A4',
      })!;
      expect(s.stateLabel, '缺纸');
      expect(s.stateFlag, 3);
    });

    test('托盘 3 的 A3 不能被漏掉（站点前端那个少下标的 bug 不复刻）', () {
      final s = CprintStation.fromJson({
        'dwDevSN': 1001,
        'dwStatus': 1,
        'dwTrayPaper1': 9,
        'dwTrayPaper2': 9,
        'dwTrayPaper3': 8,
      })!;
      expect(s.paperLabel, 'A4、A3', reason: 'dwTrayPaper3 也必须参与纸型推导');
    });

    test('dwProperty 低四位：打印/复印/扫描/彩色', () {
      expect(
        CprintStation.fromJson({'dwDevSN': 1, 'dwStatus': 1, 'dwProperty': 4})!
            .functionLabel,
        '扫描',
      );
      expect(
        CprintStation.fromJson({'dwDevSN': 1, 'dwStatus': 1, 'dwProperty': 0})!
            .functionLabel,
        isEmpty,
      );
    });

    test('dwDevSN 为 0 的条目丢掉（服务端的占位行）', () {
      expect(CprintStation.parseList([
        {'dwDevSN': 0, 'szName': 'x'}
      ]), isEmpty);
    });

    test('按服务商分组：devSN ~/ 1000 == srv.sn，算不出来的归「其他打印点」', () {
      const r = CprintStationResult(
        srvs: [CprintSrv(sn: 1, name: 'OPMServer')],
        stations: [
          CprintStation(
              devSn: 1001,
              name: 'A',
              property: 1,
              status: 1,
              statusInfo: '',
              driver: '',
              trays: []),
          CprintStation(
              devSn: 1002,
              name: 'B',
              property: 1,
              status: 1,
              statusInfo: '',
              driver: '',
              trays: []),
          CprintStation(
              devSn: 2999,
              name: 'C',
              property: 1,
              status: 1,
              statusInfo: '',
              driver: '',
              trays: []),
        ],
        errorCode: 0,
        message: '',
      );
      final grouped = r.grouped;
      final names = grouped.keys.map((e) => e.name).toList();
      expect(names, contains('OPMServer'));
      expect(names, contains('其他打印点'));
      expect(
        grouped.entries.firstWhere((e) => e.key.sn == 1).value,
        hasLength(2),
      );
    });
  });

  group('使用记录', () {
    test('金额是分，要除 100；结算方式低 8 位 == 4 为手工收费', () {
      final page = CprintRecordPage.parse({
        'code': 0,
        'message': '',
        'dwPageNo': 1,
        'dwTotalPage': 2,
        'result': [
          {
            'dwDate': 20261124,
            'dwTime': 1548,
            'dwPaperID': 9,
            'dwPageNo': 3,
            'dwSettleType': 4,
            'dwUsedCardMoney': 10,
            'dwUsedFreeMoney': 5,
            'dwUsedMoney': 5,
          }
        ],
      });
      expect(page.ok, isTrue);
      expect(page.pageNo, 1);
      expect(page.totalPage, 2);
      final r = page.items.single;
      expect(r.dateLabel, '2026.11.24');
      expect(r.timeLabel, '15:48');
      expect(r.paperLabel, 'A4');
      expect(r.pages, 3);
      expect(r.settleLabel, '手工收费');
      expect(r.moneyLabel, '0.20 元');
      expect(r.moneyYuan, closeTo(0.2, 1e-9));
    });

    test('低 8 位不是 4 → 自助收费（高位掩码不能干扰）', () {
      // 0x100 = 256，低 8 位是 0，不是 4 → 自助收费。
      final r = CprintRecord.fromJson({'dwSettleType': 256})!;
      expect(r.settleLabel, '自助收费');
    });

    test('解析失败给中文提示，不抛异常', () {
      final page = CprintRecordPage.parse('随便一段 HTML');
      expect(page.ok, isFalse);
      expect(page.items, isEmpty);
      expect(page.message, isNotEmpty);
    });

    test('result 为 null 当空列表', () {
      final page = CprintRecordPage.parse({
        'code': 0,
        'result': null,
      });
      expect(page.ok, isTrue);
      expect(page.items, isEmpty);
    });
  });

  group('上传结果（从 302 Location 里读）', () {
    test('真实成功样本：code=0 fee=20', () {
      const loc =
          'http://zzwy.cwxu.edu.cn:9130/client/new/cprintPc/result.html?code=0&fee=20&message=';
      final r = CprintUploadResult.parseLocation(loc);
      expect(r.ok, isTrue);
      expect(r.feeFen, 20);
      expect(r.feeLabel, '0.20 元');
    });

    test('失败时 message 是 URL 编码的中文，要解码', () {
      const loc =
          'http://x/client/new/cprintPc/result.html?code=1&fee=0&message=%E6%96%87%E4%BB%B6%E8%BF%87%E5%A4%A7';
      final r = CprintUploadResult.parseLocation(loc);
      expect(r.ok, isFalse);
      expect(r.message, '文件过大');
      expect(r.feeLabel, isEmpty);
    });

    test('Location 是 garbage 时不抛异常，按失败处理', () {
      final r = CprintUploadResult.parseLocation('not a url');
      expect(r.ok, isFalse);
    });
  });
}
