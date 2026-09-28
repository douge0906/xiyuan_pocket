# 消息系统统一改造方案

> 目标：把「学校公告」与「校园资讯」这两套**同质异源**的平行实现，收敛成**一套消息数据模型 + 一套来源适配器 + 一套列表/详情 UI**。
> 约束：Flutter **3.24.3** / Dart **3.5.3**；纯客户端、无服务器；不改 `assets/seed/app_seed.json` 结构；`flutter analyze lib` 必须零 warning 零 info。
> 本文档仅为方案，**不修改任何 `lib/` 下代码**。落地按第 6 节的步骤分次提交、分次验证。

---

## 1. 问题与现状核实

用户判断正确：二者在产品上是**同一类东西**（学校发布的消息列表），只是来源不同；代码层却是两套独立实现。

### 1.1 两套平行实现对照（均已读源码核实）

| 关注点 | 学校公告（教务处） | 校园资讯（官网栏目） |
|---|---|---|
| 列表模型 | `SchoolNotice`（`lib/models/school_notice.dart`） | `CampusInfoItem`（`lib/services/campus_info_service.dart:7`） |
| 详情模型 | 无（直接传 `Map<String,dynamic>`） | `CampusInfoDetail`（`lib/services/campus_info_service.dart:40`） |
| 列表服务 | `SchoolNoticeService.fetchList`（`lib/services/school_notice_service.dart:25`） | `CampusInfoService.fetchList`（`lib/services/campus_info_service.dart:89`） |
| 详情服务 | `SchoolNoticeService.fetchDetail`（:107） | `CampusInfoService.fetchDetail`（:171） |
| 详情页 | `lib/pages/school_notice_detail_page.dart`（277 行） | `lib/pages/campus_info_detail_page.dart`（206 行） |
| 列表卡片 | `SchoolNoticeCard`（`lib/pages/message/message_cards.dart:12`） | 无卡片，页面内联 Row（`notification_page.dart:490`） |
| 抓取器 | `JwcCrawler`（`lib/services/campus/jwc_crawler.dart`） | `CampusInfoCrawler`（`lib/services/campus/campus_info_crawler.dart`） |
| 列表缓存键 | `school_notice_list_cache` | `campus_info_list_<columnId>` |
| 详情缓存键 | `school_notice_detail_<id>` | `campus_info_detail_<columnId>_<id>` |
| 未读基准线 | `school_notice_unread_baseline` | 无 |
| 已读键前缀 | `school_<id>` | 无（渠道当前不标记已读） |

**关键发现（决定改造量）**：
1. 两个抓取器**已经共用**数据类 `NoticeItem` / `NoticeDetail`（`campus_info_crawler.dart:2` 显式 `show NoticeItem, NoticeDetail`）——抓取层重复早已消除在数据类层面。
2. 两套 UI 已统一到 `notification_page.dart`（chips 切换 + PageView 左右滑动，见 :319 / :800），但**数据层仍是两条独立代码路径**（`_buildSchoolNotices` :686 vs `_buildChannelContent` :457）。
3. `MessageReadStorage`（`lib/models/message_read_storage.dart`）已是一套共用已读存储。
4. 另有一套与之**概念重叠**的 `NoticeChannel` + `NoticeChannelService`（`lib/models/notice_channel.dart`、`lib/services/notice_channel_service.dart`）——"渠道"其实等价于"来源"，是同一套二分法的第三处重复。

### 1.2 实际字段清单（逐字核对，非猜测）

- 种子资产顶层键（`assets/seed/app_seed.json`）：`v`、`notices`、`notice_details`、`columns`、`details`。
- `notices[]` 元素：`id, title, date, url, has_content, views`
- `notice_details[<id>]`：`title, date, author, content, attachments`
- `columns[<colId>][]` 元素：`id, title, date, url, column`
- `details[<colId>_<itemId>]`：`id, title, date, author, url, content, attachments`
- `SchoolNotice`（Dart）：`id,title,date,url,hasContent,views`
- `CampusInfoItem`（Dart）：`id,title,date,url,column`
- 抓取器 `NoticeItem`：`id,title,date,url`（其 `toJson` 才补 `has_content:false, views:0`）
- 抓取器 `NoticeDetail`：`title,date,author,content,attachments`，其中 `attachments` 为 `List<Map<String,String>>`（`campus_web.dart:202`）
- `CampusInfoDetail`：`id,title,date,author,url,content,attachments`（`List<Map<String,dynamic>>`）

