import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/constants/control_config.dart';

/// 回归：更新下载白名单必须包含 APK 的**真实**托管域名。
///
/// ## 这个 bug 长什么样（2026-11-02 审批项 A1）
///
/// `ControlConfig.updateDownloadHosts` 原本只有
/// `con` / `api` / `down` 三个域名，但安装包实际放在
/// `static.wxxydouge.icu`（EdgeOne CDN，回源到 `api.wxxydouge.icu/static/`）。
///
/// 于是 `AppUpdateService.checkAndPrompt()` 走到第 41 行：
///
/// ```dart
/// if (!ControlConfig.updateDownloadHosts.contains(uri.host)) return;
/// ```
///
/// 就**静默 return** —— 不弹窗、不报错、不写日志。
/// 用户永远收不到更新提示，而开发者以为「更新功能已经做好了」。
///
/// ## 为什么要写这份测试
///
/// 白名单这一块**原本一条测试都没有**。它失效的方式是「什么都不发生」，
/// 比崩溃更难发现 —— 崩溃至少有堆栈，静默失败只有用户抱怨「怎么不提示更新」。
///
/// 这里既锁「必须包含 CDN 域名」这个事实，也锁白名单的**语义边界**
/// （只认这些域名，不能因为修 A1 就把白名单变成「什么都放行」）。
void main() {
  group('updateDownloadHosts：白名单必须覆盖真实下载域名', () {
    test('必须包含 CDN 域名 static.wxxydouge.icu（A1 的核心断言）', () {
      expect(
        ControlConfig.updateDownloadHosts.contains('static.wxxydouge.icu'),
        isTrue,
        reason: '真实 APK 在 static.wxxydouge.icu 上托管；不在这份名单里，'
            'AppUpdateService 会静默拒绝跳转，更新提示永不出现',
      );
    });

    test('kCdnHost 常量本身必须是 CDN 域名', () {
      expect(ControlConfig.kCdnHost, 'static.wxxydouge.icu');
    });

    test('白名单必须包含 kCdnHost（避免两边各写一遍字符串后漂移）', () {
      expect(
        ControlConfig.updateDownloadHosts.contains(ControlConfig.kCdnHost),
        isTrue,
      );
    });

    test('原有的三个域名不能被顺手删掉', () {
      // 修 A1 时最容易犯的错：把白名单换成只有一个 static。
      for (final host in const [
        'con.wxxydouge.icu',
        'api.wxxydouge.icu',
        'down.wxxydouge.icu',
      ]) {
        expect(
          ControlConfig.updateDownloadHosts.contains(host),
          isTrue,
          reason: '$host 原本就在白名单里，删掉会让对应的合法下载地址失效',
        );
      }
    });

    test('白名单只放行自家域名，不能变成「什么都信」', () {
      // 修一个「太严」的 bug 时，最容易引入「太松」的新 bug。
      const strangers = [
        'example.com',
        'evil.com',
        'wxxydouge.icu.evil.com', // 后缀欺骗
        'static.wxxydouge.icu.evil.com', // 前缀欺骗
        'github.com',
        '',
      ];
      for (final host in strangers) {
        expect(
          ControlConfig.updateDownloadHosts.contains(host),
          isFalse,
          reason: '$host 不是自家域名，放进来等于把「任意 APK 都能推」的口子开了',
        );
      }
    });

    test('白名单数量必须精确，新增域名要有意识而不是顺手加', () {
      expect(
        ControlConfig.updateDownloadHosts.length,
        4,
        reason: '当前应为 con / api / down / static 四个。'
            '数量变化说明有人改了白名单 —— 请确认是有意为之',
      );
    });

    test('白名单里每个域名都是非空、不含协议、不含路径的裸 host', () {
      for (final host in ControlConfig.updateDownloadHosts) {
        expect(host.isNotEmpty, isTrue);
        expect(host.contains('://'), isFalse, reason: '$host 混进了协议头');
        expect(host.contains('/'), isFalse, reason: '$host 混进了路径');
        expect(host, host.toLowerCase(), reason: '$host 必须小写');
      }
    });
  });

  group('ControlConfig：控制端开关语义', () {
    test('baseUrl 非空时 enabled 必须为 true', () {
      expect(ControlConfig.baseUrl.isNotEmpty, isTrue);
      expect(ControlConfig.enabled, isTrue);
    });

    test('baseUrl 必须是 https（明文 http 下设备签名会被中间人重放）', () {
      expect(ControlConfig.baseUrl.startsWith('https://'), isTrue);
    });

    test('接口路径全以 / 开头', () {
      final paths = <String>[
        ControlConfig.pathDeviceRegister,
        ControlConfig.pathChallenges,
        ControlConfig.pathAssertions,
        ControlConfig.pathRefresh,
        ControlConfig.pathRevoke,
        ControlConfig.pathConfigVersions,
        ControlConfig.pathAppRelease,
        ControlConfig.pathMessages,
        ControlConfig.pathSchoolCalendar,
        ControlConfig.pathExamPapers,
        ControlConfig.pathResources,
        ControlConfig.pathResourceUploads,
        ControlConfig.pathFeedback,
        ControlConfig.pathHealth,
      ];
      for (final p in paths) {
        expect(p.startsWith('/'), isTrue, reason: '$p 缺少前导斜杠');
      }
      // 顺带锁一条：更新与健康检查的路径必须真实存在（改路径要同步服务端）
      expect(ControlConfig.pathAppRelease, '/api/v1/app/release');
      expect(ControlConfig.pathHealth, '/healthz');
    });
  });
}
