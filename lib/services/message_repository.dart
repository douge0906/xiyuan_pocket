import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/message.dart';
import '../models/message_read_storage.dart';
import 'message_channel_service.dart';
import 'message_source.dart';
import 'sources/cached_source.dart';
import 'sources/campus_source.dart';
import 'sources/jwc_source.dart';

/// 单个消息源的状态。
///
/// 重构前消息页有两套形状完全不同的状态：教务处是 6 个平铺字段
/// （items / loading / error / total / loadingMore / pageSize），
/// 资讯是 `Map<channelId, 另一个状态类>`。现在统一成这一种 ——
/// 所有源都是这个形状，界面只写一套渲染逻辑，**新增源零 UI 成本**。
@immutable
class ChannelState {
  final List<Message> items;

  /// 首次加载中（列表还没有任何内容时用它出骨架/转圈）。
  final bool loading;

  /// 🔴 失败原因；`null` = 成功（哪怕结果为空）。
  ///
  /// **绝不能用 `items.isEmpty` 判断失败** —— 那是本项目发作次数最多的 bug。
  final String? error;

  /// 本机档案共有多少条；`<= 0` 表示未知。
  final int total;

  /// 本次数据来自本机档案（用于「显示的是上次结果」提示）。
  final bool fromCache;

  const ChannelState({
    this.items = const [],
    this.loading = false,
    this.error,
    this.total = 0,
    this.fromCache = false,
  });

  /// 真的没有内容（不是加载中、也不是失败）。
  bool get isEmpty => items.isEmpty && !loading && error == null;

  ChannelState copyWith({
    List<Message>? items,
    bool? loading,
    String? error,
    int? total,
    bool? fromCache,
  }) =>
      ChannelState(
        items: items ?? this.items,
        loading: loading ?? this.loading,
        error: error,
        total: total ?? this.total,
        fromCache: fromCache ?? this.fromCache,
      );
}

/// 消息仓库 —— 消息页**唯一**的状态与操作入口。
///
/// 【为什么有它】重构前状态散在 `State` 里（一组平铺字段 + 一个 Map），
/// 加载、已读、搜索三件事各写两遍（一份给教务处、一份给资讯），必然漂移。
/// 本类把它们收成一套：界面只认 [stateOf]，只调 [load] / [loadDetail] /
/// [markRead]，**新增消息源零 UI 成本**。
///
/// [notifyListeners] 用 [Listenable] 暴露，页面用 `ListenableBuilder` 重建 ——
/// ⚠️ 发布-订阅是**两端**契约：新建 ChangeNotifier 时必须同时确认订阅方，
/// 只写 `notifyListeners()` 等于没接线（"搜索完全失效"就是这么来的）。
class MessageRepository extends ChangeNotifier {
  /// 教务处（默认订阅，所以排第一位）。
  static final JwcSource _jwc = JwcSource();

  final Map<String, CachedMessageSource> _sources = {};
  final Map<String, ChannelState> _states = {};

  /// 同一源的并发加载：后来的**等前一个跑完**再跑自己。
  ///
  /// 为什么不是「已在加载就直接丢弃」：那样"改了同步条数 → 全渠道刷新"里
  /// 正在加载的那个源会用**旧参数**的结果收尾，而进度条照样显示 5/5。
  final Map<String, Future<void>> _inflight = {};

  /// 已读键集合（[Message.key] 形态：`<sourceId>:<id>`）。
  Set<String> _readKeys = {};

  /// 未读红点基准线（天级字符串，如 `2026-10-06`）。仅对声明了
  /// [MessageChannel.usesUnreadBaseline] 的源生效（目前只有教务处）。
  String _unreadBaseline = '';

  /// 当前页签的源 id。搜索只重载它。
  String? _activeChannelId;

  String _query = '';
  Timer? _debounce;

  /// 已加载过「目录」的渠道集合（区分「没加载过」与「加载过但为空」）。
  final Set<String> _loaded = {};

  // ---------------- 源注册表 ----------------

