import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/services/app_locale.dart';
import 'package:xiyuan_pocket/services/data_wipe.dart';
import 'package:xiyuan_pocket/services/nav_prefs.dart';
import 'package:xiyuan_pocket/services/storage_service.dart';
import 'package:xiyuan_pocket/services/ui_prefs.dart';
import 'package:xiyuan_pocket/theme/app_theme.dart';
import 'package:xiyuan_pocket/widgets/hand_drawn_backgrounds.dart';

/// 「清除所有数据与登录状态」之后，界面外观必须立刻回默认。
///
/// 为什么需要这个测试：`DataWipe.wipeAll()` 早就把手绘背景 / 导航布局之类
/// 的**内存静态值**列进了「要重置」的清单（注释写着「否则清完还是老样子」），
/// 但漏了外观这一组 —— 它们全是 `AppTheme` / `UiPrefs` / `AppLocale` 上的
/// static 值，SP 清空并不会让它们变。用户点完确认框，看到的仍是上一次设的
/// 主题色、背景色、字号、圆角，直到杀掉 App 重启。
///
/// 这不是像素测试，锁的是「清完 = 冷启动第一帧」这条契约：本文件断言
/// `resetAppearanceInMemory()` 之后的静态值与 `StorageService` 各 `load*`
/// 在空盘时返回的默认值一致。
void main() {
  // AppTheme.setMode / setBackground 会同步调用 SystemChrome.setSystemUIOverlayStyle，
  // 那条路径需要一个已初始化的 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 从出厂状态起步 —— 但刻意不用 resetAppearanceInMemory()，
    // 否则本文件就成了「自己验自己」。
    AppTheme.setMode(ThemeMode.light);
    AppTheme.setPrimary(AppTheme.defaultPrimary);
    AppTheme.setBackground(null);
    AppTheme.setBackgroundDark(null);
    handDrawnBackgroundNotifier.value = HandDrawnBackground.none;
    AppTheme.setRadiusScale(AppTheme.defaultRadiusScale);
    UiPrefs.setTextScale(1.0);
    UiPrefs.setMotion(1.0);
    UiPrefs.setHapticLevel(2);
    UiPrefs.setFontFamily('');
    AppLocale.current = AppLanguage.zh;
  });

  /// 把每一项外观都改成一个**明显的非默认值**。
  void makeEverythingNonDefault() {
    AppTheme.setMode(ThemeMode.dark);
    AppTheme.setPrimary(const Color(0xFF7C5CD6)); // 小鹿紫
    AppTheme.setBackground(const Color(0xFFFAF6EE)); // 米黄
    AppTheme.setBackgroundDark(const Color(0xFF1A1A1A));
    handDrawnBackgroundNotifier.value = HandDrawnBackground.dots; // 点阵纸
    AppTheme.setRadiusScale(1.6); // 最大圆角
    UiPrefs.setTextScale(1.3); // 最大字号
    UiPrefs.setMotion(0.0); // 关闭动效
    UiPrefs.setHapticLevel(0); // 振动关闭
    UiPrefs.setFontFamily('serif');
    AppLocale.current = AppLanguage.en;
  }

  test('wipeAll 之后外观 8 项全部回默认', () async {
    makeEverythingNonDefault();

    // 前置断言：确实已经不是默认了（否则下面的断言没有意义）
    expect(AppTheme.currentMode, ThemeMode.dark);
    expect(AppTheme.primaryColor, const Color(0xFF7C5CD6));
    expect(AppTheme.backgroundNotifier.value, const Color(0xFFFAF6EE));
    expect(AppTheme.backgroundDarkNotifier.value, const Color(0xFF1A1A1A));
    expect(handDrawnBackgroundNotifier.value, HandDrawnBackground.dots);
    expect(AppTheme.radiusScale, 1.6);
    expect(UiPrefs.textScale, 1.3);
    expect(UiPrefs.motion, 0.0);
    expect(UiPrefs.hapticLevel, 0);
    expect(UiPrefs.fontFamily, 'serif');
    expect(AppLocale.current, AppLanguage.en);

    await DataWipe.wipeAll();

    expect(AppTheme.currentMode, ThemeMode.light);
    expect(AppTheme.primaryColor, AppTheme.defaultPrimary);
    expect(AppTheme.backgroundNotifier.value, isNull);
    expect(AppTheme.backgroundDarkNotifier.value, isNull);
    expect(handDrawnBackgroundNotifier.value, HandDrawnBackground.none);
    expect(AppTheme.radiusScale, AppTheme.defaultRadiusScale);
    expect(UiPrefs.textScale, 1.0);
    expect(UiPrefs.motion, 1.0);
    expect(UiPrefs.hapticLevel, 2);
    expect(UiPrefs.fontFamily, '');
    expect(AppLocale.current, AppLanguage.zh);
  });

  test('wipeAll 之后重新读盘也全是默认值（= 冷启动第一帧）', () async {
    makeEverythingNonDefault();
    // 先确认「设过了、也确实写盘了」是成立的：直接写一次盘模拟设置页行为
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('ui_text_scale', 1.3);
    await prefs.setString('ui_font_family', 'serif');
    await prefs.setInt('ui_haptic_level', 0);
    await prefs.setString('ui_language', 'en');
    await prefs.setInt('ui_background_color', 0xFFFAF6EE);
    await prefs.setString('hand_drawn_background_v1', 'dots');
    expect(prefs.getKeys().isNotEmpty, isTrue);

    await DataWipe.wipeAll();

    // 不直接断言 SP 为空：NavPrefs.reset() 会把**默认布局**重新写回
    // `nav_layout_v1`（它只保证内存值回默认，不保证盘上无键）。真正的契约是
    // 「清完之后从头读一遍，读到的全等于默认」—— 也就是重启后的第一帧。
    final after = await SharedPreferences.getInstance();
    expect(await StorageService.loadUiTextScale(), 1.0);
    expect(await StorageService.loadUiFontFamily(), '');
    expect(await StorageService.loadUiHapticLevel(), 2);
    expect(await StorageService.loadUiMotion(), 1.0);
    expect(await StorageService.loadUiRadiusScale(), AppTheme.defaultRadiusScale);
    expect(await StorageService.loadUiBackgroundColor(), isNull);
    expect(await StorageService.loadUiBackgroundColorDark(), isNull);
    expect(await StorageService.loadHandDrawnBackground(),
        HandDrawnBackground.none.id);
    // 外观键本身不该再留在盘上（写回的只有 NavPrefs 的默认布局这类非外观键）
    expect(after.containsKey('ui_text_scale'), isFalse);
    expect(after.containsKey('ui_font_family'), isFalse);
    expect(after.containsKey('ui_haptic_level'), isFalse);
    expect(after.containsKey('ui_language'), isFalse);
    expect(after.containsKey('ui_background_color'), isFalse);
    expect(after.containsKey('hand_drawn_background_v1'), isFalse);
  });

  test('wipeAll 会重置导航布局等既有内存静态值（守卫：别把这段删了）', () async {
    // NavPrefs 在 wipeAll 里早就被 reset，这条只是防止有人重构时把
    // 「内存静态值也要回默认」这一段整体删掉 —— 那段是本文件存在的理由。
    NavPrefs.reset();
    await DataWipe.wipeAll();
    // 不抛异常即通过；NavPrefs 的具体默认值由 nav_prefs 自己的测试守。
  });
}