**字段差异（即兼容点）**：
| 字段 | 教务处 | 官网栏目 | 统一后 |
|---|---|---|---|
| 全局唯一性 | `id` 单段（`5965`） | `column + id`（`notice` + `1039_21435`） | 加 `sourceId` 区分，键 = `sourceId:id` |
| `views` | 有（仅种子携带） | 无 | 保留，缺省 0 |
| `has_content` | 有但**全程未被读取**（`grep` 确认仅赋值/序列化，无消费） | 无 | **删除** |
| `column` | 无（隐含 jwc） | 有 | 改名 `sourceId`，教务处也用 `'jwc'` |
| 详情附件元素类型 | `Map<String,String>` | `Map<String,dynamic>` | 统一 `Map<String,dynamic>` |

### 1.3 失效来源现状

- 主站 `www.cwxu.edu.cn` 三栏目（`notice`/`news`/`express`）与学工处 `xgc`：已部分失效（主站 404、学工处改版为 JS 动态渲染）。
- 教务处 `jwc.cwxu.edu.cn`：健康（种子最新 2026-09-21）。
- 团委 `tw.cwxu.edu.cn`：与教务处同一 CMS 模板，**默认按可用处理，上线前需实测确认**。

---

## 2. 统一数据模型

新增 `lib/models/message.dart`（**替换** `school_notice.dart` 的 `SchoolNotice` 与 `campus_info_service.dart` 的 `CampusInfoItem`/`CampusInfoDetail`）：

```dart
import 'package:flutter/foundation.dart';

/// 统一消息条目（列表项）。学校公告与各校园资讯来源共用同一形态。
@immutable
class Message {
  final String sourceId; // 'jwc' | 'notice' | 'news' | 'express' | 'xgc' | 'tw'
  final String id;       // 来源内唯一
  final String title;
  final String date;     // 'yyyy-MM-dd'，可能为空
  final String url;      // 原文地址
  final int views;       // 浏览数；无数据时为 0（仅教务处种子有）

  const Message({
    required this.sourceId,
    required this.id,
    required this.title,
    required this.date,
    required this.url,
    this.views = 0,
  });

  /// 全局唯一键：已读存储 / 跨来源去重用。
  String get key => '$sourceId:$id';

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        sourceId: (j['source_id'] ?? '').toString(),
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
        views: (j['views'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'source_id': sourceId,
        'id': id,
        'title': title,
        'date': date,
        'url': url,
        'views': views,
      };
}

/// 统一消息详情（正文 + 附件）。无内容时返回空对象而非 null。
@immutable
class MessageDetail {
  final String title;
  final String date;
  final String author;
  final String content; // Markdown
  final List<Map<String, dynamic>> attachments;

  const MessageDetail({
    this.title = '',
    this.date = '',
    this.author = '',
    this.content = '',
    this.attachments = const [],
  });

  bool get isEmpty => title.isEmpty && content.isEmpty && attachments.isEmpty;

  factory MessageDetail.fromJson(Map<String, dynamic> j) => MessageDetail(
        title: (j['title'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        author: (j['author'] ?? '').toString(),
        content: (j['content'] ?? '').toString(),
        attachments: ((j['attachments'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'date': date,
        'author': author,
        'content': content,
        'attachments': attachments,
      };
}
```

**设计取舍**：
- 列表项与详情**合成两个类**而非一个：详情是懒加载、可缺失，混进一个类会塞满可空字段，反而难读。
- 详情**不**再带 `id/url`：`Message` 已有，避免冗余（原 `CampusInfoDetail` 冗余携带 `id/url`）。
- 保留 `views`（卡片要用），删除 `has_content`（全程无消费者）。

---

## 3. 来源适配器

新增 `lib/services/message/message_source.dart`。这是**唯一新增的抽象**，用途明确：把"每个来源各自的抓取调用形状"归一成同一对方法，从而让上层服务/UI 不再认识具体抓取器。

