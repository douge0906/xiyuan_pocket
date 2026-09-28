import 'package:flutter/foundation.dart';

/// 可订阅的消息渠道（v1.5.1）。
///
/// 与内置的「学校公告」分类不同，渠道是**可订阅、用户自选**的：
/// 用户在消息页点「＋」勾选感兴趣的渠道，勾选结果只存本地。
///
/// 渠道清单内置在客户端，订阅结果只存本地 —— **不采集、不上传用户偏好**。
@immutable
class NoticeChannel {
  /// 渠道唯一标识，如 `jwc_notice`。
  final String id;

  /// 展示名，如「教务处」。
  final String name;

  /// 一句话说明，用于勾选面板的副标题。
  final String desc;

  /// 数据来源页（用于将来接入真实抓取；示例阶段可能为空）。
  final String sourceUrl;

  /// 抓取器标识（对应客户端 `CampusInfoCrawler` 的栏目键；空表示尚未实现）。
  final String crawler;

  const NoticeChannel({
    required this.id,
    required this.name,
    this.desc = '',
    this.sourceUrl = '',
    this.crawler = '',
  });

  factory NoticeChannel.fromJson(Map<String, dynamic> j) => NoticeChannel(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? ''}',
        desc: '${j['desc'] ?? ''}',
        sourceUrl: '${j['source_url'] ?? ''}',
        crawler: '${j['crawler'] ?? ''}',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'desc': desc,
        'source_url': sourceUrl,
        'crawler': crawler,
      };

  /// 是否已接通真实数据源（决定界面上是否显示「筹备中」标记）。
  bool get isReady => crawler.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is NoticeChannel && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 渠道目录（内置清单 + 版本号）。
@immutable
class NoticeChannelCatalog {
  /// 目录版本：渠道有增减时递增（仅作记录）。
  final int version;
  final List<NoticeChannel> channels;

  const NoticeChannelCatalog({this.version = 0, this.channels = const []});

  bool get isEmpty => channels.isEmpty;

  factory NoticeChannelCatalog.fromJson(Map<String, dynamic> j) =>
      NoticeChannelCatalog(
        version: int.tryParse('${j['version']}') ?? 0,
        channels: (j['channels'] as List<dynamic>? ?? [])
            .map((e) => NoticeChannel.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'channels': channels.map((c) => c.toJson()).toList(),
      };
}
