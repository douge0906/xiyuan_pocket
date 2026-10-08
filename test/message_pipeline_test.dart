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

  /// 让 [fetch] 本身抛异常 —— 即「源内部兜底也失效了」的那种意外失败，
  /// 用来测仓库里那道最后防线。**注意 `throwOnFull` 走不到那里**：
  /// 抓取失败的异常会被 [CachedMessageSource] 内部吞掉并降级成带 error 的
  /// MessagePage，所以那条路是「成功返回」而不是「抛上去」。
  bool throwOnFetch = false;

  int incrementalCalls = 0;
  int fullCalls = 0;
  int lastFullTarget = -1;

  int archiveUpdatedCallbacks = 0;

  /// 抓增量**之前**先跑一下（测试用来"取现场"）。
  ///
  /// 用途：验证「铺档案」那一趟真的跑在联网那趟**之前** ——
  /// 在 `fetchIncremental` 里读 `repo.stateOf(id).items.length`，
  /// 铺过就是档案条数，没铺就是 0。
  void Function()? beforeIncremental;

  /// 让增量"慢慢来"，用来测计时与更新条会不会在等待期间一直亮着。
  Duration incrementalDelay = Duration.zero;

  FakeSource(this.channel) {
    onArchiveUpdated = () => archiveUpdatedCallbacks++;
  }

  @override
  Future<MessagePage> fetch({required FetchMode mode, String q = ''}) async {
    if (throwOnFetch) throw const CampusFetchException('fake://fetch');
    return super.fetch(mode: mode, q: q);
  }

  @override
  Future<List<Message>?> fetchIncremental() async {
    beforeIncremental?.call();
    incrementalCalls++;
    if (incrementalDelay > Duration.zero) {
      await Future<void>.delayed(incrementalDelay);
    }
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
    test('条数 → 页数（每页按 8 条保守估算）', () {
      // 8 = 实测各源每页的**最小值**（学工处 8 / 校园要闻 10 / 教务处 12 / 团委 16）。
      expect(kMessageItemsPerPage, 8);
      expect(pagesForItemCount(8), 1);
      expect(pagesForItemCount(20), 3);
      expect(pagesForItemCount(40), 5);
      expect(pagesForItemCount(60), 8);
      expect(pagesForItemCount(120), 15);
      expect(pagesForItemCount(200), 25);
      expect(pagesForItemCount(400), 50);
      // 硬顶：防脏链接/错分页打爆上百个不存在的页。
      // 150 就是教务处全站的页数（实测 1793 条 / 每页 12 条）。
      expect(kMaxFetchPages, 150);
      expect(pagesForItemCount(1200), kMaxFetchPages);
      expect(pagesForItemCount(2000), kMaxFetchPages);
      expect(pagesForItemCount(999999), kMaxFetchPages);
      // 非法输入不崩，收敛到 1 页。
      expect(pagesForItemCount(0), 1);
      expect(pagesForItemCount(-5), 1);
    });

    test('🔴 页码预算只能算多、不能算少', () {
      // 翻页循环会在**凑够目标条数时立刻停下**，所以页数算多了不花任何代价，
      // 算少了才会真的抓不够。这里把「保守方向」钉死成断言 ——
      // 旧值 20（每页）正是算少了：40 条只给 2 页，而教务处一页 12 条 → 实际只够 24 条。
      for (final n in [20, 40, 60, 120, 200, 400]) {
        expect(pagesForItemCount(n) * kMessageItemsPerPage, greaterThanOrEqualTo(n),
            reason: '$n 条的页码预算在最坏情况下也要够 $n 条');
      }
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

    test('默认 40 条，且它本身就是第一个档位', () {
      // 默认值从 200 改到 40 是**实测后的修正**：教务处一页 12 条、全站 150 页，
      // 200 条 = 至少 17 次网络请求，首次进消息页根本等不起。
      expect(StorageService.kMessageSyncCountDefault, 40);
      expect(StorageService.kMessageSyncCountPresets.first,
          StorageService.kMessageSyncCountDefault,
          reason: '默认档必须能在设置页一眼选中，否则用户不知道自己在哪一档');
      expect(StorageService.kMessageSyncCountPresets,
          containsAllInOrder([40, 60, 120, 200, 400]));
      expect(StorageService.kMessageSyncCountMin,
          lessThanOrEqualTo(StorageService.kMessageSyncCountDefault));
    });

    test('「每次进入自动更新」默认开，且能存能读', () async {
      expect(await StorageService.loadMessageAutoRefresh(), isTrue,
          reason: '默认应当是「自动更新」——否则新用户看不到任何新内容');

      await StorageService.saveMessageAutoRefresh(false);
      expect(await StorageService.loadMessageAutoRefresh(), isFalse);

      await StorageService.saveMessageAutoRefresh(true);
      expect(await StorageService.loadMessageAutoRefresh(), isTrue);
    });
  });

  group('抓取模式：三种语义必须各走各的路', () {
    late FakeSource src;
    const id = 'src';

    /// 本组统一把目标条数显式写成 60。
    ///
    /// 🔴 **不要依赖默认值**：默认值改过一次（200 → 40），凡是硬编码了
    /// 「档案应该有 60 条」的断言都会跟着假红 —— 而红的其实是断言写法，
    /// 不是代码。显式写死目标，测试才只对**被测逻辑**敏感。
    Future<void> target60() => StorageService.saveMessageSyncCount(60);

    setUp(() async {
      await target60();
      src = FakeSource(const MessageChannel(id: id, name: '测试源'));
    });

    test('冷启动（无档案）→ 走全量，目标 = 设置值', () async {
      src.nextFull = msgs(id, 1, 60);
      final page = await src.fetch(mode: FetchMode.full);

      expect(src.fullCalls, 1);
      expect(src.lastFullTarget, 60, reason: '全量必须按用户设置的条数抓');
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
      expect((await MessageArchive.load(id)).length, 60,
          reason: '合并后 70 条，档案上限仍是设置值 60');
      expect(page.total, 60);
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

    test('cached 模式立刻给档案，联网丢后台', () async {
      // 档案 60 条 = 目标，**不需要补齐** → 后台只问一句「有没有新的」。
      await MessageArchive.save(id, msgs(id, 1, 60));
      src.nextIncremental = msgs(id, 61, 70);

      final page = await src.fetch(mode: FetchMode.cached);
      expect(page.items.length, 60, reason: '不该等网络，先给手上的档案');
      expect(src.incrementalCalls + src.fullCalls, 0,
          reason: '联网必须是后台的，调用当场就得返回');

      await waitUntil(() => src.incrementalCalls == 1);
      expect(src.fullCalls, 0, reason: '档案已经够了，不该再全量重爬');
      await waitUntil(() => src.archiveUpdatedCallbacks == 1);
      expect((await MessageArchive.load(id)).length, 60,
          reason: '后台增量要真的写进档案');
    });

    test('后台增量内容没变 → 不回调（避免每次进页面白重建列表）', () async {
      await MessageArchive.save(id, msgs(id, 1, 60));
      src.nextIncremental = msgs(id, 1, 60); // 与档案完全相同

      await src.fetch(mode: FetchMode.cached);
      await waitUntil(() => src.incrementalCalls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(src.archiveUpdatedCallbacks, 0);
    });
  });

  group('🔴 档案不足目标就必须真的去抓（「只加载几十条」的回归）', () {
    late FakeSource src;
    const id = 'src';

    setUp(() {
      src = FakeSource(const MessageChannel(id: id, name: '测试源'));
    });

    test('档案 20 条 + 目标 40 → incremental 真的补齐到 40', () async {
      await StorageService.saveMessageSyncCount(40);
      await MessageArchive.save(id, msgs(id, 1, 20)); // 内置快照大概就这么多
      src.nextFull = msgs(id, 1, 40);

      final page = await src.fetch(mode: FetchMode.incremental);

      expect(src.fullCalls, 1, reason: '档案不够就必须去抓，不能只做一页增量');
      expect(src.incrementalCalls, 0, reason: '补齐走全量，不是增量');
      expect(src.lastFullTarget, 40);
      expect(page.items.length, 40);
      expect((await MessageArchive.load(id)).length, 40);
    });

    test('进页面（cached）也会在后台补齐，不必等用户下拉', () async {
      await StorageService.saveMessageSyncCount(40);
      await MessageArchive.save(id, msgs(id, 1, 20));
      src.nextFull = msgs(id, 1, 40);

      final page = await src.fetch(mode: FetchMode.cached);
      expect(page.items.length, 20, reason: '仍然先给手上的档案，不阻塞首屏');

      await waitUntil(() => src.fullCalls == 1);
      await waitUntil(() => src.archiveUpdatedCallbacks == 1);
      expect((await MessageArchive.load(id)).length, 40,
          reason: '补齐要落到档案上，否则下次进来还是 20 条');
    });

    test('补齐只做一次：档案仍不足也不再重抓（站点本来就没那么多）', () async {
      await StorageService.saveMessageSyncCount(400);
      await MessageArchive.save(id, msgs(id, 1, 20));
      src.nextFull = msgs(id, 1, 30); // 这个源全站只有 30 条，凑不到 400

      await src.fetch(mode: FetchMode.incremental);
      expect(src.fullCalls, 1);

      src.nextIncremental = msgs(id, 31, 31);
      await src.fetch(mode: FetchMode.incremental);

      expect(src.fullCalls, 1, reason: '不能因为「还是不够」就每次进页面都全量重抓');
      expect(src.incrementalCalls, 1);
    });

    test('补齐失败 → 不置「已补齐」标记，下次还会再试', () async {
      await StorageService.saveMessageSyncCount(40);
      await MessageArchive.save(id, msgs(id, 1, 20));
      src.throwOnFull = true;

      final failed = await src.fetch(mode: FetchMode.incremental);
      expect(failed.error, isNotNull, reason: '补不齐必须报失败，不能谎报成功');
      expect(failed.items.length, 20, reason: '失败也不能清空旧档案');

      src.throwOnFull = false;
      src.nextFull = msgs(id, 1, 40);
      final ok = await src.fetch(mode: FetchMode.incremental);

      expect(src.fullCalls, 2, reason: '上次失败没置标记，所以这次必须重试');
      expect(ok.error, isNull);
      expect(ok.items.length, 40);
    });

    test('档案够了就不补齐：只抓一页增量', () async {
      await StorageService.saveMessageSyncCount(40);
      await MessageArchive.save(id, msgs(id, 1, 40));
      src.nextIncremental = msgs(id, 41, 45);

      final page = await src.fetch(mode: FetchMode.incremental);

      expect(src.fullCalls, 0, reason: '档案已经够目标，不该再全量重爬');
      expect(src.incrementalCalls, 1);
      expect(page.items.length, 40, reason: '新增之后仍然按设置截到 40 条');
    });
  });

  group('🔴 失败与空必须严格分开', () {
    late FakeSource src;
    const id = 'src';

    setUp(() async {
      // 显式定目标，理由同上一组：不依赖默认值。
      await StorageService.saveMessageSyncCount(60);
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
      // ⚠️ 目标必须 ≥ 快照条数：档案只保留**最新** N 条，若目标是默认的 40，
      // 60 条快照会被截成 41~60，`标题12` 根本不在档案里 —— 断言会假红。
      await StorageService.saveMessageSyncCount(60);
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

  group('设置页「每次进入自动更新」', () {
    Future<MessageRepository> repoWith(FakeSource src) async {
      final repo = MessageRepository();
      repo.debugRegisterSource(src);
      return repo;
    }

    test('开着（默认）→ 进页面会在后台查新', () async {
      final a = FakeSource(const MessageChannel(id: 'a', name: '源A'));
      a.nextFull = msgs('a', 1, 20);
      final repo = await repoWith(a);
      expect(repo.autoRefresh, isTrue, reason: '默认必须是自动更新');

      repo.setActive('a');
      await waitUntil(() => a.fullCalls == 1,
          timeout: const Duration(seconds: 3));

      repo.dispose();
    });

    test('🔴 关掉 → 进页面只读档案，一个请求都不发', () async {
      final a = FakeSource(const MessageChannel(id: 'a', name: '源A'));
      await MessageArchive.save('a', msgs('a', 1, 20));
      final repo = await repoWith(a);
      await repo.setAutoRefresh(false);

      repo.setActive('a');
      // 再显式走一次只读加载：它内部会等前面那个 fire-and-forget 跑完。
      await repo.load('a', mode: FetchMode.archive);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(a.fullCalls, 0, reason: '关了自动更新就不该联网');
      expect(a.incrementalCalls, 0, reason: '关了自动更新就不该联网');
      expect(repo.stateOf('a').items.length, 20, reason: '手上有的照常显示');
      expect(repo.stateOf('a').fromCache, isTrue);

      repo.dispose();
    });

    test('关掉 + 档案为空 → 仍然兜底抓一次（否则空页面无从下手）', () async {
      final a = FakeSource(const MessageChannel(id: 'a', name: '源A'));
      a.nextFull = msgs('a', 1, 20);
      final repo = await repoWith(a);
      await repo.setAutoRefresh(false);

      repo.setActive('a');
      await waitUntil(() => a.fullCalls == 1,
          timeout: const Duration(seconds: 3));

      repo.dispose();
    });

    test('开关落盘，下一个会话读得回来', () async {
      final a = FakeSource(const MessageChannel(id: 'a', name: '源A'));
      final repo = await repoWith(a);
      await repo.setAutoRefresh(false);
      expect(await StorageService.loadMessageAutoRefresh(), isFalse);
      repo.dispose();

      final fresh = MessageRepository();
      await fresh.initSettings();
      expect(fresh.autoRefresh, isFalse, reason: '不读回来就等于开关没存');
      fresh.dispose();
    });
  });

  group('加载进度与「加载完成」序号', () {
    test('loadSeq：每次加载结束 +1；静默加载不推进', () async {
      final a = FakeSource(const MessageChannel(id: 'a', name: '源A'));
      await MessageArchive.save('a', msgs('a', 1, 20));
      final repo = MessageRepository();
      repo.debugRegisterSource(a);
      expect(repo.loadSeq, 0);

      await repo.load('a', mode: FetchMode.archive);
      expect(repo.loadSeq, 1);

      // 静默加载 = 后台写档后的重读。它若也推进序号，界面会在用户
      // 什么都没点的时候莫名弹一次「累计条数」提示。
      await repo.load('a', mode: FetchMode.archive, silent: true);
      expect(repo.loadSeq, 1, reason: '静默加载不该推进序号');

      // 静默**失败**同样不该推进 —— 分支不同，漏一个就够界面抖一下。
      a.throwOnFull = true;
      await repo.load('a', mode: FetchMode.full, silent: true);
      expect(repo.loadSeq, 1, reason: '静默失败也不该推进序号');

      // 走到仓库里的最后一道防线（源自己抛上来的意外异常）。
      a.throwOnFetch = true;
      await repo.load('a', mode: FetchMode.full, silent: true);
      expect(repo.loadSeq, 1, reason: '静默 + 抛异常也不该推进序号');

      await repo.load('a', mode: FetchMode.full);
      expect(repo.loadSeq, 2, reason: '非静默的意外失败同样算「加载结束」');

      repo.dispose();
    });

    test('失败也算「加载结束」，序号一样推进', () async {
      final a = FakeSource(const MessageChannel(id: 'a', name: '源A'));
      a.throwOnFull = true;
      final repo = MessageRepository();
      repo.debugRegisterSource(a);

      await repo.load('a', mode: FetchMode.full);
      expect(repo.loadSeq, 1, reason: '失败也要收尾，否则进度条/提示卡住');
      expect(repo.stateOf('a').error, isNotNull);

      repo.dispose();
    });

    test('🔴 源直接抛异常（兜底也失效）→ 保留旧内容 + 报错，绝不清空', () async {
      final a = FakeSource(const MessageChannel(id: 'a', name: '源A'));
      await MessageArchive.save('a', msgs('a', 1, 20));
      final repo = MessageRepository();
      repo.debugRegisterSource(a);

      await repo.load('a', mode: FetchMode.archive);
      expect(repo.stateOf('a').items.length, 20);

      a.throwOnFetch = true;
      await repo.load('a', mode: FetchMode.full);

      final st = repo.stateOf('a');
      expect(st.error, isNotNull, reason: '失败必须报出来');
      expect(st.items.length, 20, reason: '失败绝不清空已有内容');
      expect(st.isEmpty, isFalse, reason: '有旧数据 + 失败 ≠ 空态');
      expect(st.loading, isFalse, reason: '失败也必须把 loading 收掉，否则转圈不停');

      repo.dispose();
    });

    test('🔴 强刷全部源：进度先亮后清，绝不永久停在 3/5', () async {
      final a = FakeSource(const MessageChannel(id: 'a', name: '源A'));
      final b = FakeSource(const MessageChannel(id: 'b', name: '源B'));
      a.nextFull = msgs('a', 1, 20);
      b.nextFull = msgs('b', 1, 20);
      final repo = MessageRepository();
      repo.debugRegisterSource(a);
      repo.debugRegisterSource(b);

      final seen = <({int done, int total})>[];
      repo.addListener(() {
        final p = repo.refreshProgress;
        if (p != null) seen.add(p);
      });

      await repo.refreshAll(mode: FetchMode.full);

      expect(seen.first, (done: 0, total: 2), reason: '一开始就得亮出来');
      expect(seen.contains((done: 1, total: 2)), isTrue);
      expect(seen.contains((done: 2, total: 2)), isTrue);
      expect(repo.refreshProgress, isNull,
          reason: '结束必须清空，否则进度条永远停在最后一格');

      // 第二轮必须从 0 重新开始，而不是接着上一轮的 2/2。
      seen.clear();
      await repo.refreshAll(mode: FetchMode.full);
      expect(seen.first, (done: 0, total: 2));

      repo.dispose();
    });

    test('累计条数只统计**已加载**的，与列表口径一致', () async {
      final a = FakeSource(const MessageChannel(id: 'a', name: '源A'));
      final b = FakeSource(const MessageChannel(id: 'b', name: '源B'));
      await StorageService.saveMessageSyncCount(20);
      await MessageArchive.save('a', msgs('a', 1, 20));
      await MessageArchive.save('b', msgs('b', 1, 50));
      final repo = MessageRepository();
      repo.debugRegisterSource(a);
      repo.debugRegisterSource(b);
      expect(repo.loadedTotal, 0, reason: '还没加载过 → 0');

      await repo.load('a', mode: FetchMode.archive);
      await repo.load('b', mode: FetchMode.archive);

      expect(repo.loadedCounts.map((e) => e.name).toList(), ['源A', '源B']);
      expect(repo.loadedTotal, 40, reason: '每源各 20 条（b 的 50 条被设置截到 20）');

      repo.dispose();
    });
  });

  group('【总的更新】一次性更新全部源', () {
    const aId = 'a';
    const bId = 'b';
    late FakeSource a;
    late FakeSource b;
    late MessageRepository repo;

    setUp(() async {
      await StorageService.saveMessageSyncCount(20);
      a = FakeSource(const MessageChannel(id: aId, name: '源A'));
      b = FakeSource(const MessageChannel(id: bId, name: '源B'));
      repo = MessageRepository();
      repo.debugRegisterSource(a);
      repo.debugRegisterSource(b);
    });

    tearDown(() => repo.dispose());

    test('🔴 联网更新之前，**所有**页签的内容都已经铺好了', () async {
      // 需求原文：「不要点一个更新一个」。用户切到第 2 个页签时必须
      // 立刻有内容，而不是现等一次网络。
      await MessageArchive.save(aId, msgs(aId, 1, 20));
      await MessageArchive.save(bId, msgs(bId, 1, 20));

      final seen = <String, int>{};
      a.beforeIncremental = () => seen[aId] = repo.stateOf(aId).items.length;
      b.beforeIncremental = () => seen[bId] = repo.stateOf(bId).items.length;

      await repo.syncAll();

      expect(seen[aId], 20, reason: '联网之前第 1 个页签就该有内容');
      expect(seen[bId], 20,
          reason: '🔴 第 2 个页签也要铺好 —— 不能等轮到它才加载');
      expect(a.fullCalls + b.fullCalls, 0, reason: '档案够用，不该全量重爬');
      expect(a.incrementalCalls, 1);
      expect(b.incrementalCalls, 1);
    });

    test('铺档案那趟**不联网**（各源只发一次请求）', () async {
      await MessageArchive.save(aId, msgs(aId, 1, 20));
      await MessageArchive.save(bId, msgs(bId, 1, 20));

      await repo.syncAll();

      // 只做了「一眼看有没有新的」那一次；若铺档案顺手也去抓，
      // 这里会是 2（每源多一次），对校方站点就是白打一倍请求。
      expect(a.incrementalCalls, 1);
      expect(b.incrementalCalls, 1);
      expect(a.fullCalls, 0);
      expect(b.fullCalls, 0);
    });

    test('空档案不铺，留给联网那趟去抓（且只抓一次）', () async {
      await MessageArchive.save(aId, msgs(aId, 1, 20));
      b.nextFull = msgs(bId, 1, 20); // b 是全新安装：档案为空

      await repo.syncAll();

      expect(a.fullCalls, 0, reason: 'a 有档案，走增量');
      expect(a.incrementalCalls, 1);
      expect(b.fullCalls, 1, reason: 'b 档案为空 → 兜底全量抓一次');
      expect(b.incrementalCalls, 0,
          reason: '🔴 不能在「铺档案」那趟先白抓一次，再由联网那趟抓一次');
      expect(repo.stateOf(bId).items.length, 20);
    });

    test('两个页签的加载完成提示只弹一次（不是每源弹一次）', () async {
      await MessageArchive.save(aId, msgs(aId, 1, 20));
      await MessageArchive.save(bId, msgs(bId, 1, 20));

      await repo.syncAll();

      // loadSeq 是「非静默加载完成」的次数；界面靠它弹提示。
      // 铺档案是 silent 的，所以这里应当是 2（两个源各一次联网更新），
      // 而不是 4（每源两次）—— 否则提示会连着闪两轮。
      expect(repo.loadSeq, 2);
      expect(repo.loadedCounts.map((e) => e.name).toList(), ['源A', '源B']);
      expect(repo.loadedTotal, 40);
    });

    test('没有任何源 → 直接收工，不亮更新条（不能闪一下 0/0）', () async {
      final empty = MessageRepository();

      final done = await empty.refreshAll(mode: FetchMode.full);
      expect(done, 0);
      expect(empty.refreshProgress, isNull);
      expect(empty.isBusy, isFalse);

      empty.dispose();
    });
  });

  group('更新条与计时', () {
    setUp(() async {
      // 目标 = 档案条数 ⇒ `_needsFill` 为假 ⇒ 走**增量**那条路。
      // 不显式设的话默认 40 > 档案 20，会变成「补齐」，链路就不是这里要测的了。
      await StorageService.saveMessageSyncCount(20);
    });

    test('更新条在整批期间一直亮着，跑完立刻灭', () async {
      final a = FakeSource(const MessageChannel(id: 'a', name: '源A'));
      await MessageArchive.save('a', msgs('a', 1, 20));
      a.incrementalDelay = const Duration(milliseconds: 800);
      final repo = MessageRepository();
      repo.debugRegisterSource(a);

      final f = repo.refreshAll(mode: FetchMode.incremental);

      // ⚠️ 这里**不能**断言「第一个源还没进入 loading 就已经为忙」——
      // `refreshAll` 是 async，"记进度" 到 "第一个源置 loading" 之间没有任何
      // await，中间那一刻界面渲染不出来。写那种断言是自我安慰，变异测试
      // 一下就会露（实测：把 isBusy 改成只看 isLoading，那条断言照样过）。
      expect(repo.isBusy, isTrue);
      expect(repo.refreshProgress, (done: 0, total: 1));

      await waitUntil(() => repo.busyElapsed.inMilliseconds >= 500,
          timeout: const Duration(seconds: 3));
      expect(repo.isBusy, isTrue, reason: '整批期间更新条必须一直亮着');

      await f;
      expect(repo.isBusy, isFalse, reason: '跑完必须立刻灭');
      expect(repo.refreshProgress, isNull, reason: '进度也要清掉');

      repo.dispose();
    });

    test('单源加载也走同一条更新条（不是只有批量才亮）', () async {
      final a = FakeSource(const MessageChannel(id: 'a', name: '源A'));
      await MessageArchive.save('a', msgs('a', 1, 20));
      a.incrementalDelay = const Duration(milliseconds: 500);
      final repo = MessageRepository();
      repo.debugRegisterSource(a);

      final f = repo.load('a', mode: FetchMode.incremental);
      // 没有批量进度 —— 界面会画成不确定进度（来回扫），但计时照走。
      expect(repo.isBusy, isTrue);
      expect(repo.refreshProgress, isNull, reason: '单源加载没有 done/total');

      await waitUntil(() => repo.busyElapsed.inMilliseconds >= 300,
          timeout: const Duration(seconds: 3));
      await f;
      expect(repo.isBusy, isFalse);

      repo.dispose();
    });

    test('🔴 计时要真的在走：请求挂住 1.2 秒，秒表就得走到 1 秒以上', () async {
      final a = FakeSource(const MessageChannel(id: 'a', name: '源A'));
      await MessageArchive.save('a', msgs('a', 1, 20));
      a.incrementalDelay = const Duration(milliseconds: 1200);
      final repo = MessageRepository();
      repo.debugRegisterSource(a);

      final f = repo.load('a', mode: FetchMode.incremental);
      await waitUntil(() => repo.busyElapsed.inMilliseconds >= 1000,
          timeout: const Duration(seconds: 3));

      expect(repo.busyElapsed.inMilliseconds, greaterThanOrEqualTo(1000),
          reason: '秒表要在等待期间一直往前跑');
      expect(repo.isBusy, isTrue, reason: '这段时间更新条应当还亮着');

      await f;
      repo.dispose();
    });

    test('忙完自动归零（不用谁去手动停表）', () async {
      final a = FakeSource(const MessageChannel(id: 'a', name: '源A'));
      await MessageArchive.save('a', msgs('a', 1, 20));
      final repo = MessageRepository();
      repo.debugRegisterSource(a);

      await repo.load('a', mode: FetchMode.archive);
      expect(repo.busyElapsed, greaterThan(Duration.zero),
          reason: '刚忙过，秒表上应当有数');
      expect(repo.isBusy, isFalse);

      // 收工是靠秒表自己每秒看一眼判定的，所以最多等一拍。
      await waitUntil(() => repo.busyElapsed == Duration.zero,
          timeout: const Duration(seconds: 3));

      repo.dispose();
    });

    test('一串串行的源属于**同一次**更新，计时不重开', () async {
      final a = FakeSource(const MessageChannel(id: 'a', name: '源A'));
      final b = FakeSource(const MessageChannel(id: 'b', name: '源B'));
      await MessageArchive.save('a', msgs('a', 1, 20));
      await MessageArchive.save('b', msgs('b', 1, 20));
      a.incrementalDelay = const Duration(milliseconds: 700);
      b.incrementalDelay = const Duration(milliseconds: 700);
      final repo = MessageRepository();
      repo.debugRegisterSource(a);
      repo.debugRegisterSource(b);

      final f = repo.refreshAll(mode: FetchMode.incremental);
      await waitUntil(() => a.incrementalCalls == 1);
      final afterFirst = repo.busyElapsed;
      await waitUntil(() => b.incrementalCalls == 1);
      await waitUntil(() => repo.busyElapsed > afterFirst,
          timeout: const Duration(seconds: 3));
      await f;

      // 两个源各 700ms ⇒ 合计 ≥1.4s。若每个源都把秒表重开，
      // 秒数就会永远停在 0~1 秒 —— 用户看到的「计时」就是假的。
      expect(repo.busyElapsed.inMilliseconds, greaterThanOrEqualTo(1300),
          reason: '计时必须连着算，不能每换一个源就跳回 0');

      repo.dispose();
    });
  });
}
