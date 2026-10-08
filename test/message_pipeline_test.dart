import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/message.dart';
import 'package:xiyuan_pocket/models/message_read_storage.dart';
import 'package:xiyuan_pocket/services/campus/campus_http_fetcher.dart';
import 'package:xiyuan_pocket/services/campus/campus_info_crawler.dart';
import 'package:xiyuan_pocket/services/campus/jwc_crawler.dart';
import 'package:xiyuan_pocket/services/message_archive.dart';
import 'package:xiyuan_pocket/services/message_repository.dart';
import 'package:xiyuan_pocket/services/message_source.dart';
import 'package:xiyuan_pocket/services/sources/cached_source.dart';
import 'package:xiyuan_pocket/services/storage_service.dart';

/// 假消息源：不联网，只记账。
///
/// 为什么必须有它：真源会去打校方公开站点 —— 单元测试既慢又不确定，
/// 而这里要验证的是**机制**（抓什么、抓多少、失败怎么办），不是抓取器本身。
class FakeSource extends CachedMessageSource {
  @override
  final MessageChannel channel;

  /// 返回 `null` = 失败（不抛异常的那种失败）。
  List<Message>? nextIncremental;
  List<Message>? nextFull;

  /// 抛异常 = 失败的另一种形态（抓取器实际就是这样报错的）。
  bool throwOnIncremental = false;
  bool throwOnFull = false;

  int incrementalCalls = 0;
  int fullCalls = 0;
  int lastFullTarget = -1;

  int archiveUpdatedCallbacks = 0;

  FakeSource(this.channel) {
    onArchiveUpdated = () => archiveUpdatedCallbacks++;
  }

  @override
  Future<List<Message>?> fetchIncremental() async {
    incrementalCalls++;
    if (throwOnIncremental) throw const CampusFetchException('fake://inc');
    return nextIncremental;
  }

  @override
  Future<List<Message>?> fetchFull(int target) async {
    fullCalls++;
    lastFullTarget = target;
    if (throwOnFull) throw const CampusFetchException('fake://full');
    return nextFull;
  }

  @override
  Future<MessageDetail?> fetchDetail(Message message) async => null;
}

Message msg(String sourceId, String id, String date) => Message(
      id: id,
      sourceId: sourceId,
      title: '标题$id',
      date: date,
      url: 'https://example.com/$id',
      badge: sourceId,
    );

/// 造 [from..to] 条，**id 越大日期越新**（与真实列表的排序一致）。
///
/// ⚠️ 日期必须单调递增：档案合并后按日期倒序重排，如果测试数据本身不是
/// 单调的，「内容没变就不回调」那条断言会因为**顺序变化**而假红。
List<Message> msgs(String sourceId, int from, int to) => [
      for (var i = from; i <= to; i++)
        msg(
          sourceId,
          '$i',
          '2026-${((i ~/ 28) + 1).toString().padLeft(2, '0')}'
              '-${((i % 28) + 1).toString().padLeft(2, '0')}',
        )
    ];

