import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/control_config.dart';
import '../theme/app_theme.dart';
import 'control_service.dart';

/// 控制台版本更新提示。
///
/// 只做三件事：
/// 1. 公共接口查最新版本，不要求登录；
/// 2. 与本地版本比较，新版本才提示；
/// 3. 下载地址必须在白名单域名内，用系统浏览器打开。
class AppUpdateService {
  AppUpdateService._();

  static const String _kPromptedVersion = 'app_update_prompted_version_v1';

  static Future<void> checkAndPrompt(BuildContext context) async {
    if (!Platform.isAndroid) return;
    final release = await ControlService.fetchAppRelease();
    if (release == null) return;

    final latest = (release['latestVersion'] ?? '').toString().trim();
    if (latest.isEmpty) return;

    final info = await PackageInfo.fromPlatform();
    if (_compare(latest, info.version) <= 0) return;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_kPromptedVersion) == latest) return;

    final url = (release['downloadUrl'] ?? '').toString().trim();
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return;
    if (uri.scheme != 'https' && uri.scheme != 'http') return;
    if (!ControlConfig.updateDownloadHosts.contains(uri.host)) return;
    if (!context.mounted) return;

    final notes = (release['notes'] ?? '').toString().trim();
    // 🔴 「本版本已提示过」必须在弹窗**真正展示之后**才落盘。
    //    写在 showDialog 之前时，只要弹窗前进程被杀或 context 已卸载，
    //    这一版就永远不会再提示（用户彻底收不到更新）。
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 v$latest'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              notes.isEmpty ? '新版本已准备好，建议连接 WiFi 后更新。' : notes,
              style: const TextStyle(fontSize: AppTheme.fontSmall, height: 1.6),
            ),
            const SizedBox(height: 10),
            Text(
              '当前版本 ${info.version}',
              style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('稍后'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.of(ctx).pop();
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            },
            child: const Text('去下载'),
          ),
        ],
      ),
    );
    // 弹窗已真正展示（用户点了「稍后」/「去下载」或返回键关闭）→ 记为已提示。
    await prefs.setString(_kPromptedVersion, latest);
  }

  /// 「检查更新」—— 用户**手动**点版本号时调用（2026-11-03）。
  ///
  /// 与 [checkAndPrompt] 的区别：
  ///   - [checkAndPrompt] 是启动时自动跑，受「每版本只提示一次」约束
  ///     （`_kPromptedVersion`），提示过一次这个版本就不再弹；
  ///   - 本方法是**用户主动点**，必须**无视那个约束** —— 否则用户点完没反应
  ///     会以为功能坏了，这正是「版本号是死点击区」修完最容易犯的新错。
  ///
  /// 三种结果都必须给反馈：有新版本（弹窗）/ 已是最新（提示）/ 查不到
  /// （提示网络问题），不能静默返回。
  static Future<void> checkManually(BuildContext context) async {
    if (!Platform.isAndroid) {
      _toast(context, '当前平台不支持检查更新');
      return;
    }
    final release = await ControlService.fetchAppRelease();
    if (!context.mounted) return;
    if (release == null) {
      _toast(context, '无法获取版本信息，请检查网络后重试');
      return;
    }

    final latest = (release['latestVersion'] ?? '').toString().trim();
    final info = await PackageInfo.fromPlatform();
    if (!context.mounted) return;
    if (latest.isEmpty) {
      _toast(context, '无法获取版本信息，请稍后重试');
      return;
    }
    if (_compare(latest, info.version) <= 0) {
      _toast(context, '已是最新版本 v${info.version}');
      return;
    }

    final url = (release['downloadUrl'] ?? '').toString().trim();
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      _toast(context, '新版本 v$latest 已发布，但下载地址无效');
      return;
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      _toast(context, '新版本 v$latest 已发布，但下载地址不安全');
      return;
    }
    if (!ControlConfig.updateDownloadHosts.contains(uri.host)) {
      _toast(context, '新版本 v$latest 已发布，但下载地址不在白名单内');
      return;
    }

    final notes = (release['notes'] ?? '').toString().trim();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 v$latest'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              notes.isEmpty ? '新版本已准备好，建议连接 WiFi 后更新。' : notes,
              style: const TextStyle(fontSize: AppTheme.fontSmall, height: 1.6),
            ),
            const SizedBox(height: 10),
            Text(
              '当前版本 ${info.version}',
              style: TextStyle(fontSize: AppTheme.fontSmall, color: context.textTertiary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('稍后'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.of(ctx).pop();
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            },
            child: const Text('去下载'),
          ),
        ],
      ),
    );
    // 手动检查也记一次，避免下次启动又弹一遍同一版本。
    await SharedPreferences.getInstance()
        .then((p) => p.setString(_kPromptedVersion, latest));
  }

  static void _toast(BuildContext context, String msg) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  static int _compare(String a, String b) {
    int seg(String s) {
      // 容忍 `v1.0.9` / `V1.0.9` 这类带前缀的写法：原来的正则直接把整段
      // 判成 0，`_compare('v1.0.9','1.0.8')` 会得 -1（把新版本当旧版本，
      // 静默不提示）。控制台现在返回不带前缀的「1.0.8」，一旦改成
      // 「v1.0.9」就会永久失效。
      final cleaned = s.trim().replaceFirst(RegExp(r'^[vV]'), '');
      final m = RegExp(r'^\d+').firstMatch(cleaned);
      return m == null ? 0 : int.parse(m.group(0)!);
    }

    final pa = a.split('.').map(seg).toList();
    final pb = b.split('.').map(seg).toList();
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) return va - vb;
    }
    // 数字段完全相等时，带 `-beta` / `-rc1` 这类后缀的是预发布版，比正式版旧。
    // 不做这一步的话 `_compare('1.0.9-beta','1.0.9')` 得 0，预发布包与正式包
    // 被判成同一版本，既有用户收不到正式版提示。
    final preA = a.contains('-');
    final preB = b.contains('-');
    if (preA != preB) return preA ? -1 : 1;
    return 0;
  }
}
