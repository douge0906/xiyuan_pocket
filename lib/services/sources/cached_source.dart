import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/message.dart';
import '../message_archive.dart';
import '../message_source.dart';
import '../storage_service.dart';

/// 🔴 **所有消息源共用的唯一一套加载机制。**
///
/// ## 为什么要有这个基类
/// 重构前每个消息源各自实现一遍加载：教务处一套、校园资讯栏目一套。
/// 后果是同一个设置（「最多同步 N 条」）**只对一半源生效** ——
/// 用户把条数调小，几个资讯栏目照样各拉 60 条，看起来就像「设置没生效」。
/// **同一个机制写两遍，就一定会漂。**
///
/// ## 统一后的算法（**只有这一份**）
/// ```text
/// 档案 = MessageArchive.load(sourceId)          // 本机档案
/// 目标 = StorageService.loadMessageSyncCount()  // 用户设置「最多同步 N 条」
///
/// 搜索            -> 本地过滤档案，绝不联网
/// archive         -> 只读档案
/// cached          -> 立刻返回档案，同步丢后台（进页面）
/// incremental     -> 同步一次，merge 进档案后返回（下拉刷新）
/// full            -> 按目标全量抓（改了数量 / 冷启动）
/// 同步一次        -> 档案 < 目标 ? 按目标全量补齐 : 只抓最新一页
/// 抓取失败        -> 返回旧档案 + error（降级，绝不清空）
/// ```
///
/// ## 四条关键不变量
/// ① **失败与空严格分开**。抓取失败带 `error` 且保留旧数据，
///    绝不返回「空且无错」（本项目发作次数最多的 bug）。
/// ② **增量失败一律是 `null`，绝不是空列表**。空列表 = 「确实没有新公告」，
///    两者在上层完全同形，混淆一次就又变成「断网时显示刷新成功」。
/// ③ **网络 IO 绝不在写锁内**。锁只保护 `load → merge → save` 这十几行
///    读改写；把网络请求也圈进去，会让"后台增量正在跑时的下拉刷新"
///    排队干等，表现为刷新计时动画走不动。
/// ④ **档案不足目标就必须真的去抓**。只做增量的话，档案长度永远长不到
///    用户设置的数量 —— 「设了 200 条却只看到几十条」就是这么来的。
abstract class CachedMessageSource implements MessageSource {
  /// **增量**：只抓「最新一小段」（1 页），用于快速比对。
  ///
  /// 🔴 **返回 `null` 表示抓取失败**，与「抓到空列表」严格分开。
  /// 绝大多数消息源都只需要它 —— 列表顶部只有最新一页会变。
  Future<List<Message>?> fetchIncremental();

  /// **全量**：按 [target] 条抓一次。返回 `null` 表示抓取失败。
  Future<List<Message>?> fetchFull(int target);

  /// 拉详情。返回 `null` 表示失败（不是「没有正文」）。
  @override
  Future<MessageDetail?> fetchDetail(Message message);

  @override
  MessageChannel get channel;

  String get sourceId => channel.id;

  /// 抓取失败时页面上显示的名字。
  String get displayName => channel.name;

  /// 本机档案里**有没有东西**（**不联网**）。
  ///
  /// 用途：批量更新时先判断「这个源值不值得读一趟档案」。
  /// 空的档案读出来也是空的，白占一个异步往返；而 [fetch] 在档案为空时
  /// 会兜底去抓 —— 批量更新里那一步由「联网更新」那趟统一做，
  /// 不必在这里多做一次。
  Future<bool> hasArchive() async => (await MessageArchive.load(sourceId)).isNotEmpty;

  /// 后台增量真的写进档案后回调一次 —— 仓库据此刷新界面。
  ///
  /// 🔴 为什么必须有：重构前后台增量抓到了新公告，却**没有任何人通知界面**，
  /// 于是每次进消息页看到的都是上一次的档案，「有新的但看不到」。
  /// 发布-订阅是**两端**契约，只实现发布端等于没实现。
  void Function()? onArchiveUpdated;

