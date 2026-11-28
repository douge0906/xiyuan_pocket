import 'package:shared_preferences/shared_preferences.dart';

/// 首次启动「快速开始」的状态。
///
/// 只记两件事：走完没有、选了哪种模式。模式本身已经落进 `NavPrefs`（页面显隐），
/// 这里存一份只是让下次能知道「用户当初选的是哪个」。
enum OnboardingMode {
  full('full'),
  minimal('minimal');

  const OnboardingMode(this.id);
  final String id;

  static OnboardingMode byId(String? id) =>
      id == minimal.id ? minimal : full;
}

class OnboardingPrefs {
  OnboardingPrefs._();

  static const String _kDone = 'onboarding_done_v1';
  static const String _kMode = 'onboarding_mode_v1';

  static Future<bool> isDone() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kDone) == true;
    } catch (_) {
      // 读不到就当没走过 —— 宁可多看一次引导，也不要让首屏空着。
      return false;
    }
  }

  static Future<OnboardingMode> mode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return OnboardingMode.byId(prefs.getString(_kMode));
    } catch (_) {
      return OnboardingMode.full;
    }
  }

  static Future<void> markDone(OnboardingMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kDone, true);
      await prefs.setString(_kMode, mode.id);
    } catch (_) {
      // 写失败不影响本次使用；下次启动会再引导一次。
    }
  }

  /// 清除数据后要回到「没走过」，否则换个人用同一台手机看不到引导。
  static Future<void> reset() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kDone);
      await prefs.remove(_kMode);
    } catch (_) {}
  }
}
