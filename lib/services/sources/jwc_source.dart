import '../../models/message.dart';
import '../campus/campus_http_fetcher.dart';
import '../campus/jwc_crawler.dart';
import '../message_detail_cache.dart';
import '../message_source.dart';
import 'cached_source.dart';

/// 教务处公告源 —— 默认订阅、排在第一位。
///
/// 本类**只回答「怎么抓」**（[fetchIncremental] / [fetchFull] / [fetchDetail]），
/// 加载、入档、预算、失败降级全在 [CachedMessageSource] 里 ——
/// 与其它源**同一套机制**。
///
/// ⚠️ 它**不是**特权源：用户可以在订阅页把它关掉（「所有消息列表都是
/// 可选项」）。它之所以一打开就在台面上，只是因为 [MessageChannel.defaultSubscribed]。
class JwcSource extends CachedMessageSource {
  JwcSource();

  @override
  MessageChannel get channel => const MessageChannel(
        id: kJwcChannelId,
        name: '教务处',
        desc: '教务处通知公告',
        defaultSubscribed: true,
        badge: '教务处',
        // 教务处保留「发布日期 ≥ 基准线才算新公告」的未读语义：
        // 早于用户首次打开公告页那天的旧公告，不该永远挂着红点。
        usesUnreadBaseline: true,
      );

  @override
  String get displayName => '教务处';

  /// 增量：**只抓最新 1 页**。
  ///
  /// 教务处通知公告是「页码越大越新」，所以第 1 页就是最新的 —— 一页足够。
  ///
  /// 🔴 抓取失败时**抛异常**（由基类接住并转成 `null`），**不得压成空列表**
  /// —— 空列表会被上层当成「确实没有新公告」，于是断网时用户看到「刷新成功」。
  @override
  Future<List<Message>?> fetchIncremental() async {
    final items = await JwcCrawler.fetchList(
      fetcher: CampusHttpFetcher.inject,
      maxPages: 1,
    );
    return items.map(_toMessage).toList();
  }

  /// 冷启动 / 改了同步条数：按目标条数换算成页数全量抓。
  @override
  Future<List<Message>?> fetchFull(int target) async {
    final items = await JwcCrawler.fetchList(
      fetcher: CampusHttpFetcher.inject,
      maxPages: pagesForItemCount(target),
    );
    return items.map(_toMessage).toList();
  }

  /// 详情：**用列表项自带的 URL 直接抓**。
  ///
  /// 🔴 这里不查任何"按 id 反查 URL"的旁路 —— [Message] 随身带着 `url`。
  /// 此前那套反查走的是另一个缓存键，键一迁移就断，症状是
  /// 「列表正常、点进去白屏」这种最难自查的形态。
  @override
  Future<MessageDetail?> fetchDetail(Message message) async {
    // 缓存优先（有缓存秒开）。
    final cached = await MessageDetailCache.load(sourceId, message.id);
    if (cached != null) return cached;

    if (message.url.isEmpty) return null;
    final d = await JwcCrawler.fetchDetail(
      fetcher: CampusHttpFetcher.inject,
      detailUrl: message.url,
    );
    if (d == null) return null;

    final detail = MessageDetail(
      id: message.id,
      sourceId: sourceId,
      title: d.title.isNotEmpty ? d.title : message.title,
      date: d.date.isNotEmpty ? d.date : message.date,
      author: d.author,
      url: message.url,
      content: d.content,
      attachments: d.attachments
          .map((e) => Map<String, dynamic>.from(e))
          .toList(),
    );
    await MessageDetailCache.save(detail);
    return detail;
  }

  Message _toMessage(NoticeItem n) => Message(
        id: n.id,
        sourceId: kJwcChannelId,
        title: n.title,
        date: n.date,
        url: n.url,
        badge: '教务处',
      );
}
