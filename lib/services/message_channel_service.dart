import 'package:shared_preferences/shared_preferences.dart';

import 'campus/campus_info_crawler.dart';
import 'message_source.dart';
import 'sources/jwc_source.dart';

/// 消息栏目目录 + 订阅集合。
///
/// 【所有栏目一律平等】本文件里没有「内置特权」这一说：教务处只是一个
/// [MessageChannel.defaultSubscribed] 为 `true` 的普通栏目，用户一样能取消
/// 订阅。目录里每一项都能被关掉、也都能被重新打开。
///
/// 两条本地状态：
///  ① **栏目目录**：可订阅的全部栏目 —— **内置常量，不联网**
///     （抓取器随客户端发布，栏目清单属于静态配置，没有一处为「拿清单」发请求）。
///  ② **订阅集合**：用户勾选了哪些栏目。纯本地，不上传。
///
/// ⚠️ 存储键沿用旧版 `notice_channel_subscribed_v1` —— **故意不改**。
/// 改了名就等同于「老用户订阅被清空」，表现是升级后消息页突然只剩一个页签。
class MessageChannelService {
  MessageChannelService._();

  /// 沿用旧键（见类注释，改键 = 老用户订阅丢失）。
  static const String _kSubscribed = 'notice_channel_subscribed_v1';

  /// 校园资讯栏目的说明文案。
  ///
  /// **键集合即「对外开放的栏目集合」** —— 名单以这里为准，
  /// 名称与可用性从 [CampusInfoCrawler] 取（单一真相，避免两处各写一遍而漂）。
  ///
  /// 刻意**不含** `notice`：那是主站的「通知公告」，内容与教务处公告重复，
  /// 摆在同一个页面上只会让用户看到两份几乎一样的列表。
  static const Map<String, String> _campusDescs = {
    'news': '学校重要活动与对外交流',
    'express': '各学院的日常动态',
    'xgc': '奖助学金、评优与日常事务',
    'tw': '团学活动、志愿服务与公示',
  };

  /// 校园资讯栏目（顺序即展示顺序）。
  static List<MessageChannel> get campusChannels => _campusDescs.entries
      .map(_toChannel)
      .whereType<MessageChannel>()
      .toList();

  /// 把「说明文案」条目补全成完整栏目（名称与可用性取自抓取器）。
  ///
  /// 目录里写了、抓取器里却没有这个栏目 = 两处配置漂了。开发期用 assert
  /// 直接暴露；发布版静默跳过，绝不让一个幽灵栏目把页面搞崩。
  static MessageChannel? _toChannel(MapEntry<String, String> e) {
    final col = CampusInfoCrawler.columnById(e.key);
    assert(col != null, '栏目「${e.key}」未在 CampusInfoCrawler 登记');
    if (col == null) return null;
    return MessageChannel(
      id: col.id,
      name: col.name,
      desc: e.value,
      badge: col.name,
    );
  }

  /// 全部可订阅栏目：教务处 + 校园资讯栏目。
  static List<MessageChannel> get allChannels => [
        kJwcChannel,
        ...campusChannels,
      ];

  /// 默认订阅集合 = 所有 [MessageChannel.defaultSubscribed] 的栏目。
  ///
  /// 目前只有教务处 —— 用户口径是「所有栏目都是可选项，只不过默认把教务处
  /// 那个放到台面上来」。其余栏目在订阅面板里一勾即出现。
  static Set<String> get defaultSubscribedIds => {
        for (final c in allChannels)
          if (c.defaultSubscribed) c.id,
      };

  /// 读取订阅集合。
  ///
  /// **从未保存过** → 返回默认集合（教务处）；保存过 `[]`（用户把所有栏目都
  /// 关掉了）→ 返回空集。两者必须分开：不分开就会出现「用户关光了栏目，
  /// 下次启动又自己长回来」。
  static Future<Set<String>> loadSubscribed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kSubscribed);
      if (raw == null) return defaultSubscribedIds;
      // 过滤掉已下线/不再开放的栏目 id（老版本存下的残留不会变成幽灵页签）。
      final known = {for (final c in allChannels) c.id};
      return raw.where(known.contains).toSet();
    } catch (_) {
      return defaultSubscribedIds;
    }
  }

  /// 保存订阅集合。
  static Future<void> saveSubscribed(Set<String> ids) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kSubscribed, ids.toList(growable: false));
    } catch (_) {
      // 存储失败不影响本次使用（本次会话内订阅仍然生效）
    }
  }
}
