import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个「倒数日」条目（2026-11-04 新增，需求 #6）。
///
/// 设计取舍：
///  · **只存日期（年月日），不存时刻**。倒数日的语义是「还有几天」，
///    精确到分秒没有意义，反而会让「今天」这个状态在跨零点时抖动
///    （23:59 建的「今天」条目，00:01 会突然变成「昨天」）。
///  · `id` 用创建时刻的微秒串，不用 `hashCode` —— `String.hashCode` 在不同
///    Dart 版本/Dart VM 与 AOT 之间不保证稳定，拿它当持久化键会在发版后
///    让所有条目的 id 变化、小组件与提醒全部对不上号。
///  · `pinned` 只是排序权重（置顶的排前面），不参与小组件选谁。
@immutable
class CountdownItem {
  const CountdownItem({
    required this.id,
    required this.title,
    required this.date,
    this.note = '',
    this.pinned = false,
    this.emoji = '',
  });

  final String id;
  final String title;
  final DateTime date;
  final String note;
  final bool pinned;
  final String emoji;

  /// 距今天还有几天：今天 = 0，明天 = 1，昨天 = -1。
  ///
  /// 🔴 **必须按「日」相减，不能拿 `DateTime.difference` 的
  ///    `inDays` 直接比**：后者是「时长 / 24 小时」取整，
  ///    今天 09:00 到明天 08:00 只有 23 小时 → `inDays == 0`，
  ///    界面上会显示成「今天」。改成两端都截到当地零点再算。
  int daysFrom(DateTime now) {
    final a = DateTime(now.year, now.month, now.day);
    final b = DateTime(date.year, date.month, date.day);
    return b.difference(a).inDays;
  }

  /// 「还有 12 天」/「今天」/「已过去 3 天」。
  String label(DateTime now) {
    final d = daysFrom(now);
    if (d == 0) return '今天';
    if (d == 1) return '明天';
    if (d == 2) return '后天';
    if (d > 0) return '还有 $d 天';
    return '已过去 ${-d} 天';
  }

  /// 是否已经过去（用于置灰）。
  bool isPast(DateTime now) => daysFrom(now) < 0;

  CountdownItem copyWith({
    String? title,
    DateTime? date,
    String? note,
    bool? pinned,
    String? emoji,
  }) {
    return CountdownItem(
      id: id,
      title: title ?? this.title,
      date: date ?? this.date,
      note: note ?? this.note,
      pinned: pinned ?? this.pinned,
      emoji: emoji ?? this.emoji,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'date': '${date.year.toString().padLeft(4, '0')}-'
            '${date.month.toString().padLeft(2, '0')}-'
            '${date.day.toString().padLeft(2, '0')}',
        'note': note,
        'pinned': pinned,
        'emoji': emoji,
      };

  static CountdownItem? fromJson(Map<String, dynamic> json) {
    final id = '${json['id'] ?? ''}';
    final title = '${json['title'] ?? ''}';
    final raw = '${json['date'] ?? ''}';
    if (id.isEmpty || title.isEmpty) return null;
    final parts = raw.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    // 损坏日期不能进模型：否则 Calendar/DateTime 会溢出到未来几十年。
    if (y < 2000 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31) return null;
    return CountdownItem(
      id: id,
      title: title,
      date: DateTime(y, m, d),
      note: '${json['note'] ?? ''}',
      pinned: json['pinned'] == true,
      emoji: '${json['emoji'] ?? ''}',
    );
  }
}

/// 倒数日仓库：本地存储 + 变更通知 + 向小组件下发。
///
/// 为什么放在 `services/` 而不是 provider：
/// 小组件同步（`WidgetSyncService.syncCountdownWidget`）与提醒页都要读它，
/// 走 `ChangeNotifier` 单例比让每个调用点各自 `ref.watch` 更省事，
/// 也不会因为页面重建而重复读盘。
class CountdownStore extends ChangeNotifier {
  CountdownStore._();

  static final CountdownStore instance = CountdownStore._();

  /// 存储键。与 `WidgetSyncService` 下发给原生的 key 不同：
  /// 这里是**本地全量**，原生只拿「最近 N 条」的投影。
  static const String storageKey = 'countdown_items_v1';

