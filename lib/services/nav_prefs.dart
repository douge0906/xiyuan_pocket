import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 底部导航的页面（v1.7.0）。
///
/// 🔴 用**枚举身份**而不是下标寻址：导航项可隐藏 / 可排序之后，下标随时会变
///    （隐藏一项，它后面的全部前移），凡「跳到某一页」都必须用枚举，
///    绝不能用位置数字 —— 否则用户改过顺序就会出现「点 A 跳到 B」。
enum NavPage {
  home('home', '首页', Icons.home_rounded, Icons.home_rounded),
  message('message', '消息', Icons.inbox_outlined, Icons.inbox_outlined),
  course('course', '课表', Icons.calendar_month_outlined,
      Icons.calendar_month_rounded),
  service('service', '服务', Icons.apps_rounded, Icons.apps_rounded),
  user('user', '用户', Icons.person_outline_rounded, Icons.person_rounded);

  const NavPage(this.id, this.label, this.icon, this.activeIcon);

  /// 存进磁盘用的稳定 id（**不要改**，改了等于用户已有配置作废）。
  final String id;

  final String label;
  final IconData icon;
  final IconData activeIcon;

  static NavPage? byId(String id) {
    for (final p in values) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// 固定页：**不可隐藏**，且永远排在最后一位。
///
/// 用户要求「主页除了用户页以外都可以隐藏或者随意调节顺序」——
/// 用户页是登录态与账号设置的唯一入口，藏掉了就没地方找回，故锁死。
const NavPage kPinnedNavPage = NavPage.user;

/// 可自定义的页面（除固定页外的全部）—— 也是导航设置页里可拖动的那几项。
const List<NavPage> kCustomizableNavPages = <NavPage>[
  NavPage.home,
  NavPage.message,
  NavPage.course,
  NavPage.service,
];

/// 底部导航布局（v1.7.0）：顺序 + 隐藏项。
@immutable
class NavLayout {
  const NavLayout({required this.order, required this.hidden});

  /// 可自定义页面的顺序（**不含**固定页）。
  final List<NavPage> order;

  /// 被隐藏的页面（**不含**固定页 —— 固定页不可能被隐藏）。
  final Set<NavPage> hidden;

  /// 底部导航最终显示的顺序：自定义页里未隐藏的 + 固定页（永远最后）。
  List<NavPage> get visible =>
      <NavPage>[...order.where((p) => !hidden.contains(p)), kPinnedNavPage];

  bool isVisible(NavPage p) => p == kPinnedNavPage || !hidden.contains(p);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'order': order.map((p) => p.id).toList(),
        'hidden': hidden.map((p) => p.id).toList(),
      };

  /// 容错解析（老数据 / 被手改过的数据 / 以后新增页面都要能兜住）。
  static NavLayout fromJson(Map<String, dynamic> j) {
    final order = <NavPage>[];
    final rawOrder = j['order'];
    if (rawOrder is List) {
      for (final v in rawOrder) {
        final p = NavPage.byId('$v');
        // 固定页不进 order；重复项丢掉
        if (p != null && p != kPinnedNavPage && !order.contains(p)) order.add(p);
      }
    }
    // 缺项（老数据没有的新页面）按默认顺序补到末尾 —— 升级后不会「新功能不见了」
    for (final p in kCustomizableNavPages) {
      if (!order.contains(p)) order.add(p);
    }
    final hidden = <NavPage>{};
    final rawHidden = j['hidden'];
    if (rawHidden is List) {
      for (final v in rawHidden) {
        final p = NavPage.byId('$v');
        if (p != null && p != kPinnedNavPage) hidden.add(p);
      }
    }
    return NavLayout(
      order: List<NavPage>.unmodifiable(order),
      hidden: Set<NavPage>.unmodifiable(hidden),
    );
  }

  /// 出厂布局：首页 / 消息 / 课表 / 服务，全显示。
  static final NavLayout initial = NavLayout(
    order: List<NavPage>.unmodifiable(kCustomizableNavPages),
    hidden: const <NavPage>{},
  );
}

/// 底部导航布局的读取 / 保存 / 变更通知（v1.7.0）。
///
/// 通知方式与 [AppTheme] 的主题色一致：一个全局 ValueNotifier，
/// MainApp 监听它重建导航条 —— 设置页改完**立刻**生效，不用重启。
class NavPrefs {
  NavPrefs._();

  static const String _key = 'nav_layout_v1';

  static final ValueNotifier<NavLayout> notifier =
      ValueNotifier<NavLayout>(NavLayout.initial);

  static NavLayout get layout => notifier.value;

  /// 当前实际显示的导航项（含固定页，已按用户顺序排好）。
  static List<NavPage> get visible => notifier.value.visible;

  /// 进入 App 的**实际初始页面**（v1.7.1）= 用户排在最前面的那一页。
  ///
  /// 首页没动过时它就是首页（老行为完全一致）；首页被挪到后面或被隐藏时，
  /// 落点顺延到当前排第一的那页 —— 和底部导航「从左到右」的顺序一致，
  /// 不会一进来就跳到中间去，也不会停在一张空白页上。
  static NavPage get initialPage => visible.first;

  /// 启动时读一次（main.dart 里 `await` 过，保证首帧就是用户的布局、不跳变）。
  static Future<void> ensureLoaded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw);
      if (j is Map<String, dynamic>) notifier.value = NavLayout.fromJson(j);
    } catch (_) {
      // 数据损坏 → 保持出厂布局，导航永远可用（绝不因为读配置失败而空白）
    }
  }

  /// 拖动排序：传入可自定义页面的**完整新顺序**。
  static Future<void> setOrder(List<NavPage> order) async {
    notifier.value = NavLayout(
      order: List<NavPage>.unmodifiable(order),
      hidden: layout.hidden,
    );
    await _persist();
  }

  /// 显示 / 隐藏某一页。固定页直接忽略（不可隐藏）。
  static Future<void> setHidden(NavPage page, bool hidden) async {
    if (page == kPinnedNavPage) return;
    final next = Set<NavPage>.from(layout.hidden);
    if (hidden) {
      next.add(page);
    } else {
      next.remove(page);
    }
    notifier.value = NavLayout(
      order: layout.order,
      hidden: Set<NavPage>.unmodifiable(next),
    );
    await _persist();
  }


  /// 一次性设置可见页面（极简模式首次选择用）。
  ///
  /// 逐个 [setHidden] 会连续发 4 次通知、重排 4 次导航；这里合并成一次。
  static Future<void> setVisiblePages(Set<NavPage> visible) async {
    final hidden = kCustomizableNavPages
        .where((p) => !visible.contains(p))
        .toSet();
    notifier.value = NavLayout(
      order: layout.order,
      hidden: Set<NavPage>.unmodifiable(hidden),
    );
    await _persist();
  }

  /// 恢复出厂布局（全部显示 + 默认顺序）。
  static Future<void> reset() async {
    notifier.value = NavLayout.initial;
    await _persist();
  }

  static Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(layout.toJson()));
    } catch (_) {
      // 写失败 → 内存里已生效，只是下次启动回落默认布局，不影响本次使用
    }
  }
}
