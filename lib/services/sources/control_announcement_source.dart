import '../../models/message.dart';
import '../control_api.dart';
import '../control_service.dart';
import '../message_source.dart';
import 'cached_source.dart';

/// 控制台公告渠道。
///
/// 插在消息页里作为独立一列：公告由控制台下发，与教务处/校园资讯走同一套
/// 列表、已读、搜索与详情容器，不另做页面。
const String kControlAnnouncementChannelId = 'control_notice';

/// ⚠️ **名称 2026-11-23 从「公告」改成「应用公告」**，id 一个字没动。
///
/// 理由：消息页同时存在「教务处」「校园要闻」等六七个栏目，一个页签只叫
/// 「公告」时，用户分不清它是**学校**发的通知还是**这个 App** 发的维护通知
/// （实测内容全是「内测群」「版本更新」这类）。改名后一眼能对上。
/// 🔴 只改 name/badge，**绝不能改 id** —— id 是订阅集合的键，
/// 改 id 等于把老用户的订阅清空。
const MessageChannel kControlAnnouncementChannel = MessageChannel(
  id: kControlAnnouncementChannelId,
  name: '应用公告',
  desc: '掌上锡院自身的版本更新与维护通知',
  defaultSubscribed: true,
  badge: '应用公告',
);

class ControlAnnouncementSource extends CachedMessageSource {
  /// 列表里已经拿到的正文，供详情页直接使用，避免二次请求。
  final Map<String, String> _bodies = {};

  @override
  MessageChannel get channel => kControlAnnouncementChannel;

  @override
  Future<List<Message>?> fetchIncremental() => _fetch();

  @override
  Future<List<Message>?> fetchFull(int target) => _fetch();

  Future<List<Message>?> _fetch() async {
    // 未登录：控制台门禁本就要求登录；这里返回空列表而不是错误，
    // 避免消息页给未登录用户显示一个红色的“加载失败”页签。
    if (!await ControlApi.allowed()) return <Message>[];
    final items = await ControlService.fetchMessages();
    if (items == null) return null;

    final out = <Message>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final id = (raw['id'] ?? '').toString().trim();
      final title = (raw['title'] ?? '').toString().trim();
      if (id.isEmpty || title.isEmpty) continue;
      _bodies[id] = (raw['body'] ?? '').toString();
      out.add(Message(
        id: id,
        sourceId: channel.id,
        title: title,
        date: (raw['date'] ?? '').toString(),
        url: '',
        badge: channel.badge,
      ));
    }
    return out;
  }

  @override
  Future<MessageDetail?> fetchDetail(Message message) async {
    var body = _bodies[message.id];
    if (body == null) {
      await _fetch();
      body = _bodies[message.id];
    }
    if (body == null) return null;
    return MessageDetail(
      id: message.id,
      sourceId: channel.id,
      title: message.title,
      date: message.date,
      author: '掌上锡院',
      url: '',
      content: body,
    );
  }
}
