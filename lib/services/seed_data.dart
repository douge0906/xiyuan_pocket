import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

/// 内置种子数据：把**服务器上已经爬好的内容**打进 App，让首次打开秒出内容。
///
/// 为什么需要：开源版没有服务端，首次安装时本地缓存是空的 —— 不预置的话，
/// 用户打开消息页要干等一次联网抓取（几秒，还可能失败）。
///
/// 做法：把随包发布的快照（`assets/seed/app_seed.json`）写进本地缓存，
/// 之后走各 Service 正常的「先显示缓存 → 后台/下拉刷新」流程，
/// 刷新拿到的**新数据会照常覆盖**这些种子。
///
/// ⚠️ 缓存键与各 Service 的缓存键**完全一致**（改键要两边同步）。
/// ⚠️ 只在「缓存里没有内容」时才写；因此**缓存被清空（例如抓取失败写成空数组）时
///    会自动补回来**，这也是本类不能只依赖一个"已写入"标记位的原因。
class SeedData {
  SeedData._();

  static const String _kApplied = 'app_seed_applied_v1';
  static const String _asset = 'assets/seed/app_seed.json';

  // ---- 与各 Service 保持一致的缓存键 ----
  static const String _kNoticeList = 'school_notice_list_cache';
  static const String _kNoticeDetailPrefix = 'school_notice_detail_';
  static const String _kInfoListPrefix = 'campus_info_list_';
  static const String _kInfoDetailPrefix = 'campus_info_detail_';
  static const String _kSubscribed = 'notice_channel_subscribed_v1';

  /// 该键是否「没有可用内容」：不存在 / 空串 / 空数组都算没有。
  static bool _missing(SharedPreferences prefs, String key) {
    final v = prefs.getString(key);
    return v == null || v.isEmpty || v == '[]';
  }

  /// 写入内置内容。任何异常都静默 —— 不能让种子数据影响启动。
  static Future<void> ensureApplied() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // 已写过、且公告缓存还在 → 不用再读资源（省启动时间）。
      // 缓存被清空时会走到下面重新补齐。
      if (prefs.getBool(_kApplied) == true && !_missing(prefs, _kNoticeList)) {
        return;
      }

      final raw = await rootBundle.loadString(_asset);
      final j = jsonDecode(raw) as Map<String, dynamic>;

      // ① 教务处公告：列表 + 详情
      final notices = j['notices'];
      if (notices is List &&
          notices.isNotEmpty &&
          _missing(prefs, _kNoticeList)) {
        await prefs.setString(_kNoticeList, jsonEncode(notices));
      }
      final noticeDetails = j['notice_details'];
      if (noticeDetails is Map) {
        for (final e in noticeDetails.entries) {
          final key = '$_kNoticeDetailPrefix${e.key}';
          if (_missing(prefs, key)) {
            await prefs.setString(key, jsonEncode(e.value));
          }
        }
      }

      // ② 校园资讯：各栏目列表 + 详情
      final columns = j['columns'];
      final columnIds = <String>[];
      if (columns is Map) {
        for (final e in columns.entries) {
          final cid = e.key.toString();
          columnIds.add(cid);
          final key = '$_kInfoListPrefix$cid';
          if (_missing(prefs, key)) {
            await prefs.setString(key, jsonEncode(e.value));
          }
        }
      }
      final details = j['details'];
      if (details is Map) {
        for (final e in details.entries) {
          final key = '$_kInfoDetailPrefix${e.key}';
          if (_missing(prefs, key)) {
            await prefs.setString(key, jsonEncode(e.value));
          }
        }
      }

      // ③ 默认订阅内置的这几个栏目 —— 否则消息页首次打开只有「学校公告」一个页签。
      //    （客户端栏目目录里没有的 id 会被页面自动过滤掉，所以多写也无害。）
      final subscribed = prefs.getStringList(_kSubscribed);
      if ((subscribed == null || subscribed.isEmpty) &&
          columnIds.isNotEmpty) {
        await prefs.setStringList(_kSubscribed, columnIds);
      }

      await prefs.setBool(_kApplied, true);
    } catch (_) {
      // 种子缺失/损坏：静默跳过，用户仍可正常联网加载
    }
  }
}
