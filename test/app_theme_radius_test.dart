import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/theme/app_theme.dart';

/// 回归：圆角三档必须等于设计稿原值（用户审批项 D1，2026-11-02）。
///
/// ## 背景
///
/// `AppTheme` 把三档圆角做成了「基准值 × 全局缩放系数」：
///
/// ```dart
/// static double radiusSmRaw = 12;
/// static double radiusMdRaw = 14;
/// static double radiusLgRaw = 20;
/// static double get radiusMd => (radiusMdRaw * _radiusScale).roundToDouble();
/// ```
///
/// 2026-10-24 曾把 `defaultRadiusScale` 改成 `0.55`（「最小」——视觉上趋近直角），
/// 于是 `radiusLg` 实际是 **11** 而不是 20。
///
/// **2026-11-02 用户审批 D1：恢复成设计稿大小**，`defaultRadiusScale = 1.0`。
///
/// ## 为什么值得写测试
///
/// 这个值改一个数字，全 App 每个卡片、按钮、输入框的圆角同时变。
/// 它不会报错、不会崩、现有测试一条都发现不了（原先没有任何测试提到 radius）。
/// 一旦有人「顺手调一下手感」，整个 App 的视觉就漂了，而且没人会记得原来是多少。
void main() {
  group('defaultRadiusScale：默认必须等于设计稿（1.0）', () {
    test('D1 审批后默认值为 1.0', () {
      expect(
        AppTheme.defaultRadiusScale,
        1.0,
        reason: '用户 2026-11-02 审批 D1「圆角恢复成设计稿大小」，'
            '默认缩放必须是 1.0（曾是 0.55）',
      );
    });

    test('三档圆角在默认缩放下等于基准值 12 / 14 / 20', () {
      // 注意：radiusSm/Md/Lg 是读 _radiusScale 的 getter。
      // 这里断言的是「默认态」；调过滑杆的用户以存盘值为准。
      expect(AppTheme.radiusScale, AppTheme.defaultRadiusScale,
          reason: '测试进程内没有人调过 setRadiusScale');
      expect(AppTheme.radiusSm, 12);
      expect(AppTheme.radiusMd, 14);
      expect(AppTheme.radiusLg, 20);
    });

    test('三档必须严格递增（小控件 < 卡片 < 大容器）', () {
      expect(AppTheme.radiusSm < AppTheme.radiusMd, isTrue);
      expect(AppTheme.radiusMd < AppTheme.radiusLg, isTrue);
    });

    test('缩放系数的可调范围必须包住 1.0', () {
      expect(AppTheme.minRadiusScale, lessThan(1.0));
      expect(AppTheme.maxRadiusScale, greaterThan(1.0));
    });
  });

  group('setRadiusScale：缩放必须真的生效，且被夹在范围内', () {
    tearDown(() {
      // 每个用例后复位，避免污染其它测试
      AppTheme.setRadiusScale(AppTheme.defaultRadiusScale);
    });

    test('缩放到 0.5 时三档同时减半（取整）', () {
      AppTheme.setRadiusScale(0.5);
      expect(AppTheme.radiusSm, 6); //  12 * 0.5 = 6
      expect(AppTheme.radiusMd, 7); //  14 * 0.5 = 7
      expect(AppTheme.radiusLg, 10); // 20 * 0.5 = 10
    });

    test('缩放到 1.0 时回到 12 / 14 / 20', () {
      AppTheme.setRadiusScale(0.3);
      AppTheme.setRadiusScale(1.0);
      expect(AppTheme.radiusSm, 12);
      expect(AppTheme.radiusMd, 14);
      expect(AppTheme.radiusLg, 20);
    });

    test('超出上限会被夹到 maxRadiusScale，不会算出荒谬的圆角', () {
      AppTheme.setRadiusScale(99);
      expect(AppTheme.radiusScale, AppTheme.maxRadiusScale);
    });

    test('低于下限会被夹到 minRadiusScale', () {
      AppTheme.setRadiusScale(0.0001);
      expect(AppTheme.radiusScale, AppTheme.minRadiusScale);
    });

    test('改动会通知 radiusNotifier（整树重建靠它）', () {
      var fired = 0;
      void listener() => fired++;
      AppTheme.radiusNotifier.addListener(listener);
      AppTheme.setRadiusScale(0.8);
      AppTheme.radiusNotifier.removeListener(listener);
      expect(fired, 1, reason: '调滑杆必须触发一次重建，否则界面不会变');
    });

    test('设成相同值不应重复通知（避免无意义重建）', () {
      AppTheme.setRadiusScale(1.0);
      var fired = 0;
      void listener() => fired++;
      AppTheme.radiusNotifier.addListener(listener);
      AppTheme.setRadiusScale(1.0); // 相同值
      AppTheme.radiusNotifier.removeListener(listener);
      expect(fired, 0, reason: '同值 guard：|v - _radiusScale| < 0.001 时直接 return');
    });
  });
}
