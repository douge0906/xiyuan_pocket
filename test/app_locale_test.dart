import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/services/app_locale.dart';

/// 多语言文案表自检（2026-10-30）。
///
/// 之前踩过的坑：中文表加了新键、英文表没加 → 切到英文时那一处直接显示
/// key 本身（形如 `notif_perm`），非常刺眼。
/// 这个测试把「中英键集合必须完全一致」钉死。
void main() {
  test('🔴 中英文案键必须完全一致', () {
    final zh = AppLocale.strings[AppLanguage.zh]!;
    final en = AppLocale.strings[AppLanguage.en]!;
    expect(
      zh.keys.toSet().difference(en.keys.toSet()),
      isEmpty,
      reason: '英文表缺少这些键：${zh.keys.toSet().difference(en.keys.toSet())}',
    );
    expect(
      en.keys.toSet().difference(zh.keys.toSet()),
      isEmpty,
      reason: '中文表缺少这些键：${en.keys.toSet().difference(zh.keys.toSet())}',
    );
  });

  test('🔴 没有任何文案等于 key 本身（漏翻会露馅）', () {
    for (final entry in AppLocale.strings.entries) {
      for (final kv in entry.value.entries) {
        expect(kv.value, isNot(kv.key),
            reason: '${entry.key.code} 的 ${kv.key} 没有翻译');
      }
    }
  });

  test('🔴 底栏与首页问候语的键必须存在', () {
    for (final id in ['home', 'message', 'course', 'service', 'user']) {
      expect(AppLocale.strings[AppLanguage.zh]!.containsKey('nav_$id'), isTrue);
      expect(AppLocale.strings[AppLanguage.en]!.containsKey('nav_$id'), isTrue);
    }
    for (final k in ['greeting_morning', 'greeting_noon', 'greeting_evening',
      'greeting_late']) {
      expect(AppLocale.strings[AppLanguage.zh]!.containsKey(k), isTrue);
      expect(AppLocale.strings[AppLanguage.en]!.containsKey(k), isTrue);
    }
  });
}
