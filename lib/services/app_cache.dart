import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 缓存统计与清理（2026-11-03）。
///
/// 为什么需要它：设置页原来只有一个**核弹级**的「清除本机数据」——
/// 一点就把账号、课表、待办全清掉还得重新登录。用户只想腾点时根本没有中间档。
///
/// 边界（很重要，别搞错）：
/// * **清缓存只动 `getApplicationCacheDirectory()`**（系统随时可以回收的那一层），
///   以及 Flutter 的内存图片缓存。
/// * **绝不动 `getApplicationDocumentsDirectory()`** —— 那里是用户主动下载的
///   资源文件（教材 / 试卷 PDF）和自定义课表背景图，删了等于删用户的资料。
/// * `SharedPreferences` / 安全存储也不动，那是「清除本机数据」的职责。
class AppCache {
  AppCache._();

  /// 缓存占用字节数（目录不存在或读取失败时返回 0）。
  ///
  /// Web 端没有「缓存目录」这个概念（`path_provider` 在 Web 上不可用），
  /// 改统计浏览器本地缓存条目（`SharedPreferences` 里名字含 `cache` 的键）。
  static Future<int> sizeBytes() async {
    if (kIsWeb) return _webCacheSize();
    try {
      final root = await getApplicationCacheDirectory();
      return await _du(root);
    } catch (_) {
      return 0;
    }
  }

  /// 清空缓存目录内容 + 内存图片缓存。返回**释放的字节数**。
  ///
  /// 删不掉的文件（被占用）跳过，不抛异常 —— 清理失败不该阻断页面。
  ///
  /// Web 端：清浏览器本地缓存条目（只清名字含 `cache` 的键，
  /// 账号 / 课表 / 用户配置一律不动），同样清内存图片缓存。
  static Future<int> clear() async {
    var freed = 0;
    if (kIsWeb) {
      freed = await _webCacheClear();
    } else {
      try {
        final root = await getApplicationCacheDirectory();
        freed = await _du(root);
        if (await root.exists()) {
          await for (final entity in root.list(followLinks: false)) {
            try {
              if (entity is File) {
                await entity.delete();
              } else if (entity is Directory) {
                await entity.delete(recursive: true);
              }
            } catch (_) {
              // 单个文件删不掉就算了，继续清别的
            }
          }
        }
      } catch (_) {
        // 目录拿不到就只清内存缓存
      }
    }
    // 内存里的解码图不清掉的话，界面看起来「没变化」，用户会以为清理失败。
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    return freed;
  }

  /// Web 端：缓存键名单。只清这些，账号 / 课表 / 用户配置都不碰。
  static const List<String> _webCacheKeys = <String>[
    'card_balance_cache_v1',
    'card_balance_cache_v2',
    'card_txn_cache_v1',
    'elec_balance_cache_v1',
    'exam_cache_list',
    'exam_cache_semester',
    'exam_cache_updated_at',
    'grade_cache_v1',
    'resource_center_cache_v1',
    'resource_center_cache_at_v1',
    'school_notice_list_cache',
    'textbook_cache_list',
    'textbook_cache_semester',
    'textbook_cache_updated_at',
  ];

  /// Web 端：统计本地缓存条目占用的字节数（近似值）。
  static Future<int> _webCacheSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var total = 0;
      for (final key in _webCacheKeys) {
        total += _webValueBytes(prefs, key);
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Web 端：删除本地缓存条目，返回释放的字节数（近似值）。
  static Future<int> _webCacheClear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var freed = 0;
      for (final key in _webCacheKeys) {
        final bytes = _webValueBytes(prefs, key);
        await prefs.remove(key);
        freed += bytes;
      }
      await prefs.reload();
      return freed;
    } catch (_) {
      return 0;
    }
  }

  /// 单个缓存键的近似字节数（键名 + 值的 UTF-8 长度）。
  static int _webValueBytes(SharedPreferences prefs, String key) {
    try {
      if (!prefs.containsKey(key)) return 0;
      final value = prefs.get(key);
      final text = value is String ? value : (value?.toString() ?? '');
      return key.length + text.length;
    } catch (_) {
      return 0;
    }
  }

  /// 把字节数格式化成「12.3 MB」这种人话。
  static String format(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final text = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
    return '$text ${units[unit]}';
  }

  static Future<int> _du(Directory dir) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }
}