```dart
import '../campus/campus_http_fetcher.dart';
import '../campus/jwc_crawler.dart' show NoticeItem, NoticeDetail;
import '../campus/campus_info_crawler.dart';

/// 一个消息来源。把不同抓取实现归一成同一对方法。
abstract class MessageSource {
  const MessageSource();

  String get id;
  String get name;      // chips / 详情页标题
  String get desc;      // 订阅面板副标题
  bool get isBuiltin;   // true = 内置固定页签（教务处），不出现在订阅面板
  bool get enabled;     // false = 已知失效：不联网，仅展示历史缓存

  Future<List<NoticeItem>> fetchList({int maxItems = 60});
  Future<NoticeDetail?> fetchDetail(String url);
}

/// 教务处（内置，数据源健康）。
class JwcMessageSource extends MessageSource {
  const JwcMessageSource();
  @override String get id => MessageSources.jwc;
  @override String get name => '教务处';
  @override String get desc => '教务处通知公告';
  @override bool get isBuiltin => true;
  @override bool get enabled => true;
  @override
  Future<List<NoticeItem>> fetchList({int maxItems = 60}) =>
      JwcCrawler.fetchList(fetcher: CampusHttpFetcher.inject, maxPages: 1);
  @override
  Future<NoticeDetail?> fetchDetail(String url) =>
      JwcCrawler.fetchDetail(fetcher: CampusHttpFetcher.inject, detailUrl: url);
}

/// 官网栏目（可订阅）。一个类参数化服务全部栏目，不按栏目建子类。
class CampusColumnSource extends MessageSource {
  @override final String id;
  @override final String name;
  @override final String desc;
  @override final bool enabled;
  const CampusColumnSource({
    required this.id,
    required this.name,
    required this.desc,
    required this.enabled,
  });
  @override bool get isBuiltin => false;
  @override
  Future<List<NoticeItem>> fetchList({int maxItems = 60}) =>
      CampusInfoCrawler.fetchList(
          fetcher: CampusHttpFetcher.inject, columnId: id, targetItems: maxItems);
  @override
  Future<NoticeDetail?> fetchDetail(String url) =>
      CampusInfoCrawler.fetchDetail(fetcher: CampusHttpFetcher.inject, detailUrl: url);
}

/// 来源注册表。订阅面板可见项 = channels；内置教务处 = builtin。
class MessageSources {
  MessageSources._();

  static const String jwc = 'jwc';

  static const JwcMessageSource builtin = JwcMessageSource();

  /// 与旧 `NoticeChannelService._builtinChannels` 一一对应（4 项，不含 notice 栏目）。
  /// enabled 直接写死在此处：改一个来源的可用性只需改一行。
  static const List<CampusColumnSource> channels = [
    CampusColumnSource(id: 'news',    name: '校园要闻', desc: '学校重要活动与对外交流', enabled: false),
    CampusColumnSource(id: 'express', name: '校园快讯', desc: '各学院的日常动态',     enabled: false),
    CampusColumnSource(id: 'xgc',     name: '学工处',   desc: '奖助学金、评优与日常事务', enabled: false),
    CampusColumnSource(id: 'tw',      name: '团委',     desc: '团学活动、志愿服务与公示', enabled: true),
  ];

  static final List<MessageSource> all = [builtin, ...channels];

  static MessageSource? byId(String id) {
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }
}
```

**每个现有抓取如何落成适配器**：
- `JwcCrawler` → `JwcMessageSource`，逐一转发两个静态方法，注入 `CampusHttpFetcher.inject`（与原 `SchoolNoticeService` 完全一致）。
- `CampusInfoCrawler` → `CampusColumnSource`（构造时传入 `id`），5 个栏目**共用一个类**，不做每个栏目一个子类。

**失效来源如何标记停用且互不影响**：
- `enabled: false` 只表示**"不尝试联网"**：`MessageService` 看到 `enabled==false` 时跳过网络调用，直接回退本地缓存/种子。**历史内容照常展示**，因此「校园资讯」功能与既有内容不丢。
- 各来源状态互相独立：某个 `enabled==false` 只影响它自己的联网，教务处的联网链路不受任何影响。
- 若某栏目将来恢复，只需把对应 `enabled` 改回 `true`，无需动其它代码。
- UI 侧可据 `enabled` 给停用来源一个弱提示（如 chips 面板里的「来源暂不可用」角标；沿用现有 `!ch.isReady → 筹备中` 角标的位置，文案可改为 `暂不可用`）。

---

## 4. 统一服务与缓存