  /// 注册全部**已订阅**的消息源。
  ///
  /// 【所有源一律平等】教务处也在**订阅集合**里 —— 它只是默认订阅，
  /// 用户一样可以关掉。所以这里读的是 [subscribedIds]，不含"内置特权"。
  ///
  /// 返回 `[]` 是完全合法的状态（用户把所有栏目都关掉了），
  /// 页面必须能显示「还没订阅任何栏目」的空态，不能崩。
  Future<List<MessageSource>> registerSources({Set<String>? subscribedIds}) async {
    final ids = subscribedIds ?? await MessageChannelService.loadSubscribed();
    _sources.clear();
    if (ids.contains(kJwcChannelId)) _addSource(_jwc);
    for (final ch in MessageChannelService.campusChannels) {
      if (!ids.contains(ch.id)) continue;
      _addSource(CampusSource(columnId: ch.id, columnName: ch.name));
    }
    return _sources.values.toList();
  }

  void _addSource(CachedMessageSource source) {
    // 🔴 接上「后台增量写档成功」的回调。不接这一步，增量抓到了新公告
    // 也没有任何人通知界面 —— 表现是"每次进消息页都看不到最新的"。
    source.onArchiveUpdated = () => _onSourceUpdated(source.channel.id);
    _sources[source.channel.id] = source;
  }

  MessageSource? sourceOf(String channelId) => _sources[channelId];

  /// 已注册的全部消息源。
  List<CachedMessageSource> get registeredSources =>
      _sources.values.toList(growable: false);

  /// 仅供测试注入假源（生产代码没有调用方）。
  @visibleForTesting
  void debugRegisterSource(CachedMessageSource source) => _addSource(source);

  // ---------------- 加载 ----------------

  /// 强刷**所有**已注册消息源，逐个串行。
  ///
  /// 用于「用户在设置里改了『最多同步 N 条』」→ 必须走 [FetchMode.full]，
  /// 否则每个源只会再抓 1 页，表现就是"改了没生效"。
  ///
  /// 为什么**串行**而不是并发：① 这些都是**校方公开站点**，并发 5 路 ×
  /// 每路数页 = 十几条同时打过去，没必要也不礼貌；② 串行能让
  /// 「已完成 3/5」的进度真实反映到界面上。
  ///
  /// 单个源失败**不中断**整体 —— 失败信息记在该源的 [ChannelState.error] 里。
  Future<int> refreshAll({
    FetchMode mode = FetchMode.full,
    void Function(int done, int total)? onProgress,
  }) async {
    final sources = registeredSources;
    final total = sources.length;
    var done = 0;
    onProgress?.call(done, total);
    for (final source in sources) {
      if (_disposed) break;
      await load(source.channel.id, mode: mode);
      if (_disposed) break;
      done++;
      onProgress?.call(done, total);
    }
    return done;
  }

  /// 载入某源。
  ///
  /// [silent] = true 时**不置 loading**（用于后台增量写档后的静默重读，
  /// 避免列表闪一下）。
  Future<void> load(
    String channelId, {
    FetchMode mode = FetchMode.cached,
    bool silent = false,
  }) async {
    final source = _sources[channelId];
    if (source == null) return;

    // 同一源并发加载 → 等前一个跑完再跑自己（见 [_inflight] 注释）。
    final running = _inflight[channelId];
    if (running != null) await running;
    if (_disposed) return;

    final gate = Completer<void>();
    _inflight[channelId] = gate.future;
    try {
      await _performLoad(channelId, source, mode, silent);
    } finally {
      if (!gate.isCompleted) gate.complete();
    }
  }

  Future<void> _performLoad(
    String channelId,
    CachedMessageSource source,
    FetchMode mode,
    bool silent,
  ) async {
    final prev = stateOf(channelId);
    if (!silent) {
      _states[channelId] = prev.copyWith(loading: true, error: null);
      _notify();
    }
    _loaded.add(channelId);

    MessagePage page;
    try {
      page = await source.fetch(mode: mode, q: _query);
    } catch (e) {
      // 源内部已做兜底；这是最后一道防线，失败**绝不清空**旧内容。
      if (_disposed) return;
      _states[channelId] = ChannelState(
        items: prev.items,
        loading: false,
        error: '${source.displayName} 加载失败',
        total: prev.total,
        fromCache: true,
      );
      _notify();
      return;
    }

    // 🔴 await 期间用户可能已经退出消息页（页面 dispose 了本仓库）。
    // 此时再写状态、再 notify 就是「used after being disposed」。
    if (_disposed) return;

    // 失败与空严格分开：page.error 非空就是失败，绝不清空已有数据。
    _states[channelId] = ChannelState(
      items: page.items,
      loading: false,
      error: page.error,
      total: page.total,
      fromCache: page.fromCache,
    );
    _notify();
  }

