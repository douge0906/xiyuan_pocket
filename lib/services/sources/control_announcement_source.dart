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

const MessageChannel kControlAnnouncementChannel = MessageChannel(
  id: kControlAnnouncementChannelId,
  name: '公告',
  desc: '掌上锡院公告与维护通知',
  defaultSubscribed: true,
  badge: '公告',
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
