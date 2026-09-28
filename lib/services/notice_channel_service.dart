import 'package:shared_preferences/shared_preferences.dart';

import '../models/notice_channel.dart';

/// 消息渠道服务。
///
/// 两条本地状态：
///  ① **渠道目录**：可直接订阅的校园资讯栏目清单 —— **内置常量**，不联网。
///  ② **订阅集合**：用户勾选了哪些渠道。纯本地，不上传。
///
/// 【开源版】目录为内置常量，不联网。
/// 这 4 个渠道对应的抓取器（`CampusInfoCrawler`）已随客户端一起发布，
/// 栏目清单属于**静态配置** ——
/// 也正因为如此，开源版没有任何一处会为「拿清单」而发起网络请求。
///
/// ⚠️ `_builtinChannels` 的 `source_url` 与 `CampusInfoCrawler` 的栏目配置
///    必须一致，改一处要同时改另一处（否则订阅了却抓不到内容）。
class NoticeChannelService {
  NoticeChannelService._();

  static const String _kSubscribed = 'notice_channel_subscribed_v1';

  /// 目录版本（渠道增减时 +1；仅作记录，无联网校验）。
  static const int catalogVersion = 2;

  static const List<Map<String, dynamic>> _builtinChannels = [
    {
      'id': 'news',
      'name': '校园要闻',
      'desc': '学校重要活动与对外交流',
    },
    {
      'id': 'express',
      'name': '校园快讯',
      'desc': '各学院的日常动态',
    },
    {
      'id': 'xgc',
      'name': '学工处',
      'desc': '奖助学金、评优与日常事务',
    },
    {
      'id': 'tw',
      'name': '团委',
      'desc': '团学活动、志愿服务与公示',
    },
  ];

  /// 内置目录
  static NoticeChannelCatalog get builtinCatalog => NoticeChannelCatalog(
        version: catalogVersion,
        channels: _builtinChannels
            .map((m) => NoticeChannel.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
      );

  /// 读取目录 —— 恒为内置常量，**不发起任何网络请求**。
  ///
  /// `force` 参数保留是为了兼容既有调用方（下拉刷新），语义上"重新读取内置清单"，
  /// 与不传时结果相同。
  static Future<NoticeChannelCatalog> loadCatalog({bool force = false}) async =>
      builtinCatalog;

  /// 读取已订阅的渠道 id 集合。
  static Future<Set<String>> loadSubscribed() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_kSubscribed) ?? const []).toSet();
  }

  /// 保存订阅集合。
  static Future<void> saveSubscribed(Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kSubscribed, ids.toList(growable: false));
  }
}
