/// Tab 身份（与 `NavPage` 一一对应，避免页面与 app.dart 互相 import 形成循环依赖）。
enum NavPageRef { home, message, course, service, user }

/// 页面间广播：用户**真正切到了**某一页。
///
/// App 启动时会预热所有 Tab（消除切页时「空 → 满」的闪烁），
/// 预热会执行各页 initState —— 一次性引导弹窗若在 initState 触发，
/// 就会在用户还没进那一页时误弹。
/// 所以改成：**切页时由容器广播**，目标页在此时弹引导。
///
/// 为什么用**多监听**而不是单个回调：课表页、消息页、服务页的余额卡片
/// 都要在「用户进入」时做事；单槽位会被后注册者覆盖掉。
class CurrentTab {
  CurrentTab._();

  static NavPageRef? _current;

  /// 当前页（null = 尚未初始化）。
  static NavPageRef? get current => _current;

  static void set(NavPageRef page) => _current = page;

  /// 「用户真正进入了某页」的监听列表。
  static final List<void Function(NavPageRef page)> _listeners = [];

  /// 注册监听（返回注销函数，页面 dispose 时调用）。
  static void Function() addListener(void Function(NavPageRef page) fn) {
    _listeners.add(fn);
    return () => _listeners.remove(fn);
  }

  /// 广播「用户进入了 page」。
  static void notifyEntered(NavPageRef page) {
    _current = page;
    // 复制一份再遍历：回调里可能会注册/注销监听。
    for (final fn in List.of(_listeners)) {
      fn(page);
    }
  }
}