  /// 桌面两个系统倒数日组件的固定条目 id（用户 m26008 #1 一页式）。
  /// 倒数日 1 = slot 0，倒数日 2 = slot 1；页面直接按这两个 id 读写，
  /// 原生无绑定时按 slot 取对应条目，不再需要「先新增再 pin」。
  static String slotId(int slot) => 'cd_widget_slot_$slot';

  /// 新建时预置的模板（需求原文「预置多个」）。用户点一下就能加，
  /// 不用从空白开始想标题。
  /// 2026-11-04（用户 m20455 #6）：**禁止 emoji 彩 icon**。
  /// 原来这里是 `({String emoji, String title})` 带彩色表情，桌面组件与列表
  /// 上花花绿绿的，和整个 App 的单色图标体系打架。改成只留标题，
  /// 图标统一用 `Icons.hourglass_bottom_rounded` 单色渲染。
  static const List<String> presets = [
    '生日', '放假', '考试', '出行', '纪念日', '目标截止',
  ];

  static const int _maxItems = 30;

  List<CountdownItem> _items = const <CountdownItem>[];
  bool _loaded = false;

  List<CountdownItem> get items => _items;
  bool get loaded => _loaded;

  /// 按「置顶优先 → 日期近的优先 → 已过去的沉底」排序后的视图。
  ///
  /// 已过去的排在最后：用户翻倒数日是为了看**前方**还有多少天，
  /// 昨天的生日不该占第一屏。置顶是用户手动指定的例外，所以第一排序键是它。
  List<CountdownItem> sorted(DateTime now) {
    final list = List<CountdownItem>.of(_items);
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final ap = a.isPast(now);
      final bp = b.isPast(now);
      if (ap != bp) return ap ? 1 : -1;
      final ad = a.daysFrom(now).abs();
      final bd = b.daysFrom(now).abs();
      if (ad != bd) return ad.compareTo(bd);
      return a.title.compareTo(b.title);
    });
    return list;
  }

  /// 小组件要显示的那几条：只取**今天及以后**、按日期升序、最多 [limit] 条。
  ///
  /// 2026-11-05（用户 m24837）：倒数日组件改成「单一卡片单一倒数日」，
  /// 默认 limit = 1；旧调用点（info 组件页预览）传 3 不受影响。
  List<CountdownItem> forWidget(DateTime now, {int limit = 1}) {
    final future = _items.where((e) => !e.isPast(now)).toList()
      ..sort((a, b) {
        final d = a.daysFrom(now).compareTo(b.daysFrom(now));
        if (d != 0) return d;
        return a.title.compareTo(b.title);
      });
    return future.take(limit).toList();
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await load();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    final out = <CountdownItem>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        for (final e in list) {
          if (e is! Map) continue;
          final item = CountdownItem.fromJson(e.cast<String, dynamic>());
          // 坏条目直接跳过，不让一条脏数据毁掉整个列表。
          if (item != null) out.add(item);
        }
      } catch (_) {
        // 解析失败 = 存储坏了，落回空列表（不抛，UI 永远能开）。
      }
    }
    _items = out;
    _loaded = true;
    notifyListeners();
  }

  Future<bool> add(CountdownItem item) async {
    if (_items.length >= _maxItems) return false;
    if (_items.any((e) => e.id == item.id)) return false;
    final next = <CountdownItem>[..._items, item];
    await _commit(next);
    return true;
  }

  Future<bool> update(CountdownItem item) async {
    final idx = _items.indexWhere((e) => e.id == item.id);
    if (idx < 0) return false;
    final next = List<CountdownItem>.of(_items)..[idx] = item;
    await _commit(next);
    return true;
  }

  Future<void> remove(String id) async {
    final next = _items.where((e) => e.id != id).toList();
    if (next.length == _items.length) return;
    await _commit(next);
  }

  Future<void> clear() async {
    if (_items.isEmpty) return;
    await _commit(const <CountdownItem>[]);
  }

  /// 生成一个新 id：微秒时间戳。理由见 [CountdownItem] 的类注释。
  static String newId() =>
      'cd_${DateTime.now().microsecondsSinceEpoch.toString()}';

  Future<void> _commit(List<CountdownItem> next) async {
    _items = next;
    _loaded = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      storageKey,
      jsonEncode(next.map((e) => e.toJson()).toList()),
    );
  }
}
