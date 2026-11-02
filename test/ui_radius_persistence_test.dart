import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/services/storage_service.dart';
import 'package:xiyuan_pocket/theme/app_theme.dart';

/// 回归：圆角缩放的「读回来」这条路（用户审批项 D1，2026-11-02）。
///
/// ## 为什么单测 AppTheme 不够
///
/// 只把 `AppTheme.defaultRadiusScale` 从 0.55 改成 1.0，对**老用户完全无效**：
/// 他们的手机上已经在 `SharedPreferences` 里存了 `ui_radius_scale = 0.55`
/// （`AppTheme` 的老默认值 + 2026-10-24 那次强制迁移的目标值），
/// `main.dart:177` 启动时照样把这个 0.55 读回来覆盖掉新默认值。
///
/// 这份测试锁的就是 `StorageService.loadUiRadiusScale()`：
/// 没有存盘值 → 新默认值；存的是老默认值 → 一次性迁移；真的自己调过 → 尊重。
void main() {
  const key = 'ui_radius_scale';

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('loadUiRadiusScale：没存过就用设计稿默认值', () {
    test('全新安装 → 返回 AppTheme.defaultRadiusScale（1.0），不是 0.55', () async {
      final v = await StorageService.loadUiRadiusScale();
      expect(v, AppTheme.defaultRadiusScale);
      expect(v, 1.0, reason: 'D1 要求恢复成设计稿大小；写死 0.55 就是没生效');
    });

    test('存了 0 → 当作没存过，返回默认值', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{key: 0.0});
      expect(await StorageService.loadUiRadiusScale(), AppTheme.defaultRadiusScale);
    });

    test('存了负数 → 当作没存过，返回默认值', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{key: -1.5});
      expect(await StorageService.loadUiRadiusScale(), AppTheme.defaultRadiusScale);
    });
  });

  group('loadUiRadiusScale：老默认值必须一次性迁移', () {
    test('🔴 存的是 0.55（旧默认）→ 迁到 1.0，并把磁盘上的值也改掉', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{key: 0.55});
      final v = await StorageService.loadUiRadiusScale();
      expect(v, 1.0, reason: '0.55 是旧默认值，留着它 D1 对老用户等于没做');

      // 不只是返回值对了，磁盘也必须被改掉 —— 否则每次启动都要再迁一次
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(key), 1.0);
      expect(prefs.getBool('ui_radius_default_migrated_design'), isTrue);
    });

    test('存的是 0.2（更早的旧默认）→ 直接迁到 1.0，不经中间态 0.55', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{key: 0.2});
      final v = await StorageService.loadUiRadiusScale();
      expect(v, 1.0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(key), 1.0);
    });

    test('迁移只做一次：迁完再读，用户后来主动改回 0.55 也要尊重', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{key: 0.55});
      expect(await StorageService.loadUiRadiusScale(), 1.0); // 第一次：迁移

      // 用户在设置页把滑杆拨回 0.55（模拟主动选择）
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(key, 0.55);

      // 第二次读：标记已在，不能再迁 —— 否则用户的主动选择会被反复吞掉
      expect(
        await StorageService.loadUiRadiusScale(),
        0.55,
        reason: '迁移标记存在时必须放行用户手选的值',
      );
    });
  });

  group('loadUiRadiusScale：真正手调过的值要尊重并夹到合法区间', () {
    test('存的是 0.8 → 原样返回', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{key: 0.8});
      expect(await StorageService.loadUiRadiusScale(), 0.8);
    });

    test('存的是 1.3 → 原样返回（区间内）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{key: 1.3});
      expect(await StorageService.loadUiRadiusScale(), 1.3);
    });

    test('存的是 5.0 → 夹到 maxRadiusScale', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{key: 5.0});
      final v = await StorageService.loadUiRadiusScale();
      expect(v, AppTheme.maxRadiusScale);
      expect(v, lessThanOrEqualTo(AppTheme.maxRadiusScale));
    });

    test('存的是 0.01 → 夹到 minRadiusScale，不会算出 0 或负圆角', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{key: 0.01});
      final v = await StorageService.loadUiRadiusScale();
      expect(v, AppTheme.minRadiusScale);
      expect(v, greaterThan(0));
    });
  });

  group('端到端：读回来之后 apply 到 AppTheme，圆角必须真的变大', () {
    tearDown(() => AppTheme.setRadiusScale(AppTheme.defaultRadiusScale));

    test('老用户（存 0.55）启动后 radiusLg 是 20，不是 11', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{key: 0.55});
      final scale = await StorageService.loadUiRadiusScale();
      AppTheme.setRadiusScale(scale);
      expect(
        AppTheme.radiusLg,
        20,
        reason: '修复前这里是 11 —— 这正是用户看到的「圆角偏小」',
      );
      expect(AppTheme.radiusMd, 14);
      expect(AppTheme.radiusSm, 12);
    });
  });
}