  @override
  Future<MessagePage> fetch({
    required FetchMode mode,
    String q = '',
  }) async {
    final target = await StorageService.loadMessageSyncCount();
    final searching = q.trim().isNotEmpty;

    // 搜索只在**本机档案**上过滤，不联网。
    // 搜索是逐键触发的（防抖 350ms），每次击键都打一遍校方站点既不礼貌
    // 也没必要；进入页面时已经跑过一次增量，档案就是当前能有的最新。
    if (searching) {
      final archive = await MessageArchive.load(sourceId);
      if (archive.isEmpty) return _fullFetch(target, q);
      return _pageOf(_filter(archive, q), target, fromCache: true);
    }

    switch (mode) {
      case FetchMode.archive:
        final archive = await MessageArchive.load(sourceId);
        // 档案空 = 从未成功抓过 → 该走全量，不能报「暂无内容」。
        if (archive.isEmpty) return _fullFetch(target, q);
        return _pageOf(archive, target, fromCache: true);

      case FetchMode.cached:
        final archive = await MessageArchive.load(sourceId);
        if (archive.isEmpty) return _fullFetch(target, q);
        unawaited(_backgroundSync(target));
        return _pageOf(archive, target, fromCache: true);

      case FetchMode.incremental:
        final archive = await MessageArchive.load(sourceId);
        if (archive.isEmpty) return _fullFetch(target, q);
        final merged = await _syncFetch(target);
        if (merged == null) {
          // 增量失败：降级用旧档案 + 带上错误。不清空，也不谎报「无新增」。
          return _pageOf(archive, target,
              fromCache: true, error: '$displayName 刷新失败，显示的是上次结果');
        }
        return _pageOf(merged, target, fromCache: false);

      case FetchMode.full:
        return _fullFetch(target, q);
    }
  }

  /// 全量抓 —— 冷启动、「改了同步条数」、以及「档案不够目标要补齐」都走这里。
  ///
  /// 🔴 这条路必须**能被再次到达**。重构前的全量入口只在「档案为空」时
  /// 可达，所以一旦有档案，全量永远够不着 ⇒「把 3 页改成 20 页，回来一看
  /// 还是 80 条」。
  Future<MessagePage> _fullFetch(int target, String q) async {
    final archive = await MessageArchive.load(sourceId);
    final fresh = await _tryFull(target); // 网络：锁外
    if (fresh == null) {
      if (archive.isEmpty) {
        return MessagePage(items: const [], total: 0, error: '$displayName 加载失败');
      }
      return _pageOf(_filter(archive, q), target,
          fromCache: true, error: '$displayName 加载失败，显示的是上次结果');
    }
    final out = await _mergeIntoArchive(fresh, target);
    if (out == null) {
      return _pageOf(_filter(archive, q), target,
          fromCache: true, error: '$displayName 数据保存失败，显示的是上次结果');
    }
    // 全量抓就是「向目标条数冲击」的最大努力，成功一次之后本实例不必再补。
    _archiveFilled = true;
    return _pageOf(_filter(out, q), target, fromCache: false);
  }

  /// **本实例**是否已经朝目标条数补过档。
  ///
  /// 为什么需要这个标记：站点内容本身可能少于目标（实测团委全站只有几十条），
  /// 若每次「档案 < 目标」都发起一轮全量抓，就成了**每次进页面都白打十几个请求**。
  /// 补齐按实例只做一次（实例存活期 = 消息页存活期），失败则不置位、下次还会再试。
  bool _archiveFilled = false;

  /// 档案是否还**不够**用户设置的目标条数，需要补齐。
  ///
  /// 🔴 这是「只加载几十条」的正解。原逻辑是「档案非空就只做 1 页增量」——
  /// 于是全新安装（内置快照仅 20 条）永远停在一二十条：把「最多同步条数」
  /// 设成 200 也毫无变化，因为**没有任何一条路径会为了让档案变长而去抓**。
  bool _needsFill(int have, int target) =>
      !_archiveFilled && target > 0 && have < target;

  /// 同步一次：档案不够目标 → 按目标补齐（全量）；够了 → 只问一句有没有新的。
  ///
  /// 失败一律返回 `null`（与「确实没有新内容」严格分开）。
  Future<List<Message>?> _syncFetch(int target) async {
    final archive = await MessageArchive.load(sourceId);
    if (_needsFill(archive.length, target)) {
      final fresh = await _tryFull(target); // 网络：锁外
      if (fresh == null) return null; // 失败：不置标记，下次进来还会再试
      // 成功就置标记 —— 哪怕抓回来仍不足目标（站点本身就没有那么多），
      // 也不能每次进页面都重抓一遍。
      _archiveFilled = true;
      return _mergeIntoArchive(fresh, target);
    }
    final fresh = await _tryIncremental();
    if (fresh == null) return null;
    return _mergeIntoArchive(fresh, target);
  }

  /// 后台静默同步：失败不打扰用户（手上已有数据），成功后通知界面。
  Future<void> _backgroundSync(int target) async {
    try {
      final before = await MessageArchive.load(sourceId);
      final merged = await _syncFetch(target);
      // null = 失败：安静跳过，绝不把失败当成「没有新公告」去重写档案。
      if (merged == null) return;
      // 内容真的变了才通知 —— 否则每次进页面都会白重建一遍列表。
      if (!_sameContent(before, merged)) onArchiveUpdated?.call();
    } catch (e) {
      _log('后台同步失败：$e');
    }
  }

