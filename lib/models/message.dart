import 'package:flutter/foundation.dart';

/// 统一消息模型 —— **所有消息列表共用的一种列表项**。
///
/// 【为什么有它】重构前消息页有两套并行模型：教务处公告一套、校园资讯栏目
/// 一套，字段八成同构却各写各的，导致列表、详情、已读状态都要做两遍、
/// 并且互相漂移（渠道列表的注释里曾写着「与学校公告卡一致」—— 那是
/// 复制粘贴对齐的痕迹）。
///
/// 【不合并什么】**抓取逻辑仍然各源独立** —— 教务处走 `JwcCrawler`、
/// 校园资讯走 `CampusInfoCrawler`，本来就是两类站点结构，不该硬凑成一个
/// 大 service。合并的是它们**上面**的每一层：状态、列表、详情容器、已读。
@immutable
class Message {
  /// **源内唯一** id（不同源之间可能重复，故必须配合 [sourceId] 使用）。
  final String id;

  /// 来源渠道 id：`'jwc'`（教务处）/ `'news'` / `'express'` / `'xgc'` / `'tw'`。
  final String sourceId;

  final String title;

  /// 展示用日期字符串。
  ///
  /// 源给的就是字符串，**不做解析** —— 各源日期格式不统一，强行解析成
  /// `DateTime` 只会引入「某个源格式一变就崩」的新故障。
  final String date;

  /// 原文链接。
  ///
  /// 🔴 它同时是**详情抓取的唯一入口**：列表项随身带着 URL，详情就不必
  /// 再回头去"按 id 反查 URL"。此前那个反查走的是另一套缓存键，一旦键
  /// 迁移没跟上，症状是「列表正常、点进去白屏」这种最难查的形态。
  final String url;

  /// 左侧来源标签文本（如「教务处」）；`null` 表示不显示。
  ///
  /// 为什么需要：统一成一套列表后，不同来源的条目长得一样，用户就分不清
  /// 哪条是哪来的。用来源标签点出来，是统一 UI 前提下**必须**补的区分手段。
  final String? badge;

  const Message({
    required this.id,
    required this.sourceId,
    required this.title,
    required this.date,
    required this.url,
    this.badge,
  });

  /// **全局唯一键**，用于已读状态。
  ///
  /// 格式 `<sourceId>:<id>`。重构前教务处公告用 `school_<id>`、资讯用
  /// `<channelId>_<id>`，两套约定并存；统一后只有这一种形态。
  String get key => '$sourceId:$id';

  Message copyWith({
    String? title,
    String? date,
    String? url,
    String? badge,
  }) =>
      Message(
        id: id,
        sourceId: sourceId,
        title: title ?? this.title,
        date: date ?? this.date,
        url: url ?? this.url,
        badge: badge ?? this.badge,
      );

  @override
  bool operator ==(Object other) => other is Message && other.key == key;

  @override
  int get hashCode => key.hashCode;

  Map<String, dynamic> toJson() => {
        'id': id,
        'source_id': sourceId,
        'title': title,
        'date': date,
        'url': url,
        'badge': badge,
      };

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        id: (j['id'] ?? '').toString(),
        sourceId: (j['source_id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
        badge: j['badge'] as String?,
      );

  @override
  String toString() => 'Message($key)';
}

/// 消息详情（**已解析好正文**的形态）。
///
/// [content] 是 Markdown 源码，[attachments] 是附件列表。
/// 这是各源**共有的最大公约数** —— 它们本来就都是「标题 + 日期 + 作者 +
/// Markdown 正文 + 附件」，所以详情容器可以完全共用，无需 `if` 分支。
@immutable
class MessageDetail {
  final String id;
  final String sourceId;
  final String title;
  final String date;
  final String author;
  final String url;

  /// Markdown 正文。
  final String content;

  final List<Map<String, dynamic>> attachments;

  const MessageDetail({
    required this.id,
    required this.sourceId,
    required this.title,
    required this.date,
    required this.author,
    required this.url,
    this.content = '',
    this.attachments = const [],
  });

  /// 正文与附件都空 —— 详情区据此显示「暂无正文」而不是留白。
  bool get isEmpty => content.trim().isEmpty && attachments.isEmpty;
}

/// 一次拉取的结果。
///
/// 🔴 **失败与空必须分开** —— 这是本项目发作次数最多的 bug（累计 6~7 次）。
/// 重构前教务处服务抓取失败时返回 `(items: [], total: 0)`，与「真的没有
/// 公告」返回完全相同的东西，调用方无法区分，于是把失败显示成
/// 「今天没新公告」。
///
/// 本类用 [error] 显式承载失败：[error] != null 时 [items] 仍可能是
/// **上次的档案**（降级展示），绝不能被当成空列表去覆盖档案。
class MessagePage {
  final List<Message> items;

  /// 档案里共有多少条；`<= 0` 表示未知。
  final int total;

  /// 本次数据是否来自本地档案（用于「显示的是上次结果」提示）。
  final bool fromCache;

  /// 🔴 失败原因；`null` 表示本次拉取成功（哪怕结果为空）。
  final String? error;

  const MessagePage({
    this.items = const [],
    this.total = 0,
    this.fromCache = false,
    this.error,
  });

  /// 这次拉取是否失败。
  ///
  /// **永远不要**用 `items.isEmpty` 判断失败 —— 那是历史 bug 的根。
  bool get isFailure => error != null;
}