新增 `lib/services/message/message_service.dart`（**替换** `SchoolNoticeService` + `CampusInfoService`）。

```dart
class MessageListResult {
  final List<Message> items;
  final int total;
  const MessageListResult({required this.items, required this.total});
  static const empty = MessageListResult(items: [], total: 0);
}

class MessageService {
  MessageService._();

  /// 缓存键（统一命名；迁移见第 5 节）。
  static String listKey(String sourceId) => 'message_list_$sourceId';
  static String detailKey(String sourceId, String id) => 'message_detail_${sourceId}_$id';

  /// 抓列表：缓存优先 + 后台刷新；搜索/强制时走网络；失败或停用回退缓存，绝不写空。
  static Future<MessageListResult> fetchList(
    String sourceId, {
    int limit = 20,
    int offset = 0,
    String q = '',
    bool force = false,
  });

  static Future<void> cacheList(String sourceId, List<Message> items);
  static Future<List<Message>> loadCachedList(String sourceId);

  /// 详情：缓存优先；缺失时用列表缓存里的 url 联网抓取并回写。
  static Future<MessageDetail?> fetchDetail(String sourceId, String id);
  static Future<MessageDetail?> loadCachedDetail(String sourceId, String id);

  /// 未读基准线（天级），按来源独立。
  static Future<String> loadOrInitUnreadBaseline(String sourceId);
}
```

**关键语义（逐条沿用现有正确行为，勿丢）**：
1. **空列表永不覆盖缓存**：`cacheList` 在 `items.isEmpty` 时直接返回（对应 `school_notice_service.dart:81` 的既有防回归注释，以及 `notification_page.dart:188` 的空列表保护）。这是历史 bug 的修复点，必须保留。
2. **先显示后加载**：`fetchList` 命中缓存即返回缓存，同时在后台刷新（仅当 `source.enabled`）。
3. **搜索不走缓存**：`q` 非空时强制走网络（`campus_info_service.dart:99` 的既有约定）。
4. **分页**：`_slice(messages, q, offset, limit)` 负责本地标题过滤 + 分页，`total` = 过滤后总数。教务处 `JwcMessageSource` 用 `maxPages:1` 只抓首页，与现状一致。
5. **停用来源**：`source.enabled == false` → 跳过联网，返回缓存切片。不会长时间转圈，也不会清空内容。

**内部辅助**（私有）：
- `_toMessage(String sourceId, NoticeItem it)`：`NoticeItem` → `Message`（views 传 0）。
- `_toDetail(NoticeDetail d)`：`NoticeDetail` → `MessageDetail`，附件做 `List<Map<String,String>>` → `List<Map<String,dynamic>>` 归一。
- `_readListCache(prefs, key)` / `_writeListCache(prefs, key, items)`：`Message.toJson/fromJson` 读写。

### 4.1 列表视图与详情页（UI 去重）

新增 `lib/pages/message/message_list_view.dart`：把现在 `_buildSchoolNotices`（:686，含分页/空态/错误态/红点）与 `_buildChannelContent`（:457，含空态/错误态）**合并为一个按来源工作的列表组件**：

```dart
class MessageListView extends StatefulWidget {
  final String sourceId;
  final String searchQuery; // 由父级防抖后传入；变化即重新加载
  const MessageListView({super.key, required this.sourceId, required this.searchQuery});
}
```
- State 混入 `AutomaticKeepAliveClientMixin`（`wantKeepAlive => true`），保证在 `PageView` 中"切来切去不重复请求、滚动位置保留"（对应现 `_channelStates` 缓存的意图）。
- 自行持有 `items/total/loading/loadingMore/error` 与 `ScrollController`（教务处需要上拉加载更多）。
- 下拉刷新 → `fetchList(force:true)`；点击条目 → `MessageReadStorage.markRead` + push `MessageDetailPage`，返回后重载已读集合触发红点刷新。

新增 `lib/pages/message/message_card.dart`：`SchoolNoticeCard` 泛化为 `MessageCard`，接收 `Message`；`views > 0` 时才显示浏览数（渠道无数据就不显示，保持诚实）。

新增 `lib/pages/message_detail_page.dart`：合并两个详情页（277 + 206 行 → 约 230 行）：

