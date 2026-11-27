import '../../models/message.dart';
import '../message_archive.dart';
import '../message_channel_service.dart';
import '../message_source.dart';
import '../storage_service.dart';
import 'cached_source.dart';

/// 「每日消息」—— **不是抓取源，是汇总视图**。
///
/// 用户口径（2026-11-23 定为近 3 天，2026-11-27 改为近 2 天）：*「新增一个每日消息栏目，自动加载订阅栏目中近 2 天的
/// 消息，并且加一个来源小标识。」*
///
/// ## 它和别的源有什么不同
/// 别的源回答「怎么联网抓」，这个源**一个请求都不发**：它把其它栏目已经落在
/// 本机的档案读出来，按日期过滤、按时间倒序合并。所以它
/// ① 断网可用 ② 不占任何网络配额 ③ 永远和各个栏目本身看到的一致。
///
/// 这也是为什么它重写的是 [fetch] 而不是 [fetchIncremental]：
/// [CachedMessageSource.fetch] 那套「档案 / 增量 / 全量」的调度是为**联网省流量**
/// 设计的。这里没有网络成本，套上去反而会引入「档案里留着三天前的老消息」
/// 的问题（[MessageArchive.merge] 只去重、不按时间淘汰）。
///
/// ## 为什么消息的 `sourceId` 仍然是**原栏目**的
/// 🔴 这一条是有意的，不能改成 `daily`：
///   · `Message.key` = `<sourceId>:<id>`，是**已读状态**的键。保持原值 →
///     在「每日消息」里点开一条，回到教务处那栏它也是已读的。改成 `daily`
///     就变成两套已读状态，同一条公告能在两处同时是「未读」。
///   · 详情页靠 `_sources[message.sourceId]` 找加载器。保持原值 → 点进去走的是
///     原栏目那套抓取与缓存，不多写一行详情代码。
///
/// 「来源小标识」就落在 [Message.badge] 上 —— 那是列表项早就留好的位置
/// （`MessageCard.showBadge`），这里把它填成**原栏目的名字**。
class DailyDigestSource extends CachedMessageSource {
  DailyDigestSource({required this.subscribedIds});

  /// 用户当前订阅的栏目集合 —— 没订阅的栏目不该出现在汇总里。
  final Set<String> subscribedIds;

  /// 汇总最近两天（2026-11-27 用户改为「近两天」）= 今天 + 昨天。
  static const int days = 2;

  @override
  MessageChannel get channel => kDailyChannel;

  @override
  String get displayName => '每日消息';

  /// 纯本地源：批量更新时排在**最后**跑，这样它读到的档案已经是本轮刚刷新过的。
  @override
  bool get isLocalOnly => true;

  @override
  Future<MessagePage> fetch({required FetchMode mode, String q = ''}) async {
    // 🔴 不看 mode：没有网络，四挡结果完全一样。搜索也在本地做。
    final all = await _collect();
    final kw = q.trim().toLowerCase();
    final filtered = kw.isEmpty
        ? all
        : all.where((m) => m.title.toLowerCase().contains(kw)).toList();

    // 展示条数跟「最多同步 N 条」保持一致，否则用户把条数调小后这里还是几十条。
    final target = await StorageService.loadMessageSyncCount();
    final n = target <= 0
        ? filtered.length
        : (filtered.length > target ? target : filtered.length);
    return MessagePage(
      items: filtered.sublist(0, n),
      total: filtered.length,
      fromCache: true,
    );
  }

  @override
  Future<List<Message>?> fetchIncremental() => _collect();

  @override
  Future<List<Message>?> fetchFull(int target) => _collect();

  /// 详情：**永远不会被调用**（消息的 `sourceId` 是原栏目，仓库会把请求路由到
  /// 那个源）。保留实现只是为了满足接口，返回 `null` 而不是抛异常。
  @override
  Future<MessageDetail?> fetchDetail(Message message) async => null;

  /// 读各栏目档案 → 过滤近 2 天 → 打来源标识 → 按日期倒序。
  Future<List<Message>> _collect() async {
    final cutoff = _cutoffKey();
    final out = <Message>[];
    for (final ch in MessageChannelService.allChannels) {
      if (ch.id == kDailyChannelId) continue; // 不汇总自己
      if (!subscribedIds.contains(ch.id)) continue; // 没订阅就不该出现
      final archive = await MessageArchive.load(ch.id);
      for (final m in archive) {
        // 没日期的条目（极少数）没法判断新旧，宁可不要 —— 放进「每日」里
        // 会永久霸占顶部。
        if (m.date.isEmpty) continue;
        if (m.date.compareTo(cutoff) < 0) continue;
        out.add(m.copyWith(badge: ch.name));
      }
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  /// 近 N 天的下界，`YYYY-MM-DD`（与各源写进档案的日期格式一致，可直接字符串比）。
  static String _cutoffKey() {
    final now = DateTime.now();
    final from = now.subtract(const Duration(days: days - 1));
    final mm = from.month.toString().padLeft(2, '0');
    final dd = from.day.toString().padLeft(2, '0');
    return '${from.year}-$mm-$dd';
  }
}
