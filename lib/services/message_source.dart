import '../models/message.dart';

/// 消息列表的抓取方式 —— **取代原来的 `force: bool`**。
///
/// 【为什么不是一个布尔】重构前用 `force` 同时表达两件毫不相干的事：
/// ①「下拉刷新，看看有没有新的」②「我改了同步条数，要更多」。
/// 两者对抓取量的要求完全不同（1 页 vs 按新预算全量），却被压进同一个
/// 字段，于是出现「把 3 页改成 20 页，回来一看还是 80 条」——
/// 因为 `force` 走的是增量路径，永远只抓最新一页。
///
/// 一个字段背两种语义，就一定会有一方被牺牲。拆开成三种（外加只读档案）：
enum FetchMode {
  /// **只读本地档案，绝不联网。** 用于展示、搜索、以及后台增量写档后的
  /// 界面刷新 —— 这些场景网络请求已经在前一步发生过了。
  archive,

  /// **秒开**：有档案就立刻返回，同时把增量丢到后台静默跑。
  /// 用于进入消息页。这是"先给结果再更新"的那条路。
  cached,

  /// **强制增量**：只抓最新一页合并进档案。用于下拉刷新。
  ///
  /// 这是「强制刷新 ≠ 全量重爬」的落点：档案已经有一万条时，下拉刷新
  /// 也只该问一句「有没有新的」，而不是重爬一遍。
  incremental,

  /// **按新的同步条数全量抓。** 用于「用户改了同步数量」与「首次安装」。
  ///
  /// 🔴 这条路是**必须可再次到达**的。重构前的全量入口只在「档案为空」
  /// 时可达，所以一旦有档案，全量永远够不着 —— 这是「调大档位不生效」
  /// 的根因。
  full,
}

/// 消息渠道描述符 —— 统一表达「教务处公告」与「校园资讯栏目」。
///
/// 【所有源一律平等】这是 2026-10-08 用户的明确口径：**每个消息列表都是
/// 可选项**，包括教务处 —— 只不过教务处**默认订阅**，所以它一打开就在
/// 台面上。因此这里用 [defaultSubscribed] 表达"初始值"，而**不是**用
/// `isBuiltIn` 表达"特权"。特权标记会让「取消订阅教务处」这件事在类型上
/// 就做不到，与"一律平等"自相矛盾。
class MessageChannel {
  final String id;
  final String name;

  /// 一句话说明，用于订阅页的副标题。
  final String desc;

  /// **默认是否订阅**（只在首次运行 / 老版本升级上来时用一次；
  /// 之后一律以用户存的订阅集合为准，用户关掉就是关掉）。
  final bool defaultSubscribed;

  /// 列表条目左上角的来源标签文本；`null` = 不显示。
  final String? badge;

  /// 未读红点是否受「发布日期 ≥ 未读基准线」约束。
  ///
  /// 只有教务处公告为 `true`：用户首次打开公告页的那天被记为基准线，
  /// 早于那天的旧公告不该一直挂着红点。其余源为 `false`，
  /// 即「没读过就标未读」。
  final bool usesUnreadBaseline;

  const MessageChannel({
    required this.id,
    required this.name,
    this.desc = '',
    this.defaultSubscribed = false,
    this.badge,
    this.usesUnreadBaseline = false,
  });

  @override
  bool operator ==(Object other) =>
      other is MessageChannel && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 消息源契约。
///
/// **一个源 = 一个渠道 = 一种抓法。** 抓取逻辑各源独立实现（教务处走
/// `JwcCrawler`、校园资讯走 `CampusInfoCrawler`），本抽象只固定**上层
/// 接口**，让状态层、列表、详情、已读全部只面向本接口编程。
///
/// 🔴 被锁死的是**步骤**，不是抓取代码。任何源都必须走完同一条流水线：
/// ```text
/// 注册源 → 抓取 → 入档 → 通知 → 展示 → 详情
/// ```
/// 第 1 步各源自己写（本文件的两个方法 + 一个详情方法），
/// 第 2~6 步由 [CachedMessageSource] 与 `MessageRepository` 统一提供。
/// 新增一个来源 = 只写第 1 步。
///
/// 实现类：
/// - `lib/services/sources/jwc_source.dart`（教务处公告）
/// - `lib/services/sources/campus_source.dart`（校园资讯栏目）
abstract class MessageSource {
  /// 本源的渠道描述符。
  MessageChannel get channel;

  /// 拉取本源的列表。
  ///
  /// [mode] 决定"要不要联网、抓多少"，见 [FetchMode]。
  /// [q] 非空时按标题模糊过滤（由基类在**档案**上做，各源不必管）。
  ///
  /// 🔴 **实现约定**：抓取失败时**必须**返回 `MessagePage(error: 非空)`，
  /// 且若存在旧档案应一并带上（`items` 填旧档案、`fromCache: true`）。
  /// 绝不能 `error: null` + 空列表 —— 那会让上层把「失败」显示成「没内容」，
  /// 并可能用空列表覆盖档案。这是本项目发作次数最多的 bug。
  Future<MessagePage> fetch({
    required FetchMode mode,
    String q = '',
  });

  /// 拉取详情。返回 `null` 表示失败（**不是**「没有正文」）。
  Future<MessageDetail?> fetchDetail(Message message);
}

/// 教务处公告的渠道 id。
///
/// 之所以不用 `school_*` 之类的旧前缀：它现在和其它渠道在同一体系里，
/// 统一成短 id 后已读键、档案键、页签索引全都用同一个值，不必再维护映射表。
const String kJwcChannelId = 'jwc';

/// 站点每页**最少**给多少条 —— 把「用户填的条数」换算成「页码预算」时用。
///
/// ## 为什么是 8（2026-10-08 逐页实测）
/// | 源 | 每页条数 |
/// |---|---|
/// | 教务处 | 12（共 1793 条 / 150 页） |
/// | 校园要闻 / 校园快讯 | 10 |
/// | 学工处 | 8 |
/// | 团委 | 16 |
///
/// 取**最小值**是刻意的保守方向：本常量只用来算「最多允许翻几页」，
/// 而翻页循环会在**凑够目标条数时立刻停下**，所以算多了不花任何代价，
/// 算少了才会真的抓不够。取最小值可以保证任何源都凑得到目标。
///
/// ⚠️ 曾经这里是 20，而注释自己写着「1 页 → 12 条」—— 自相矛盾，
///    且会让「40 条」只算出 2 页（实际只够 24 条）。改这个值前请先实测。
const int kMessageItemsPerPage = 8;

/// 抓取的**硬顶页数**（防脏链接/错分页打爆上百个不存在的页）。
///
/// 取 150 是因为教务处**全站就 150 页**（实测 1793 条）。也就是说
/// 教务处的真实上限约 1793 条 —— 用户即使把「最多同步条数」拉到 2000，
/// 也只能拿到站点确实有的那些，这一点无法靠加大页数解决。
const int kMaxFetchPages = 150;

/// 用户填的条数 → **页码预算**（不是"必须抓这么多页"，而是"最多允许翻这么多"）。
///
/// 用 [kMessageItemsPerPage]（最小值）作除数 → 得到的页数偏大 → 安全方向。
int pagesForItemCount(int count) {
  if (count <= 0) return 1;
  final pages = (count / kMessageItemsPerPage).ceil();
  return pages < 1 ? 1 : (pages > kMaxFetchPages ? kMaxFetchPages : pages);
}