```dart
class MessageDetailPage extends StatefulWidget {
  final Message message;
  final String sourceName; // AppBar 标题
  const MessageDetailPage({super.key, required this.message, required this.sourceName});
}
```
- 缓存优先秒开 → `MessageService.fetchDetail(...)` 联网刷新 → 失败回退列表已有信息（沿用 `school_notice_detail_page.dart:41-61` 的三段式）。
- 渲染：标题 / 日期 / 作者 / `MarkdownBody` 正文 / 附件列表 / 「查看原文」。AppBar 保留「复制全文」与「查看原文」；正文底部保留公告页的「查看原文」大按钮。

### 4.2 渠道模型并入来源

删除 `lib/models/notice_channel.dart`（`NoticeChannel`/`NoticeChannelCatalog`），把订阅存储抽成 `lib/services/message/message_subscription_service.dart`（仅 `loadSubscribed()` / `saveSubscribed(Set<String>)`，**保留原 prefs 键 `notice_channel_subscribed_v1`，订阅结果零迁移**）。`notice_channel_service.dart` 的目录/`catalogVersion`/`NoticeChannel` 逻辑由 `MessageSources` 取代。

> 理由：`NoticeChannel {id,name,desc,crawler}` 与 `MessageSource {id,name,desc,enabled}` 是同一概念的两次表达，正是用户批评的"同一二分法在多处重复"。

---

## 5. 兼容性：种子快照旧格式迁移（不丢数据）

**不改 `assets/seed/app_seed.json`**（324 KB 资产，且贡献者可能自行重生成）。只在 `lib/services/seed_data.dart` 内把**旧资产结构映射到新的缓存键**。

映射表（资产结构不变，仅写入目标键变化）：

| 资产字段 | 新缓存键 | 处理 |
|---|---|---|
| `notices[]` | `message_list_jwc` | 每项 `{id,title,date,url,views}` 归一为 `Message(sourceId:'jwc')` 后 `toJson`（丢弃 `has_content`） |
| `notice_details[<id>]` | `message_detail_jwc_<id>` | 原样 `jsonEncode(value)` |
| `columns[<colId>][]` | `message_list_<colId>` | 每项归一为 `Message(sourceId:<colId>)` |
| `details[<colId>_<itemId>]` | `message_detail_<colId>_<itemId>` | 键 = `'message_detail_' + 资产键`（资产键本身已是 `<colId>_<itemId>`），值原样 `jsonEncode` |
| 默认订阅 | `notice_channel_subscribed_v1` | 写入 `MessageSources.channels` 的 4 个 id（与原 `_builtinChannels` 一致） |

要点：
- 新 `MessageService.detailKey('notice','1039_21435')` == `'message_detail_notice_1039_21435'` == `'message_detail_' + 资产键`，与写入端天然对齐。
- 写入仍遵守「仅当键缺失时写」（`_missing`），不覆盖用户已抓取的新数据。
- `SeedData._kApplied` 逻辑保留：由于新键变更，老用户下次启动会因 `message_list_jwc` 缺失而自动重新补齐种子——**不会白屏**。

**已读状态迁移**（`lib/models/message_read_storage.dart` 内新增，约 8 行）：
- 新增 `static String keyOf(String sourceId, String id) => '$sourceId:$id';`
- 新增 `static Future<void> ensureMigrated()`：若 `message_read_ids` 中存在以 `school_` 开头的项，一次性改写为 `jwc:<id>`（幂等）。在 `main.dart` 中 `SeedData.ensureApplied()` 之后调用一次。
- 其余方法（`loadReadIds`/`markRead`/`isRead`/`markUnread`/`markAllRead`）**不改**。

**未读基准线迁移**：`school_notice_unread_baseline` → `message_unread_baseline_jwc`，首次读取时若新键缺失则从旧键复制（`MessageService.loadOrInitUnreadBaseline` 内约 5 行）。

**旧缓存键清理**（可选，放在最后一步）：删除 `school_notice_list_cache`、`school_notice_detail_*`、`campus_info_list_*`、`campus_info_detail_*`、`school_notice_unread_baseline`。不清理也无害（仅占极少空间）。

---

## 6. 迁移步骤（每步可独立提交、独立验证）

> 每步收尾统一跑：`flutter analyze lib`（期望 `No issues found`）+ `flutter test`。涉及 UI 的步骤额外做真机走查。
> 原则：**先加后删**。新增文件在被引用前不产生 lint（公开类未引用不触发 `unused_element`）。

