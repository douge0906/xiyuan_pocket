import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/services/current_tab.dart';

/// 「用户进入页」广播的回归测试（2026-10-30 六次自检）。
///
/// 背景：App 启动会预热所有 Tab（消除切页闪烁），预热时各页 initState 会跑。
/// 一次性引导弹窗若在 initState 触发就会在启动时误弹；
/// 所以改成「切页时广播 → 目标页弹引导」。
///
/// 这里锁定：广播要**送达所有监听者**（课表页 / 消息页 / 余额卡片三处），
/// 且监听者注销后不再被调用。
void main() {
  test('🔴 广播会送达所有监听者', () {
    final seen = <String>[];
    final un1 = CurrentTab.addListener((p) => seen.add('a-${p.name}'));
    final un2 = CurrentTab.addListener((p) => seen.add('b-${p.name}'));

    CurrentTab.notifyEntered(NavPageRef.course);

    expect(seen, ['a-course', 'b-course']);
    un1();
    un2();
  });

  test('🔴 注销后不再收到广播', () {
    final seen = <String>[];
    final un = CurrentTab.addListener((p) => seen.add(p.name));
    un();
    CurrentTab.notifyEntered(NavPageRef.service);
    expect(seen, isEmpty);
  });

  test('🔴 广播同时更新当前页', () {
    CurrentTab.notifyEntered(NavPageRef.message);
    expect(CurrentTab.current, NavPageRef.message);
  });
}
