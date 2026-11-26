import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/message.dart';
import 'package:xiyuan_pocket/services/message_archive.dart';
import 'package:xiyuan_pocket/services/message_source.dart';
import 'package:xiyuan_pocket/services/sources/daily_digest_source.dart';

/// 「每日消息」是**汇总视图**，不是抓取源。这里锁住它四条不变量：
/// ① 只看近 3 天 ② 给每条打上原栏目名当来源标识 ③ 保持原 sourceId（已读状态
/// 与详情路由都靠它）④ 一个请求都不发。
String _d(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Message _m(String id, String sourceId, String date) =>
    Message(id: id, sourceId: sourceId, title: '标题$id', date: date, url: '');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  final today = DateTime.now();
  final yesterday = today.subtract(const Duration(days: 1));
  final twoDaysAgo = today.subtract(const Duration(days: 2));
  final threeDaysAgo = today.subtract(const Duration(days: 3));
  final longAgo = today.subtract(const Duration(days: 30));

  group('每日消息（近 3 天汇总）', () {
    test('汇总源自己从不写档案 → hasArchive() 恒为 false（铺档案时不能按它过滤）', () async {
      // 🔴 2026-11-26 实机：「每日消息」进页面永远是「暂无内容 / 下拉可刷新」，
      //    因为 primeArchives 用 hasArchive() 过滤，把汇总源整趟跳过了，它只能
      //    等 refreshAll 排到最后（前面 10 个源联网跑完）才算。修法在
      //    MessageRepository.primeArchives：铺完别人的档案后，再单独算汇总源。
      final src = DailyDigestSource(subscribedIds: const {'jwc'});
      await MessageArchive.save('jwc', [_m('a', 'jwc', _d(today))]);
      expect(src.isLocalOnly, isTrue);
      expect(await src.hasArchive(), isFalse);
    });

    test('近 3 天保留，第 4 天起丢掉', () async {
      await MessageArchive.save('jwc', [
        _m('a', 'jwc', _d(today)),
        _m('b', 'jwc', _d(yesterday)),
        _m('c', 'jwc', _d(twoDaysAgo)),
        _m('d', 'jwc', _d(threeDaysAgo)),
        _m('e', 'jwc', _d(longAgo)),
      ]);

      final page = await DailyDigestSource(subscribedIds: {'jwc'})
          .fetch(mode: FetchMode.cached);

      expect(page.items.map((m) => m.id), ['a', 'b', 'c']);
      expect(page.total, 3);
      expect(page.fromCache, isTrue);
    });

    test('没订阅的栏目不参与汇总', () async {
      await MessageArchive.save('jwc', [_m('a', 'jwc', _d(today))]);
      await MessageArchive.save('news', [_m('n', 'news', _d(today))]);

      final page = await DailyDigestSource(subscribedIds: {'jwc'}).fetch(
        mode: FetchMode.cached,
      );

      expect(page.items.map((m) => m.id), ['a']);
    });

    test('🔴 来源标识 = 原栏目名，但 sourceId 必须保持原栏目', () async {
      await MessageArchive.save('jwc', [_m('a', 'jwc', _d(today))]);
      await MessageArchive.save('tw', [_m('t', 'tw', _d(today))]);

      final page = await DailyDigestSource(subscribedIds: {'jwc', 'tw'}).fetch(
        mode: FetchMode.cached,
      );

      final byId = {for (final m in page.items) m.id: m};
      // 来源小标识
      expect(byId['a']!.badge, '教务处');
      expect(byId['t']!.badge, '团委');
      // 🔴 sourceId 原样保留 —— 已读状态的键是 `<sourceId>:<id>`，
      // 改成 daily 会让同一条公告在两处各有一套已读状态；
      // 详情页也要靠它找回原栏目的加载器。
      expect(byId['a']!.sourceId, 'jwc');
      expect(byId['t']!.sourceId, 'tw');
    });

    test('跨栏目按日期倒序合并', () async {
      await MessageArchive.save('jwc', [
        _m('old', 'jwc', _d(yesterday)),
        _m('new', 'jwc', _d(today)),
      ]);
      await MessageArchive.save('xgc', [
        _m('mid', 'xgc', _d(twoDaysAgo)),
      ]);

      final page = await DailyDigestSource(subscribedIds: {'jwc', 'xgc'})
          .fetch(mode: FetchMode.cached);

      expect(page.items.map((m) => m.id), ['new', 'old', 'mid']);
    });

    test('空档案 → 空列表且没有 error（「没有新消息」不是「加载失败」）', () async {
      final page = await DailyDigestSource(subscribedIds: {'jwc'})
          .fetch(mode: FetchMode.cached);

      expect(page.items, isEmpty);
      expect(page.isFailure, isFalse);
    });

    test('搜索在本地过滤标题，不联网', () async {
      await MessageArchive.save('jwc', [
        _m('a', 'jwc', _d(today)).copyWith(title: '关于选课的通知'),
        _m('b', 'jwc', _d(today)).copyWith(title: '考试安排'),
      ]);

      final page = await DailyDigestSource(subscribedIds: {'jwc'})
          .fetch(mode: FetchMode.cached, q: '选课');

      expect(page.items.map((m) => m.id), ['a']);
      expect(page.total, 1);
    });

    test('纯本地源标记：刷新时必须排在所有联网源之后', () {
      expect(DailyDigestSource(subscribedIds: const {}).isLocalOnly, isTrue);
    });

    test('展示条数跟着「最多同步 N 条」的设置走', () async {
      await MessageArchive.save(
        'jwc',
        [for (var i = 0; i < 20; i++) _m('m$i', 'jwc', _d(today))],
      );

      final page = await DailyDigestSource(subscribedIds: {'jwc'})
          .fetch(mode: FetchMode.cached);

      // 默认设置是 60 条，20 条全在
      expect(page.items.length, 20);
      expect(page.total, 20);
    });
  });
}
