import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';

/// 详情缓存 —— **所有源共用的一套**。
///
/// 重构前有两套详情缓存（教务处一套、资讯栏目一套），键格式还不一样
/// （`<id>` vs `<栏目>_<id>`）。这既是重复实现，也是「详情反查 URL 走的是
/// 另一套键」那个 bug 的温床：键一迁移，漏掉哪一套都是「点进去白屏」。
///
/// 现在键统一为 `message_detail_<sourceId>:<id>` —— 与 [Message.key] 同源，
/// 不存在两套约定。
class MessageDetailCache {
  static const String _prefix = 'message_detail_';

  static String _key(String sourceId, String id) => '$_prefix$sourceId:$id';

  static Future<MessageDetail?> load(String sourceId, String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(sourceId, id));
      if (raw == null || raw.isEmpty) return null;
      return _fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // 缓存损坏当没有：宁可重新抓一次。
      return null;
    }
  }

  static Future<void> save(MessageDetail detail) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _key(detail.sourceId, detail.id), jsonEncode(_toJson(detail)));
    } catch (_) {
      // 存储失败不影响本次使用
    }
  }

  static Map<String, dynamic> _toJson(MessageDetail d) => {
        'id': d.id,
        'source_id': d.sourceId,
        'title': d.title,
        'date': d.date,
        'author': d.author,
        'url': d.url,
        'content': d.content,
        'attachments': d.attachments,
      };

  static MessageDetail _fromJson(Map<String, dynamic> j) => MessageDetail(
        id: (j['id'] ?? '').toString(),
        sourceId: (j['source_id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        author: (j['author'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
        content: (j['content'] ?? '').toString(),
        attachments: ((j['attachments'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
      );

  /// 供种子数据直接写入（键格式保持一致）。
  static Future<void> seed(Map<String, dynamic> raw) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = (raw['id'] ?? '').toString();
      final sourceId = (raw['source_id'] ?? '').toString();
      if (id.isEmpty || sourceId.isEmpty) return;
      final k = _key(sourceId, id);
      if (prefs.getString(k)?.isNotEmpty == true) return;
      await prefs.setString(k, jsonEncode(raw));
    } catch (_) {}
  }
}