**S1 — 落地统一模型（无引用）**
- 新增 `lib/models/message.dart`（`Message` / `MessageDetail`）。
- 验证：`flutter analyze lib` 零 issue；`flutter test` 通过。无行为变化。

**S2 — 落地来源适配器（无引用）**
- 新增 `lib/services/message/message_source.dart`。
- 新增 `test/message_source_test.dart`：断言 `MessageSources.all` 含 `jwc` + 4 渠道、`builtin.isBuiltin==true`、`tw.enabled==true`、其余渠道 `enabled==false`、`byId('news')!.name=='校园要闻'`。不触网。
- 验证：analyze + test。无行为变化。

**S3 — 落地统一服务（无引用）**
- 新增 `lib/services/message/message_service.dart`。
- 新增 `test/message_service_test.dart`：用 `SharedPreferences.setMockInitialValues({})` 验证 `cacheList` 空列表不写、`loadCachedList` 往返一致、`_slice` 过滤/分页（可通过 `fetchList` 走缓存路径断言）、`loadOrInitUnreadBaseline` 幂等。
- 验证：analyze + test。无行为变化。

**S4 — 教务处链路切到统一实现 + 种子写新键**
- 新增 `lib/pages/message_detail_page.dart`、`lib/pages/message/message_card.dart`。
- 改 `notification_page.dart`：`_buildSchoolNotices` 改为渲染 `MessageListView(sourceId: 'jwc')`；`_onNoticeTap` → `MessageReadStorage.keyOf('jwc', id)` + `MessageDetailPage`。
- 改 `seed_data.dart`：`notices`/`notice_details` 改写入 `message_list_jwc` / `message_detail_jwc_<id>`；**校园栏目仍写旧键**（本步不动）。
- 改 `message_read_storage.dart` 加 `keyOf` + `ensureMigrated`；`main.dart` 调用 `ensureMigrated()`。
- 验证（真机）：清数据安装 → 消息页「教务处」页签秒出种子内容；下拉刷新正常；点开详情正文/附件/查看原文正常；新公告红点出现、点开后消失；搜索正常。其余渠道行为不变。

**S5 — 渠道链路切到统一实现 + 种子写新键**
- 改 `notification_page.dart`：`_activeChannelId` → `_activeSourceId`；`_allTabs` → `List<MessageSource>`（`builtin` + 已订阅 `channels`）；`_buildChannelContent` 改为 `MessageListView(sourceId: ch.id)`；`_openCampusInfo` → `MessageDetailPage`。
- 改 `seed_data.dart`：`columns`/`details` 改写入 `message_list_<col>` / `message_detail_<col>_<id>`；默认订阅改写 `MessageSources.channels` 的 id。
- 改 `notice_channel_service.dart` → `lib/services/message/message_subscription_service.dart`（仅订阅集合读写，保留 prefs 键）；`_ChannelPickerSheet` 改用 `MessageSource.name/desc/enabled`；`_showChannelPicker` 改用 `MessageSources.channels`。
- 验证（真机）：chips 显示「教务处 + 已订阅渠道」；点击/左右滑动切换一致；「＋」勾选/取消渠道后 chips 实时增减、取消当前渠道退回教务处；渠道能显示种子内容、下拉刷新正常（停用渠道不转圈、显示历史内容）、点开详情正常。

**S6 — 删除旧实现并清理**
- 删除：`lib/models/school_notice.dart`、`lib/services/school_notice_service.dart`、`lib/services/campus_info_service.dart`、`lib/pages/school_notice_detail_page.dart`、`lib/pages/campus_info_detail_page.dart`、`lib/pages/message/message_cards.dart`、`lib/models/notice_channel.dart`、`lib/services/notice_channel_service.dart`。
- 清理 `notification_page.dart` 中仅供旧实现使用的状态字段（`_notices`/`_noticeTotal`/`_noticeError`/`_channelStates`/`_NoticeTab`/`_ChannelState`/`_scrollController` 等），确认已由 `MessageListView` 接管。
- 可选：删除旧缓存键。
- 验证：analyze 零 issue；test 通过；完整跑一遍第 7 节回归清单；`flutter build apk --release --target-platform android-arm64` 成功。