  /// 后台增量写档成功后重读该源（只读档案，不再联网）。
  void _onSourceUpdated(String channelId) {
    if (_disposed) return;
    _fireAndForget(load(channelId, mode: FetchMode.archive, silent: true),
        '增量后重读 $channelId');
  }

  ChannelState stateOf(String channelId) =>
      _states[channelId] ?? const ChannelState();

  String? get activeChannelId => _activeChannelId;

  String get query => _query;

  Future<MessageDetail?> loadDetail(Message message) async {
    final source = _sources[message.sourceId];
    if (source == null) return null;
    return source.fetchDetail(message);
  }

  // ---------------- 页签 / 搜索 ----------------

  /// 切换当前页签。首次进入该源时才触发加载。
  void setActive(String channelId) {
    if (_activeChannelId == channelId) return;
    _activeChannelId = channelId;
    _notify();
    if (!_loaded.contains(channelId)) {
      _fireAndForget(load(channelId, mode: FetchMode.cached), '加载 $channelId');
    }
  }

  /// 搜索词变化 → **重载当前页签的源**（只在本地档案上过滤，不联网）。
  ///
  /// 搜索是仓库级能力，**与具体源无关** —— 重构前它只对教务处生效，
  /// 在资讯页签下搜索毫无反应。
  void onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (_disposed) return;
      _query = value;
      final id = _activeChannelId;
      if (id == null) return;
      _fireAndForget(load(id, mode: FetchMode.archive), '搜索重载 $id');
    });
  }

  /// 清空搜索条件并重载当前页签。
  void clearQuery() {
    _debounce?.cancel();
    _query = '';
    final id = _activeChannelId;
    if (id != null) {
      _fireAndForget(load(id, mode: FetchMode.archive), '清空搜索重载 $id');
    }
  }

  // ---------------- 已读 ----------------

  Future<void> initReadState() async {
    _readKeys = await MessageReadStorage.loadReadIds();
    _unreadBaseline = await MessageReadStorage.loadOrInitUnreadBaseline();
    _notify();
  }

  bool isRead(Message m) => _readKeys.contains(m.key);

  /// 是否显示未读红点。
  ///
  /// 教务处额外受「发布日期 ≥ 未读基准线」约束（[MessageChannel.usesUnreadBaseline]）
  /// —— 早于基准线的旧公告本就不是「新公告」，不该一直挂红点。
  /// 其余源只看已读与否。
  bool isUnread(Message m) {
    if (_readKeys.contains(m.key)) return false;
    if (!(_sources[m.sourceId]?.channel.usesUnreadBaseline ?? false)) return true;
    if (m.date.isEmpty || _unreadBaseline.isEmpty) return false;
    return m.date.compareTo(_unreadBaseline) >= 0;
  }

  Future<void> markRead(Message m) async {
    if (_readKeys.contains(m.key)) return;
    _readKeys = {..._readKeys, m.key};
    _notify();
    await MessageReadStorage.markRead(m.key);
  }

  Future<void> markUnread(Message m) async {
    if (!_readKeys.contains(m.key)) return;
    _readKeys = {..._readKeys}..remove(m.key);
    _notify();
    await MessageReadStorage.markUnread(m.key);
  }

  // ---------------- 生命周期 ----------------

  /// 本仓库是否已 [dispose]。
  ///
  /// 🔴 页面在 `dispose()` 里退订并 [dispose] 本仓库，而 [load] 是
  /// 「await 网络之后再 notify」—— 用户在刷新途中退出消息页就撞上
  /// `notifyListeners() called after dispose()`。
  bool _disposed = false;

  /// 所有通知的唯一出口：[dispose] 之后一律不发。
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 丢弃 future 而不 await，并把错误**记下来**。
  ///
  /// 🔴 不要用 `dart:async` 的 `unawaited`：它完全不处理错误，未捕获异常会
  /// 直接变成未处理的 zone 错误。这里显式 `debugPrint`，让「静默失败」
  /// 在日志里留痕 —— 静默是必要的（用户不该被后台任务打扰），但静默到
  /// 连开发者都看不见就成了黑洞。
  void _fireAndForget(Future<void> f, String what) {
    unawaited(f.then((_) {}, onError: (Object e, StackTrace s) {
      debugPrint('[MessageRepository] $what 失败：$e\n$s');
    }));
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    super.dispose();
  }
}