/// 轮询等待条件成立（比 `Future.delayed` 稳，不会因为机器快慢而假红）。
Future<void> waitUntil(bool Function() cond,
    {Duration timeout = const Duration(seconds: 2)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('「最多同步 N 条」的换算', () {
    test('条数 → 页数', () {
      expect(pagesForItemCount(20), 1);
      expect(pagesForItemCount(60), 3);
      expect(pagesForItemCount(120), 6);
      expect(pagesForItemCount(200), 10);
      expect(pagesForItemCount(400), 20);
      // 硬顶：防脏链接/错分页打爆上百个不存在的页。
      expect(pagesForItemCount(2000), kMaxFetchPages);
      expect(pagesForItemCount(999999), kMaxFetchPages);
      // 非法输入不崩，收敛到 1 页。
      expect(pagesForItemCount(0), 1);
      expect(pagesForItemCount(-5), 1);
    });

    test('设置值钳制，不是「非法回落默认」', () async {
      expect(await StorageService.loadMessageSyncCount(),
          StorageService.kMessageSyncCountDefault);

      await StorageService.saveMessageSyncCount(7);
      expect(await StorageService.loadMessageSyncCount(),
          StorageService.kMessageSyncCountMin,
          reason: '超下限应被钳到下限，而不是悄悄改回默认值');

      await StorageService.saveMessageSyncCount(99999);
      expect(await StorageService.loadMessageSyncCount(),
          StorageService.kMessageSyncCountMax);

      await StorageService.saveMessageSyncCount(400);
      expect(await StorageService.loadMessageSyncCount(), 400);
    });
  });

  group('抓取模式：三种语义必须各走各的路', () {
    late FakeSource src;
    const id = 'src';

    setUp(() {
      src = FakeSource(const MessageChannel(id: id, name: '测试源'));
    });

    test('冷启动（无档案）→ 走全量，目标 = 设置值', () async {
      src.nextFull = msgs(id, 1, 60);
      final page = await src.fetch(mode: FetchMode.full);

      expect(src.fullCalls, 1);
      expect(src.lastFullTarget, StorageService.kMessageSyncCountDefault);
      expect(page.error, isNull);
      expect(page.items.length, 60);
      expect((await MessageArchive.load(id)).length, 60,
          reason: '全量抓到的结果必须入档');
    });

    test('有档案 + incremental → 只抓增量，不碰全量', () async {
      await MessageArchive.save(id, msgs(id, 1, 60));
      src.nextIncremental = msgs(id, 61, 70);

      final page = await src.fetch(mode: FetchMode.incremental);

      expect(src.incrementalCalls, 1);
      expect(src.fullCalls, 0, reason: '强制增量绝不能退化成全量重爬');
      expect(page.error, isNull);
      expect((await MessageArchive.load(id)).length, 70);
    });

    test('🔴 有档案 + full → 必须真的全量重抓（调大档位要生效）', () async {
      await MessageArchive.save(id, msgs(id, 1, 60));
      await StorageService.saveMessageSyncCount(400);
      src.nextFull = msgs(id, 1, 400);

      final page = await src.fetch(mode: FetchMode.full);

      expect(src.fullCalls, 1,
          reason: '有档案时全量入口也必须可达 —— 否则改了设置拿不到更多');
      expect(src.lastFullTarget, 400, reason: '必须按新设置抓，不能用旧档位');
      expect(page.items.length, 400);
      expect((await MessageArchive.load(id)).length, 400);
    });

    test('archive 模式绝不联网', () async {
      await MessageArchive.save(id, msgs(id, 1, 30));
      final page = await src.fetch(mode: FetchMode.archive);

      expect(src.incrementalCalls, 0);
      expect(src.fullCalls, 0);
      expect(page.fromCache, isTrue);
      expect(page.items.length, 30);
    });

    test('cached 模式立刻给档案，增量丢后台', () async {
      await MessageArchive.save(id, msgs(id, 1, 30));
      src.nextIncremental = msgs(id, 31, 40);

      final page = await src.fetch(mode: FetchMode.cached);
      expect(page.items.length, 30, reason: '不该等网络，先给手上的档案');

      await waitUntil(() => src.incrementalCalls == 1);
      await waitUntil(() => src.archiveUpdatedCallbacks == 1);
      expect((await MessageArchive.load(id)).length, 40,
          reason: '后台增量要真的写进档案');
    });

    test('后台增量内容没变 → 不回调（避免每次进页面白重建列表）', () async {
      await MessageArchive.save(id, msgs(id, 1, 30));
      src.nextIncremental = msgs(id, 1, 30); // 与档案完全相同

      await src.fetch(mode: FetchMode.cached);
      await waitUntil(() => src.incrementalCalls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(src.archiveUpdatedCallbacks, 0);
    });
  });

  group('🔴 失败与空必须严格分开', () {
    late FakeSource src;
    const id = 'src';

    setUp(() {
      src = FakeSource(const MessageChannel(id: id, name: '测试源'));
      src.nextFull = msgs(id, 1, 60);
    });

    test('增量抛异常 → 降级显示旧档案 + 带 error，且档案不清空', () async {
      await src.fetch(mode: FetchMode.full);
      src.throwOnIncremental = true;

      final page = await src.fetch(mode: FetchMode.incremental);

      expect(page.error, isNotNull, reason: '失败必须带 error');
      expect(page.items.isNotEmpty, isTrue, reason: '失败时不能清空，要降级');
      expect((await MessageArchive.load(id)).length, 60);

      final st = ChannelState(items: page.items, error: page.error);
      expect(st.isEmpty, isFalse, reason: '有旧数据 + 失败 ≠ 空态');
    });

    test('增量返回 null（另一种失败形态）→ 同样降级', () async {
      await src.fetch(mode: FetchMode.full);
      src.nextIncremental = null;

      final page = await src.fetch(mode: FetchMode.incremental);
      expect(page.error, isNotNull);
      expect(page.items.length, 60);
    });

    test('增量返回空列表 = 确实没有新公告 → 不是失败', () async {
      await src.fetch(mode: FetchMode.full);
      src.nextIncremental = const [];

      final page = await src.fetch(mode: FetchMode.incremental);
      expect(page.error, isNull, reason: '空列表是成功，绝不能报错');
      expect(page.items.length, 60);
    });

    test('冷启动全量失败 → 空 + error（不是「暂无内容」）', () async {
      final fresh = FakeSource(const MessageChannel(id: 'cold', name: '冷启动源'));
      fresh.throwOnFull = true;

      final page = await fresh.fetch(mode: FetchMode.full);
      expect(page.items, isEmpty);
      expect(page.error, isNotNull);
      expect(page.isFailure, isTrue);
    });

    test('🔴 列表首页抓不到 → 抛异常，绝不是「返回空列表」', () async {
      // 这是「失败与空分开」的**最上游**一道闸：爬虫一旦返回空列表，
      // 下游无论怎么写都分不清"没内容"和"抓失败"。
      expect(
        () => JwcCrawler.fetchList(fetcher: (u, h) async => null),
        throwsA(isA<CampusFetchException>()),
      );
      expect(
        () => CampusInfoCrawler.fetchList(
          fetcher: (u, h) async => null,
          columnId: 'news',
        ),
        throwsA(isA<CampusFetchException>()),
      );
    });

    test('🔴 抓到页面却解析不出条目 → 也抛异常（站点改版/被拦截页顶替）', () async {
      expect(
        () => JwcCrawler.fetchList(fetcher: (u, h) async => '<html></html>'),
        throwsA(isA<CampusFetchException>()),
      );
    });

    test('未登记的栏目 id → 抛异常，不静默返回空', () async {
      expect(
        () => CampusInfoCrawler.fetchList(
          fetcher: (u, h) async => '<html></html>',
          columnId: '并不存在的栏目',
        ),
        throwsA(isA<CampusFetchException>()),
      );
    });
  });

  group('档案上限跟着设置走（用户拍板：不做兜底）', () {
    const id = 'src';

    test('设置 60 条 → 档案最多 60 条', () async {
      await StorageService.saveMessageSyncCount(60);
      final src = FakeSource(const MessageChannel(id: id, name: '测试源'));
      src.nextFull = msgs(id, 1, 200);

      final page = await src.fetch(mode: FetchMode.full);

      expect(page.items.length, 60);
      expect((await MessageArchive.load(id)).length, 60);
    });

    test('调小之后展示也跟着变小', () async {
      final src = FakeSource(const MessageChannel(id: id, name: '测试源'));
      await StorageService.saveMessageSyncCount(200);
      src.nextFull = msgs(id, 1, 200);
      await src.fetch(mode: FetchMode.full);
      expect((await src.fetch(mode: FetchMode.archive)).items.length, 200);

      await StorageService.saveMessageSyncCount(60);
      final page = await src.fetch(mode: FetchMode.incremental);
      expect(page.items.length, 60);
    });
  });

  group('搜索', () {
    const id = 'src';

    test('搜索只在本地档案过滤，绝不联网', () async {
      final src = FakeSource(const MessageChannel(id: id, name: '测试源'));
      src.nextFull = msgs(id, 1, 60);
      await src.fetch(mode: FetchMode.full);

      final page = await src.fetch(mode: FetchMode.archive, q: '标题12');
      expect(src.incrementalCalls, 0, reason: '搜索不该触发网络');
      expect(src.fullCalls, 1, reason: '只有前面那次冷启动全量');
      expect(page.items.length, 1);
      expect(page.items.first.title, '标题12');
    });

    test('搜索大小写不敏感', () async {
      final src = FakeSource(const MessageChannel(id: id, name: '测试源'));
      await MessageArchive.save(
          id,
          [
            Message(
                id: 'a',
                sourceId: id,
                title: 'CET-4 报名',
                date: '2026-01-01',
                url: 'u')
          ]);
      final page = await src.fetch(mode: FetchMode.archive, q: 'cet-4');
      expect(page.items.length, 1);
    });
  });

  group('档案合并', () {
    test('按 key 去重 + 新→旧排序', () {
      const id = 'src';
      final a = [msg(id, '1', '2026-01-01'), msg(id, '2', '2026-01-02')];
      final b = [
        msg(id, '2', '2026-01-02'), // 重复
        msg(id, '3', '2026-01-03'),
      ];
      final out = MessageArchive.merge(a, b);
      expect(out.length, 3);
      expect(out.first.id, '3', reason: '按日期倒序，新的在最前');
      expect(out.last.id, '1');
    });

    test('空列表一律不写档案', () async {
      await MessageArchive.save('src', const []);
      expect((await MessageArchive.load('src')).isEmpty, isTrue);
    });
  });

  group('已读键迁移', () {
    test('老键 → 新键，新键不动', () {
      expect(MessageReadStorage.migrateLegacyKey('school_123'), 'jwc:123');
      expect(MessageReadStorage.migrateLegacyKey('news_456'), 'news:456');
      expect(MessageReadStorage.migrateLegacyKey('tw_7'), 'tw:7');
      expect(MessageReadStorage.migrateLegacyKey('jwc:123'), isNull);
      expect(MessageReadStorage.migrateLegacyKey('无法识别的旧键'), isNull);
    });

    test('首次读取会补齐新键，且老键保留（两边都能用）', () async {
      SharedPreferences.setMockInitialValues({
        'message_read_ids': ['school_1', 'news_2', 'jwc:3'],
      });

      final set = await MessageReadStorage.loadReadIds();
      expect(set.contains('school_1'), isTrue, reason: '老键保留，旧路径不断');
      expect(set.contains('jwc:1'), isTrue, reason: '补出新键');
      expect(set.contains('news:2'), isTrue);
      expect(set.contains('jwc:3'), isTrue);

      // 只迁一次：再读时不应重复处理。
      final again = await MessageReadStorage.loadReadIds();
      expect(again.length, set.length);
    });
  });

  group('MessagePage 判别式', () {
    test('isFailure 只看 error，不看条数', () {
      expect(const MessagePage().isFailure, isFalse);
      expect(const MessagePage(items: []).isFailure, isFalse);
      expect(const MessagePage(error: 'x').isFailure, isTrue);
    });

    test('ChannelState.isEmpty 排除加载中与失败', () {
      expect(const ChannelState().isEmpty, isTrue);
      expect(const ChannelState(loading: true).isEmpty, isFalse);
      expect(const ChannelState(error: 'x').isEmpty, isFalse);
      expect(const ChannelState(items: []).isEmpty, isTrue);
    });
  });
}