**S7（可选，可单独丢弃）— 未读红点跨来源统一**
- 让每个来源都用 `loadOrInitUnreadBaseline(sourceId)`，红点逻辑对各来源一致（原先仅教务处有）。这是**行为增强**，若产品不需要，跳过本步即可，不影响 S1–S6。

---

## 7. 回归清单（改完真机逐条测）

1. 清数据全新安装 → 打开消息页：秒出内置内容，无白屏、无长转圈。
2. chips：默认显示「教务处 + 已订阅渠道」，顺序正确。
3. chip 点击切换列表正确；选中态高亮正确。
4. 左右滑动翻页与 chip 选中态同步（滑到第 N 页 → 第 N 个 chip 高亮）。
5. 「＋」订阅面板：勾选/取消渠道 → chips 实时增减；取消当前所在渠道 → 自动退回教务处。
6. 已读红点：新公告（发布日期 ≥ 基准线）显示红点；点开详情返回后红点消失；（若保留右滑标记未读）标记未读后再看红点行为符合预期。
7. 下拉刷新：教务处页强制刷新；渠道页强制刷新；刷新失败时旧内容不被清空。
8. 搜索：输入关键词过滤**当前来源**标题；清空恢复；渠道页搜索也生效。
9. 详情页：标题/日期/作者/Markdown 正文渲染正确；附件可点击打开；「查看原文」跳外部浏览器；「复制全文」成功。
10. 失效来源（`enabled:false`）：不出现长时间转圈；显示历史（种子）内容；有停用提示；教务处链路完全不受影响。
11. 空态/错误态：断网时有缓存显示缓存、无缓存显示「重新加载」并可重试。
12. 深色模式：列表卡片、详情页、chips、订阅面板配色正常。
13. 未读基准线跨来源相互独立（若做 S7）。
14. `flutter analyze lib` 零 warning 零 info；`flutter test` 全通过。
15. `flutter build apk --release --target-platform android-arm64` 构建成功。
16. 旁路回归：底部导航其它页（首页/课表/工具箱/我的）、上课提醒、桌面小组件不受影响（本次未触碰其代码，仅确认无连带编译问题）。

---

## 8. 工作量与风险

**改动规模（估）**：
| 类别 | 文件数 | 行数（估） |
|---|---|---|
| 新增 | 6（`message.dart`、`message_source.dart`、`message_service.dart`、`message_subscription_service.dart`、`message_card.dart`、`message_detail_page.dart`）+ 1 列表组件 | 约 +920 |
| 改写 | `notification_page.dart`（1034 → 约 450）、`seed_data.dart`(+40)、`message_read_storage.dart`(+30)、`main.dart`(+2) | 约 +300 / −590 |
| 删除 | 8 个旧文件（合计约 1169 行） | 约 −1169 |
| 新增测试 | 2 | 约 +120 |
| **净变化** | **约 13 个文件** | **净减约 700 行** |

**最大风险点（按严重度）**：
1. **`notification_page.dart` 行为回归（最高）**：该文件 1034 行、状态交织（chips 索引 / PageView 索引 / 订阅集合 / 搜索防抖 / 已读 / 基准线 / 分页）。重构为单一数据路径时，最易破坏"chip 与滑动对齐""切来源不重复请求""空列表不覆盖缓存"。
   - 缓解：保持 `_allTabs`/`_currentTabIndex`/`_switchTo` 的**索引一致性设计不动**，只替换数据层与条目组件；用 `AutomaticKeepAliveClientMixin` 保证跨页保活；先切教务处（S4）再切渠道（S5），分两次验证；保留 `cacheList` 空列表守卫并有测试。
2. **失效来源的产品决策（中）**：把主站/xgc 标 `enabled:false` 后，这些渠道不再联网、只显示历史内容。若产品希望改为"从订阅面板隐藏"，只需在 `MessageSources.channels` 增删条目/改 `enabled`，改动点集中在一处。
3. **已读键迁移（中低）**：`school_<id>` → `jwc:<id>` 若漏迁移，仅导致教务处公告红点重新出现一次，无数据损坏；`ensureMigrated` 幂等零风险。
4. **`tw` 栏目可用性未知（低）**：默认按可用处理，上线前需实测；若实测失效，改一行 `enabled:false`。

---

## 9. 明确不做（按"能简单就不要复杂"）

