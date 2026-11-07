import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiyuan_pocket/services/widget_prefs.dart';

/// 2026-11-05（用户 m24495 #1）：每种组件各自的外观设置。
///
/// 关键约束是**向后兼容**：老用户升级后，从没单独设置过的组件必须
/// 继续跟随全局外观，不能因为引入了 per-kind 键就变成「恢复默认」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('per-kind 键不存在时回落全局值', () async {
    await WidgetPrefs.setTheme('dark');
    await WidgetPrefs.setAccent('112233');
    await WidgetPrefs.setFontScale(1.15);
    expect(await WidgetPrefs.themeFor('exam'), 'dark');
    expect(await WidgetPrefs.accentFor('exam'), '112233');
    expect(await WidgetPrefs.fontScaleFor('exam'), 1.15);
    expect(await WidgetPrefs.hasCustomAppearance('exam'), isFalse);
  });

  test('单独设置只影响那一种组件', () async {
    await WidgetPrefs.setTheme('light');
    await WidgetPrefs.setThemeFor('countdown', 'dark');
    expect(await WidgetPrefs.themeFor('countdown'), 'dark');
    expect(await WidgetPrefs.themeFor('exam'), 'light');
    expect(await WidgetPrefs.themeFor('card'), 'light');
    expect(await WidgetPrefs.themeFor('schedule'), 'light');
    expect(await WidgetPrefs.hasCustomAppearance('countdown'), isTrue);
  });

  test('appearanceFor 下发的键名与原生 WidgetPrefs 一致', () async {
    await WidgetPrefs.setThemeFor('card', 'dark');
    await WidgetPrefs.setAccentFor('card', 'ABCDEF');
    await WidgetPrefs.setFontScaleFor('card', 0.9);
    final json = await WidgetPrefs.appearanceFor('card');
    // 🔴 键名必须是 theme/accent/fontScale —— Kotlin 的 WidgetPrefs 读的就是
    // 这三个名字，换名字等于原生侧收不到。
    expect(json.keys.toSet(), containsAll(<String>['theme', 'accent', 'fontScale']));
    expect(json['theme'], 'dark');
    expect(json['accent'], 'ABCDEF');
    expect(json['fontScale'], 0.9);
  });

  test('clearAppearanceFor 只清那一种组件', () async {
    await WidgetPrefs.setTheme('light');
    await WidgetPrefs.setThemeFor('exam', 'dark');
    await WidgetPrefs.setThemeFor('card', 'dark');
    await WidgetPrefs.clearAppearanceFor('exam');
    expect(await WidgetPrefs.hasCustomAppearance('exam'), isFalse);
    expect(await WidgetPrefs.themeFor('exam'), 'light');
    expect(await WidgetPrefs.themeFor('card'), 'dark');
  });

  test('字号缩放被夹在 0.8..1.2', () async {
    await WidgetPrefs.setFontScaleFor('exam', 3.0);
    expect(await WidgetPrefs.fontScaleFor('exam'), 1.2);
    await WidgetPrefs.setFontScaleFor('exam', 0.1);
    expect(await WidgetPrefs.fontScaleFor('exam'), 0.8);
  });
}
