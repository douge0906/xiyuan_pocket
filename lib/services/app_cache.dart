import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

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
  static Future<int> sizeBytes() async {
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
  static Future<int> clear() async {
    var freed = 0;
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
    // 内存里的解码图不清掉的话，界面看起来「没变化」，用户会以为清理失败。
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    return freed;
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
