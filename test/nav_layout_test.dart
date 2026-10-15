import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/services/nav_prefs.dart';

/// 底部导航自定义（v1.7.0）回归测试。
///
/// 这里钉住三件容易在后续改动里被破坏的事：
///  ① 顺序 / 显隐解析必须**容错** —— 老数据、手改过的数据、以后新增页面都不能崩；
///  ② 用户页**永远显示且永远排最后**（用户要求：除用户页外才可隐藏 / 排序）；
///  ③ 存了再读回来必须一模一样（否则用户改完顺序重启就复原了）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NavLayout.visible', () {
    test('出厂布局 = 首页 / 消息 / 课表 / 服务 / 用户', () {
      expect(NavLayout.initial.visible, [
        NavPage.home,
        NavPage.message,
        NavPage.course,
        NavPage.service,
        NavPage.user,
      ]);
    });

    test('隐藏一项后它不再出现，但用户页仍在最后', () {
      final l = NavLayout(
        order: NavLayout.initial.order,
        hidden: {NavPage.message},
      );
      expect(l.visible, [
        NavPage.home,
        NavPage.course,
        NavPage.service,
        NavPage.user,
      ]);
      expect(l.isVisible(NavPage.message), isFalse);
      expect(l.isVisible(kPinnedNavPage), isTrue);
    });

    test('调顺序只影响自定义页，用户页照样在最后', () {
      final l = NavLayout(
        order: [NavPage.service, NavPage.course, NavPage.home, NavPage.message],
        hidden: const {},
      );
      expect(l.visible.last, NavPage.user);
      expect(l.visible.take(4), [
        NavPage.service,
        NavPage.course,
        NavPage.home,
        NavPage.message,
      ]);
    });

    test('全部自定义页都隐藏时，只剩用户页（不崩、不空白）', () {
      final l = NavLayout(
        order: NavLayout.initial.order,
        hidden: kCustomizableNavPages.toSet(),
      );
      expect(l.visible, [NavPage.user]);
    });
  });

  group('NavLayout.fromJson 容错', () {
    test('空 JSON → 出厂布局', () {
      expect(NavLayout.fromJson(const {}).visible, NavLayout.initial.visible);
    });

    test('未知 id 丢弃、重复项去重', () {
      final l = NavLayout.fromJson(const {
        'order': ['home', '乱码', 'course', 'home', 'course'],
      });
      expect(l.order.take(2), [NavPage.home, NavPage.course]);
      // 去重后不会出现两遍
      expect(l.order.toSet().length, l.order.length);
    });

    test('老数据缺项 → 按默认顺序补到末尾（新功能不会凭空消失）', () {
      final l = NavLayout.fromJson(const {
        'order': ['message', 'home'],
      });
      // 自定义页一个都不能少
      expect(l.order.toSet(), kCustomizableNavPages.toSet());
      // 原有顺序保持在前
      expect(l.order.take(2), [NavPage.message, NavPage.home]);
    });

    test('order / hidden 里出现用户页 → 直接忽略（它不可调）', () {
      final l = NavLayout.fromJson(const {
        'order': ['user', 'home'],
        'hidden': ['user', 'service'],
      });
      expect(l.order.contains(kPinnedNavPage), isFalse);
      expect(l.hidden.contains(kPinnedNavPage), isFalse);
      expect(l.hidden, {NavPage.service});
      expect(l.visible.last, NavPage.user);
    });

    test('字段类型不对（不是 List）也不崩', () {
      final l = NavLayout.fromJson(const {'order': 123, 'hidden': 'oops'});
      expect(l.visible, NavLayout.initial.visible);
    });

    test('存了再读回来一致（否则改完重启就复原）', () {
      final src = NavLayout(
        order: [NavPage.course, NavPage.home, NavPage.message, NavPage.service],
        hidden: {NavPage.home, NavPage.message},
      );
      final back = NavLayout.fromJson(src.toJson());
      expect(back.order, src.order);
      expect(back.hidden, src.hidden);
      expect(back.visible, src.visible);
    });
  });

  group('初始页面（v1.7.1：进 App 落在排第一的那页）', () {
    test('导航没动过 → 还是首页（老行为完全不变）', () {
      expect(NavLayout.initial.visible.first, NavPage.home);
    });

    test('把课表拖到第一位 → 进 App 直接落在课表', () {
      final l = NavLayout(
        order: [NavPage.course, NavPage.home, NavPage.message, NavPage.service],
        hidden: const {},
      );
      expect(l.visible.first, NavPage.course);
    });

    test('首页被隐藏 → 落在剩下排第一的那页（不停在空白页上）', () {
      final l = NavLayout(
        order: NavLayout.initial.order,
        hidden: {NavPage.home},
      );
      expect(l.visible.first, NavPage.message);
    });
  });

  group('NavPrefs（读写 + 通知）', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await NavPrefs.reset();
    });

    test('默认全显示', () {
      expect(NavPrefs.visible.length, NavPage.values.length);
    });

    test('隐藏后 visible 立刻少一项，并写进磁盘（换一次读取仍在）', () async {
      await NavPrefs.setHidden(NavPage.service, true);
      expect(NavPrefs.visible.contains(NavPage.service), isFalse);
      // 模拟重启：清掉内存布局后再读一次
      NavPrefs.notifier.value = NavLayout.initial;
      await NavPrefs.ensureLoaded();
      expect(NavPrefs.visible.contains(NavPage.service), isFalse);
    });

    test('用户页设不隐藏（调用被忽略）', () async {
      await NavPrefs.setHidden(kPinnedNavPage, true);
      expect(NavPrefs.visible.contains(kPinnedNavPage), isTrue);
      expect(NavPrefs.visible.last, kPinnedNavPage);
    });

    test('排序会通知监听者（导航条靠它即时重建）', () async {
      var notified = 0;
      void listener() => notified++;
      NavPrefs.notifier.addListener(listener);
      await NavPrefs.setOrder([
        NavPage.course,
        NavPage.home,
        NavPage.message,
        NavPage.service,
      ]);
      NavPrefs.notifier.removeListener(listener);
      expect(notified, greaterThan(0));
      expect(NavPrefs.visible.first, NavPage.course);
      expect(NavPrefs.visible.last, NavPage.user);
    });

    test('initialPage 始终等于用户排第一的那页', () async {
      expect(NavPrefs.initialPage, NavPage.home); // 出厂布局
      await NavPrefs.setOrder([
        NavPage.service,
        NavPage.home,
        NavPage.message,
        NavPage.course,
      ]);
      expect(NavPrefs.initialPage, NavPage.service);
      // 把排第一那页藏掉 → 落点顺延给下一个
      await NavPrefs.setHidden(NavPage.service, true);
      expect(NavPrefs.initialPage, NavPage.home);
      await NavPrefs.setHidden(NavPage.home, true);
      expect(NavPrefs.initialPage, NavPage.message);
    });

    test('损坏的存储内容 → 回落出厂布局，不抛异常', () async {
      SharedPreferences.setMockInitialValues(
          <String, Object>{'nav_layout_v1': '{{{ 不是 json'});
      await NavPrefs.ensureLoaded();
      expect(NavPrefs.visible, NavLayout.initial.visible);
    });
  });
}
