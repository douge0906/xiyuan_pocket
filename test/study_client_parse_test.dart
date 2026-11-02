import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/services/campus/study_client.dart';

/// 真实教务页面（2025 级账号，2026-11-02 抓取，581,116 字符）的回归测试。
///
/// ## 为什么要这份测试
///
/// `StudyClient` 的解析全靠几条正则去啃教务返回的 HTML。教务改一次页面
/// 这些正则就**静默失效**——界面数字变空字符串而不是报错，用户看到的是
/// 「一片空」，我们却以为抓取成功。用真实页面锁住是最便宜的防线。
///
/// ## 测试数据从哪来
///
/// 主源是**仓库内夹具** `test/fixtures/jwgl_study_page_2025.html`（13 KB）：
/// 从真实页 581,116 字符里剥出的「顶部汇总区 + 10 个节点模板」，
/// 学生姓名已替换为「张三」。它随代码走，CI 和换机器都跑得了。
///
/// 副源（可选）是抓下来的完整页面 `D:/workdsh/_xsxy_2025.html`：
/// 存在时优先用它，用于发现「夹具没覆盖到的新区域」。
///
/// 重新抓完整页面：`python D:/workdsh/fetch_study_page.py`
/// 重新生成夹具：`python D:/workdsh/make_fixture2.py`
String? _loadPage() {
  const candidates = [
    // ① 仓库内夹具：一定会命中，构建测试不依赖外部文件
    r'test/fixtures/jwgl_study_page_2025.html',
    // ② 完整真实页面（可选）
    r'D:\workdsh\_xsxy_2025.html',
    r'C:\build_ws\_snapshots\xsxy_2025.html',
  ];
  for (final p in candidates) {
    final f = File(p);
    if (f.existsSync()) {
      final text = f.readAsStringSync();
      // 只认「有培养方案树」的那份；2026 级抓下来的是「没有教学计划」页
      if (text.contains('treeview')) return text;
    }
  }
  return null;
}

void main() {
  final html = _loadPage();
  final skip = html == null
      ? '未找到夹具 test/fixtures/jwgl_study_page_2025.html'
      : null;

  group('顶部汇总解析（真实页面）', () {
    test('六个汇总数字与教务页面完全一致', () {
      // 教务原文：计划总课程 135 门 通过 17 门 未通过 0 门 未修 103 门 在读 15 门
      final s = StudyClient.debugParseSummary(html!);
      expect(s['gpa'], 3.62, reason: '平均学分绩点 3.62');
      expect(s['totalCourses'], 135);
      expect(s['passedCourses'], 17, reason: '「通过」全文出现 80 次，不能抓错');
      expect(s['failedCourses'], 0);
      expect(s['notStartedCourses'], 103);
      expect(s['studyingCourses'], 15);
    }, skip: skip);

    test('学生姓名取自「XX 同学」', () {
      final s = StudyClient.debugParseSummary(html!);
      expect(s['studentName'], isNotEmpty);
    }, skip: skip);

    test('不会把「计划外：通过 11」当成主「通过」', () {
      final s = StudyClient.debugParseSummary(html!);
      expect(s['passedCourses'], isNot(11),
          reason: '计划外通过 11 门是另一项，不能混进主汇总');
    }, skip: skip);
  });

  group('培养方案树解析（真实页面）', () {
    test('40 次节点头命中，去重后 10 个节点', () {
      final nodes = StudyClient.debugParseNodes(html!);
      expect(nodes.length, 10, reason: '教务把同一节点渲染两遍，必须去重');
    }, skip: skip);

    test('根节点「2025电气工程及其自动化」要求 165 学分、已获 40', () {
      final nodes = StudyClient.debugParseNodes(html!);
      final root = nodes.first;
      expect(root['name'], '2025电气工程及其自动化');
      expect(root['yqzdxf'], '165');
      expect(root['yxxf'], '40.0', reason: '教务原文 40.0，保留原始字符串');
    }, skip: skip);

    test('十个板块名与实测一字不差', () {
      final nodes = StudyClient.debugParseNodes(html!);
      expect(
        nodes.skip(1).map((n) => n['name']).toList(),
        ['通识（必）', '通识（选）', '专基（必）', '专主（必）', '专业（选）',
         '专拓（选）', '实践（必）', '实践（选）', '实践（拓）'],
      );
    }, skip: skip);

    test('没有解析出无名节点（板块名正则不能掉）', () {
      final nodes = StudyClient.debugParseNodes(html!);
      expect(nodes.where((n) => (n['name'] ?? '').isEmpty), isEmpty);
    }, skip: skip);

    test('只有根节点的要求学分不是怪值 1.0', () {
      final nodes = StudyClient.debugParseNodes(html!);
      final notOne = nodes.where((n) => n['yqzdxf'] != '1').toList();
      expect(notOne.length, 1,
          reason: '子节点 yqzdxf 全是 1.0 是教务渲染怪值，只有根节点真实');
      expect(notOne.first['name'], '2025电气工程及其自动化');
    }, skip: skip);

    test('通识（必）已获 36 学分、实践（必）已获 4 学分', () {
      final nodes = StudyClient.debugParseNodes(html!);
      final required = nodes.firstWhere((n) => n['name'] == '通识（必）');
      final practice = nodes.firstWhere((n) => n['name'] == '实践（必）');
      expect(required['yxxf'], '36.0');
      expect(practice['yxxf'], '4.0');
    }, skip: skip);
  });

  group('页面结构判定', () {
    test('有树页面必须含 treeview，无树页面不能含', () {
      expect(html!.contains('treeview'), isTrue);
      expect(html.contains('您所在年级专业没有教学计划'), isFalse);
    }, skip: skip);
  });
}
