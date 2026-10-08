import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';

/// **本地档案库** —— 所有消息源共用的一套列表存储。
///
/// 🔴 抽出来的理由：重构前每个源各写一套缓存，教务处存一种格式、
/// 资讯栏目存另一种，两套合并、两套「失败时回退」。于是「同一个设置只
/// 对一半源生效」这类 bug 反复出现 —— **同一个机制写两遍，就一定会漂。**
/// 现在统一存 [Message]，键按 `source_id` 分开。
///
/// ## 语义（准确表述，别再写「只增不减」）
/// **上限内只增不减；上限由「最多同步 N 条」这个设置决定。**
///
/// [merge] 只去重、**不截断**；截断由 `CachedMessageSource._trim` 负责。
/// 分层理由：存储层不该去读用户设置。
///
/// ⚠️ 用户已明确接受「调小 N 时会真的丢弃多出来的条目（连同它们的详情
/// 链接）」，并要求**不做兜底**。所以这不是 bug，是有意行为 —— 但改动
/// 这里之前请先确认口径没变。
class MessageArchive {
  static const String _prefix = 'message_archive_';

  static Future<List<Message>> load(String sourceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_prefix$sourceId');
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map>()
          .map((e) => Message.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      // 档案损坏当空处理：宁可重新抓，也不要卡在解析失败上。
      return const [];
    }
  }

  static Future<void> save(String sourceId, List<Message> items) async {
    // 🔴 空列表**一律不写**：否则一次网络失败就会把档案洗掉。
    if (items.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          '$_prefix$sourceId', jsonEncode(items.map((e) => e.toJson()).toList()));
    } catch (_) {
      // 存储失败不影响本次使用
    }
  }

  /// 按 key 去重合并，**新 → 旧**排序。[fresh] 优先（它更新）。
  ///
  /// ⚠️ 本方法**只去重、不截断**（长度只增不减）。
  static List<Message> merge(List<Message> archive, List<Message> fresh) {
    final seen = <String>{};
    final out = <Message>[];
    for (final e in [...fresh, ...archive]) {
      if (seen.add(e.key)) out.add(e);
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  /// 清空某个源的档案（「清除本机消息缓存」用）。
  static Future<void> clear(String sourceId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_prefix$sourceId');
    } catch (_) {}
  }
}