  Future<List<Message>?> _tryIncremental() async {
    try {
      return await fetchIncremental();
    } catch (e) {
      _log('增量抓取抛异常：$e');
      return null;
    }
  }

  Future<List<Message>?> _tryFull(int target) async {
    try {
      return await fetchFull(target);
    } catch (e) {
      _log('全量抓取抛异常：$e');
      return null;
    }
  }

  // ---------------- 档案写入 ----------------

  /// 同一 [sourceId] 的档案写入**串行化**。
  ///
  /// 🔴 两条路径会并发写同一份档案：① 后台静默增量 ② 下拉刷新 / 全量抓。
  /// 各自 `load → merge → save`，后写者会把先写者的结果整份覆盖掉
  /// （last-writer-wins，表现为「刚刷出来的新公告又不见了」）。
  /// 这里给每个 sourceId 一把串行锁，后来的等先前的。
  ///
  /// ⚠️ **锁只包住读改写这十几行**。网络请求发生在调用本方法**之前** ——
  /// 把网络圈进临界区会让刷新排队干等。
  static final Map<String, Future<void>> _writeLocks = <String, Future<void>>{};

  /// 把 [fresh] 合并进档案并落盘，返回合并后的档案；失败返回 `null`。
  Future<List<Message>?> _mergeIntoArchive(List<Message> fresh, int target) {
    return _serializedWrite(() async {
      final latest = await MessageArchive.load(sourceId);
      final merged = _trim(MessageArchive.merge(latest, fresh), target);
      await _save(latest, merged);
      return merged;
    });
  }

  Future<T?> _serializedWrite<T>(Future<T> Function() action) {
    final prev = _writeLocks[sourceId] ?? Future<void>.value();
    final completer = Completer<T?>();
    // 登记进链尾的只关心「这一轮做完没有」，错误在此吞掉，不传染下一轮。
    final next = completer.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _writeLocks[sourceId] = next;
    prev.then((_) async {
      try {
        completer.complete(await action());
      } catch (e) {
        _log('档案写入失败：$e');
        completer.complete(null);
      }
    });
    return completer.future;
  }

  /// 内容没变就不重写档案，也不通知界面。
  ///
  /// 为什么要查：merge 结果与旧档案完全相同是**常态**（每次下拉刷新都没
  /// 新公告），而 200 条的档案约 40KB —— 无条件 `jsonEncode` + `setString`
  /// 等于每次刷新都重写一遍；对界面来说则是每次进页面都白重建一次列表。
  ///
  /// ⚠️ **按 key 比较内容，不按下标** —— 档案可能来自不同写入路径（增量
  /// merge / 种子数据 / 全量重抓），顺序未必一致。「同一批条目换个顺序」
  /// 不该被当成内容变化，否则首发那次刷新必然误报一次。
  Future<void> _save(List<Message> old, List<Message> next) async {
    if (_sameContent(old, next)) return;
    await MessageArchive.save(sourceId, next);
  }

  static bool _sameContent(List<Message> a, List<Message> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    final byKey = <String, Message>{};
    for (final m in a) {
      byKey[m.key] = m;
    }
    if (byKey.length != b.length) return false;
    for (final m in b) {
      final x = byKey[m.key];
      if (x == null) return false;
      if (x.title != m.title ||
          x.date != m.date ||
          x.url != m.url ||
          x.badge != m.badge) {
        return false;
      }
    }
    return true;
  }

  /// 档案上限 = **用户设置的「最多同步 N 条」**（用户拍板：跟着设置走）。
  ///
  /// ⚠️ 因此调小 N 会真的丢弃多出来的条目（连同详情链接），用户已明确
  /// 接受并要求**不做兜底**。改这里之前先确认口径没变。
  List<Message> _trim(List<Message> items, int target) {
    if (target <= 0) return items;
    return items.length <= target ? items : items.sublist(0, target);
  }

  /// 标题模糊过滤（各源格式一致，统一在这里做）。
  List<Message> _filter(List<Message> src, String q) {
    final kw = q.trim().toLowerCase();
    if (kw.isEmpty) return src;
    return src.where((e) => e.title.toLowerCase().contains(kw)).toList();
  }

  /// 切片。**展示条数由设置决定，不由「碰巧抓到了多少」决定。**
  ///
  /// [MessagePage.total] 报「本机档案共有多少条」，供底部「已加载 N 条」用。
  MessagePage _pageOf(List<Message> src, int target,
      {required bool fromCache, String? error}) {
    final n = target <= 0 ? src.length : target;
    final slice = src.length > n ? src.sublist(0, n) : src;
    return MessagePage(
      items: slice,
      total: src.length,
      fromCache: fromCache,
      error: error,
    );
  }

  void _log(String msg) {
    debugPrint('[CachedMessageSource:$sourceId] $msg');
  }
}
