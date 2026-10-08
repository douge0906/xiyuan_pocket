import '../../models/message.dart';
import '../campus/campus_http_fetcher.dart';
import '../campus/campus_info_crawler.dart';
import '../campus/jwc_crawler.dart' show NoticeItem;
import '../message_detail_cache.dart';
import '../message_source.dart';
import 'cached_source.dart';

/// 校园资讯栏目源（校园要闻 / 校园快讯 / 学工处 / 团委）。
///
/// 与 [JwcSource] **完全同一套机制**（都继承 [CachedMessageSource]）——
/// 本类同样**只回答「怎么抓」**，不碰档案、不碰预算、不碰降级逻辑。
/// 此前它有一套自己的实现，「最多同步 N 条」这个设置对它完全无效。
class CampusSource extends CachedMessageSource {
  final String columnId;
  final String columnName;

  CampusSource({
    required this.columnId,
    required this.columnName,
  });

  @override
  MessageChannel get channel => MessageChannel(
        id: columnId,
        name: columnName,
        desc: '校园资讯中心 · $columnName',
        badge: columnName,
      );

  @override
  String get displayName => columnName;

  /// 增量：只抓最新 **1 页**（约 20 条）。
  ///
  /// 资讯中心是单页连续列表，「最新一小段」= 前 20 条 —— 与教务处抓 1 页等价。
  @override
  Future<List<Message>?> fetchIncremental() async {
    final items = await CampusInfoCrawler.fetchList(
      fetcher: CampusHttpFetcher.inject,
      columnId: columnId,
      targetItems: kMessageItemsPerPage,
    );
    return items.map(_toMessage).toList();
  }

  /// 冷启动 / 改了同步条数：**按目标条数抓**。
  ///
  /// 🔴 这里此前写死过 `limit > 20 ? limit : 60`，于是"设 1 页"照样拉 60 条
  /// —— 设置对它形同虚设。现在直接把目标条数交给抓取器。
  @override
  Future<List<Message>?> fetchFull(int target) async {
    final items = await CampusInfoCrawler.fetchList(
      fetcher: CampusHttpFetcher.inject,
      columnId: columnId,
      targetItems: target,
    );
    return items.map(_toMessage).toList();
  }

  @override
  Future<MessageDetail?> fetchDetail(Message message) async {
    final cached = await MessageDetailCache.load(sourceId, message.id);
    if (cached != null) return cached;

    if (message.url.isEmpty) return null;
    final d = await CampusInfoCrawler.fetchDetail(
      fetcher: CampusHttpFetcher.inject,
      detailUrl: message.url,
    );
    if (d == null) return null;

    final detail = MessageDetail(
      id: message.id,
      sourceId: columnId,
      title: d.title.isNotEmpty ? d.title : message.title,
      date: d.date.isNotEmpty ? d.date : message.date,
      author: d.author,
      url: message.url,
      content: d.content,
      attachments:
          d.attachments.map((e) => Map<String, dynamic>.from(e)).toList(),
    );
    await MessageDetailCache.save(detail);
    return detail;
  }

  Message _toMessage(NoticeItem it) => Message(
        id: it.id,
        sourceId: columnId,
        title: it.title,
        date: it.date,
        url: it.url,
        badge: columnName,
      );
}