1. **不合并两个抓取器**（`JwcCrawler` / `CampusInfoCrawler`）：二者 HTML 模板、翻页参数、无年份日期推断规则完全不同，合并只会造出一个脆弱的大 if-else；它们已共用 `NoticeItem`/`NoticeDetail`，**重复早已消除在数据类层**，抓取层保持独立是正确边界。
2. **不为每个来源建子类**：`JwcMessageSource` 一个 + `CampusColumnSource` 一个（参数化服务 5 个栏目）足够。拒绝"每栏目一个类"式的类爆炸。
3. **不引入状态管理重构**：不把 `StatefulWidget + setState` 改成 Riverpod provider。现有页面工作良好，为"统一"而引入 provider 属"为统一而新增抽象层"，高风险低收益。
4. **不引入代码生成/序列化库**：不加 `json_serializable`/`freezed`，手写 `fromJson/toJson` 足够，新增构建依赖违背"低依赖"。
5. **不引入本地数据库**：不上 `sqflite`/`Isar`。每来源缓存规模 ≤ 60 条，`SharedPreferences` 足够。
6. **不改 `assets/seed/app_seed.json` 结构**：只在代码侧做映射，避免让贡献者重新生成 324 KB 资产。
7. **不删除「校园资讯」**：按用户要求保留；失效来源只标 `enabled:false`（显示历史内容 + 弱提示），不删功能、不删已缓存内容。
8. **不给渠道凭空造 `views`**：渠道无浏览数就不显示，不显示 0 占位。
9. **不改未读红点的"天级基准线"算法**：这是既有产品行为，统一时原样保留（教务处语义不变）。
10. **不做服务端聚合**：项目定位纯客户端直连，不新增任何服务器侧逻辑。

---

## 10. 关键决策记录（ADR 内联）

**ADR-001：以"来源（source）"取代"渠道 + 公告"的二分**
- 背景：`NoticeChannel` 与 `SchoolNotice`/`CampusInfoItem` 是同一"消息来源"概念的三处表达。
- 决策：统一为 `MessageSource` + `Message`（带 `sourceId`）；教务处为内置来源（`isBuiltin`），官网栏目为可订阅来源。
- 后果：+ 消除概念重复、chips/详情/卡片/服务全部单一实现；− 需一次性迁移已读键与种子缓存键。

**ADR-002：失效来源用 `enabled` 开关而非删除**
- 背景：主站 404、学工处 JS 改版，但用户明确要保留「校园资讯」。
- 决策：`enabled` 只控制"是否联网"，历史内容照常展示。
- 后果：+ 保留内容与功能、单点可恢复；− 用户看到的是可能过期的历史内容（已用弱提示说明）。

**ADR-003：抓取层不合并**
- 背景：两个爬虫模板异构。
- 决策：保留两个爬虫，仅在其上做薄适配。
- 后果：+ 解析逻辑稳定、各自可独立维护；− 抓取层仍有"两条入口"（但边界清晰、非重复）。

**ADR-004：缓存键统一 + 代码侧映射种子（不改资产）**
- 背景：需统一键名，又不能动 324 KB 资产。
- 决策：新键 `message_list_*` / `message_detail_*`，`SeedData` 负责旧资产 → 新键映射；旧键可后续清理。
- 后果：+ 键名一致、老用户自动补齐种子不白屏；− 需过渡期注意 S4/S5 的两步键切换（已在步骤中显式列出）。

---

## 11. 端到端验证步骤（收尾即验收）

1. `flutter pub get && flutter analyze lib` → 期望 `No issues found`。
2. `flutter test` → 期望全部通过（含新增 `message_source_test.dart` / `message_service_test.dart`）。
3. `flutter build apk --release --target-platform android-arm64` → 构建成功。
4. 真机（校园网内）安装 release 包，**首次清数据**打开 → 消息页秒出内容。
5. 走查第 7 节清单第 2–13 条（chips / 滑动 / 订阅 / 红点 / 刷新 / 搜索 / 详情 / 附件 / 失效来源 / 空态 / 深色）。
6. 关键错误流：飞行模式断网下拉刷新 → 已有内容不被清空；无缓存来源显示「重新加载」并可恢复。
7. 验收判据：analyze 零 issue + test 全绿 + 第 7 节逐条通过 + 构建成功 = 本次统一交付完成。
