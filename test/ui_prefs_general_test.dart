import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/pages/general_settings_page.dart';
import 'package:xiyuan_pocket/pages/settings_page.dart';
import 'package:xiyuan_pocket/services/app_locale.dart';
import 'package:xiyuan_pocket/services/ui_prefs.dart';

/// 设置页 IA（2026-11-03 v1.0.9 重排，同日按用户驳回意见二次收敛）。
///
/// 用户原话：「设置页怎么还是小字长篇大论，极简化」，以及
/// 「语言没有放到通用设置里，服务管理应该也并入外观与个性化」。
///
/// 最终结构：**首屏只剩四张卡，不写区块大标题**
///   1. 通知提醒 / 课程提醒 / 消息设置
///   2. 外观与个性化 / 通用设置（语言与服务管理分别收进这两个子页）
///   3. 清理缓存 / 清除所有数据与登录状态
///   4. 意见反馈 / 隐私政策 / 用户协议 / 联系投诉邮箱 / 检查更新
///
/// 这不是像素测试，锁的是三条容易回退的行为：
///   1. 首屏不得再出现「通知与提醒 / 界面与显示 / …」分区大字；
///   2. 语言是就地展开（在通用设置页里），不是跳页；同时只允许一个下拉展开；
///   3. 振动强度是单按钮循环档，点一下换一档并且写盘。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 每个用例从出厂状态起步，避免上一个用例的残留影响断言。
    UiPrefs.setTextScale(1.0);
    UiPrefs.setMotion(1.0);
    UiPrefs.setHapticLevel(2);
    UiPrefs.setFontFamily('');
    AppLocale.setLanguage(AppLanguage.zh);
  });

  group('字号步进器 -18+', () {
    test('标准档位就是 18 号', () {
      expect(UiPrefs.baseFontSize, 18);
      expect(UiPrefs.fontSizeNumber, 18);
    });

    test('加一号 = 缩放比 19/18，且字号数字跟着回到 19', () {
      UiPrefs.setFontSizeNumber(19);
      expect(UiPrefs.textScale, closeTo(19 / 18, 1e-9));
      expect(UiPrefs.fontSizeNumber, 19);
    });

    test('上下限夹在 14~24 号，不会越界', () {
      UiPrefs.setFontSizeNumber(99);
      expect(UiPrefs.fontSizeNumber, lessThanOrEqualTo(23));
      UiPrefs.setFontSizeNumber(-99);
      expect(UiPrefs.fontSizeNumber, greaterThanOrEqualTo(14));
    });

    test('全局生效：textScaler 跟着变', () {
      UiPrefs.setFontSizeNumber(20);
      final scaler = UiPrefs.textScaler;
      expect(scaler.scale(10), closeTo(10 * UiPrefs.textScale, 1e-6));
    });
  });

  group('振动强度四档（原「动效强度」）', () {
    test('四档标签固定为 关闭/轻/强/极强', () {
      expect(UiPrefs.hapticChoices, ['关闭', '轻', '强', '极强']);
    });

    test('cycleHapticLevel 从当前档转下一档并回绕', () {
      UiPrefs.setHapticLevel(0);
      expect(UiPrefs.cycleHapticLevel(), 1);
      expect(UiPrefs.cycleHapticLevel(), 2);
      expect(UiPrefs.cycleHapticLevel(), 3);
      expect(UiPrefs.cycleHapticLevel(), 0, reason: '极强之后回到关闭');
    });

    test('haptics 开关等价于「档位 > 0」', () {
      UiPrefs.setHapticLevel(0);
      expect(UiPrefs.haptics, isFalse);
      UiPrefs.setHapticLevel(1);
      expect(UiPrefs.haptics, isTrue);
    });

    test('hapticLabel 与档位一一对应', () {
      for (var i = 0; i < 4; i++) {
        UiPrefs.setHapticLevel(i);
        expect(UiPrefs.hapticLabel, UiPrefs.hapticChoices[i]);
      }
    });
  });

  group('字体族', () {
    test('默认是空串（跟随系统）', () {
      expect(UiPrefs.fontFamily, '');
    });

    test('切换后立即生效并通知重建', () {
      final before = UiPrefs.notifier.value;
      UiPrefs.setFontFamily('serif');
      expect(UiPrefs.fontFamily, 'serif');
      expect(UiPrefs.notifier.value, greaterThan(before));
    });

    test('三个候选项的族名与显示名都不为空', () {
      expect(UiPrefs.fontChoices.length, 3);
      for (final f in UiPrefs.fontChoices) {
        expect(f.$2, isNotEmpty);
      }
      expect(UiPrefs.fontChoices.first.$1, '');
    });
  });

  group('设置首屏：四块 IA', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SettingsPage(
          onLogout: () async {},
          themeMode: ThemeMode.light,
          onThemeChanged: (_) async {},
          primaryColor: ValueNotifier(Colors.black),
          onPrimaryChanged: (_) async {},
        ),
      ));
      await tester.pump();
    }

    testWidgets('首屏按 通用 / 功能 / 帮助与反馈 三个分区', (tester) async {
      await pumpSettings(tester);
      // 🔴 2026-11-03 用户口径第三次更正（原话）：
      // 「你是脑残吗？ 我让你简化的注释是通知消息里面的大量小字，
      //   我的分类小字怎么没有了 你现在按照 通用 功能 帮助与反馈
      //   直接划分设置页」
      //
      // 所以：分区标题**必须在**（上一版一起删掉是误读），要简化的是
      // 「通知消息页里的注释小字」，不是设置页的分类。
      expect(find.text('通用'), findsOneWidget);
      expect(find.text('功能'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('检查更新'), 240,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('检查更新'), findsOneWidget);
      expect(find.text('帮助与反馈'), findsOneWidget);

      // 三个分区各自的入口都在。
      expect(find.text('通知提醒'), findsOneWidget);
      expect(find.text('外观与个性化'), findsOneWidget);
      expect(find.text('清理缓存'), findsOneWidget);

      // 旧的四个分区名一律不再出现（已被三块划分取代）。
      expect(find.text('界面与显示'), findsNothing);
      expect(find.text('数据与存储'), findsNothing);
      expect(find.text('帮助与关于'), findsNothing);
    });

    testWidgets('「界面与显示」卡只剩 外观与个性化 / 通用设置 两个入口', (tester) async {
      await pumpSettings(tester);
      // 语言已搬进「通用设置」，服务管理已搬进「外观与个性化」。
      expect(find.text('外观与个性化'), findsOneWidget);
      expect(find.text('通用设置'), findsOneWidget);
      expect(find.text('语言'), findsNothing,
          reason: '语言现在在「通用设置」页里');
      expect(find.text('服务管理'), findsNothing,
          reason: '服务管理现在在「外观与个性化」页里');
    });

    testWidgets('字体/字号/振动强度不再出现在首屏（已收进通用设置）', (tester) async {
      await pumpSettings(tester);
      expect(find.text('字体设置'), findsNothing);
      expect(find.text('字号'), findsNothing);
      expect(find.text('振动强度'), findsNothing);
      expect(find.text('动效强度'), findsNothing, reason: '旧名必须彻底消失');
    });

    testWidgets('语言在通用设置里就地下拉（不跳页），出现 English',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: GeneralSettingsPage()));
      await tester.pump();
      expect(find.text('English'), findsNothing);

      await tester.tap(find.text('语言'));
      await tester.pumpAndSettle();
      expect(find.text('English'), findsOneWidget);
      expect(find.text('中文'), findsWidgets);
      // 还在通用设置页 —— 没有 push 新页面。
      expect(find.text('字体'), findsOneWidget);

      // 选中即收：下拉列表收起来后，未选中项「中文」必须消失，
      // 行右侧的当前值变成「English」（这是正常的，不是残留）。
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      expect(find.text('中文'), findsNothing, reason: '选中后下拉应自动收起');
      expect(AppLocale.current, AppLanguage.en);
      // 🔴 这一条同时证明「语言切换真的全局生效」：同一页的中文标签
      // 立刻变成英文（此前只有 MaterialApp 重建、`home` 是 const，全 App 不变）。
      expect(find.text('Font'), findsOneWidget, reason: '仍在通用设置页，且已切成英文');
      expect(find.text('字体'), findsNothing);
    });

    testWidgets('页面不抛异常（回归：曾因 containsKey 漏 .id 整页空白）',
        (tester) async {
      await pumpSettings(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('通用设置页：三行容器', () {
    Future<void> pumpGeneral(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: GeneralSettingsPage()));
      await tester.pump();
    }

    testWidgets('三行齐全：字体 / 字号 / 振动强度', (tester) async {
      await pumpGeneral(tester);
      expect(find.text('字体'), findsOneWidget);
      expect(find.text('字号'), findsOneWidget);
      expect(find.text('振动强度'), findsOneWidget);
    });

    testWidgets('字号默认 18，点 + 变 19 并落库', (tester) async {
      await pumpGeneral(tester);
      expect(find.text('18'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();
      expect(find.text('19'), findsOneWidget);
      expect(UiPrefs.fontSizeNumber, 19);
    });

    testWidgets('振动强度是单按钮：点一下换一档', (tester) async {
      UiPrefs.setHapticLevel(0);
      await pumpGeneral(tester);
      expect(find.text('关闭'), findsOneWidget);

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(UiPrefs.hapticLevel, 1);
      expect(find.text('轻'), findsWidgets);
    });

    testWidgets('字体点开后才出现候选项，选中即收', (tester) async {
      await pumpGeneral(tester);
      expect(find.text('衬线（宋体）'), findsNothing);

      await tester.tap(find.text('字体'));
      await tester.pumpAndSettle();
      expect(find.text('衬线（宋体）'), findsOneWidget);
      expect(find.text('等宽'), findsOneWidget);

      await tester.tap(find.text('等宽'));
      await tester.pumpAndSettle();
      expect(UiPrefs.fontFamily, 'monospace');
      expect(find.text('衬线（宋体）'), findsNothing, reason: '选中后应当自动收起');
    });
  });
}
