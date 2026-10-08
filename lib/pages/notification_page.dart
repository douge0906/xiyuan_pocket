import 'package:flutter/material.dart';

import '../models/message.dart';
import '../services/message_channel_service.dart';
import '../services/message_repository.dart';
import '../services/message_source.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import 'message/channel_picker_dialog.dart';
import 'message/message_cards.dart';
import 'message/message_detail.dart';
import 'message/msg_style.dart';
import 'message_settings_page.dart';

/// 消息页 —— **一个页签 = 一个消息源**，所有源的渲染完全同一套代码。
///
/// 【本页只剩三件事】布局、把手势转成对 [MessageRepository] 的调用、
/// 把仓库状态画出来。加载、入档、预算、失败降级、已读、搜索全在仓库里 ——
/// 所以「新增一个消息来源」在这里是**零改动**（源注册好就自动出现页签）。
///
/// 重构前这里同时维护两套状态（教务处 6 个平铺字段 + 资讯的
/// `Map<channelId, _ChannelState>`）和两套渲染，同一件事写两遍必然漂 ——
/// 「搜索只对教务处生效」「改了同步条数对资讯无效」都是这么来的。
class NotificationPage extends StatefulWidget {
  const NotificationPage({super.key});

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage>
    with TickerProviderStateMixin {
  /// 页面**唯一**的状态与操作入口。
  final MessageRepository _repo = MessageRepository();

  /// 全部可订阅栏目（订阅面板用）。
  List<MessageChannel> _allChannels = const [];

  /// 用户当前订阅的栏目 id。
  Set<String> _subscribedIds = {};

  final TextEditingController _searchController = TextEditingController();

  /// 左右滑动切换页签；顺序与 [_tabs] 一致。
  final PageController _tabPageController = PageController();

  /// 搜索框里是否有内容（只用来决定后缀「清除」按钮显不显示）。
  String _searchQuery = '';

  /// 首屏装配中（读订阅集合 + 注册源）。
  bool _booting = true;

  // ---------------- 教程锚点（v2.0.0）----------------
  final GlobalKey _kTabsRow = GlobalKey();
  final GlobalKey _kAddChannelBtn = GlobalKey();

  // ---------------- 消息栏目样式（两套，默认纯白） ----------------
  String _messageStyle = StorageService.kMessageStylePlain;

  /// 当前页签（顺序 = 注册顺序 = chip 顺序 = PageView 页序）。
  List<MessageChannel> get _tabs =>
      _repo.registeredSources.map((s) => s.channel).toList();

  /// 当前选中的页签下标；找不到时回落 0。
  int get _currentTabIndex {
    final tabs = _tabs;
    final id = _repo.activeChannelId;
    if (id == null) return 0;
    final i = tabs.indexWhere((t) => t.id == id);
    return i < 0 ? 0 : i;
  }

  @override
  void initState() {
    super.initState();
    _loadMessageStyle();
    // 发布-订阅是**两端**契约：只写 notifyListeners() 而没人订阅，
    // 等于没接线（历史上「搜索完全失效」就是这么来的）。
    _repo.addListener(_onRepoChanged);
    _boot();
  }

  void _onRepoChanged() {
    if (mounted) setState(() {});
  }

  /// 首屏：读已读状态 → 读订阅集合 → 注册源 → 选中第一个页签。
  Future<void> _boot() async {
    await _repo.initReadState();
    final subscribed = await MessageChannelService.loadSubscribed();
    await _repo.registerSources(subscribedIds: subscribed);
    if (!mounted) return;
    setState(() {
      _allChannels = MessageChannelService.allChannels;
      _subscribedIds = subscribed;
      _booting = false;
    });
    final tabs = _tabs;
    if (tabs.isNotEmpty) _repo.setActive(tabs.first.id);
  }

  @override
  void dispose() {
    _repo.removeListener(_onRepoChanged);
    _searchController.dispose();
    _tabPageController.dispose();
    _repo.dispose();
    super.dispose();
  }

  // ---------------- 样式 ----------------

  Future<void> _loadMessageStyle() async {
    final s = await StorageService.loadMessageStyle();
    MsgStyle.card = s == StorageService.kMessageStyleCard;
    if (!mounted || s == _messageStyle) return;
    setState(() => _messageStyle = s);
  }

  /// 右上角齿轮 → **独立设置页**；返回时无条件重读样式，立即生效。
  Future<void> _openSettings() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MessageSettingsPage(repository: _repo),
    ));
    await _loadMessageStyle();
    if (!mounted) return;
    setState(() {});
  }

  // ---------------- 订阅 ----------------

  /// 打开订阅面板；用户点「完成」才落盘并重注册源。
  Future<void> _showChannelPicker() async {
    if (_allChannels.isEmpty) {
      _allChannels = MessageChannelService.allChannels;
    }
    final picked = await showChannelPickerDialog(
      context,
      channels: _allChannels,
      selected: _subscribedIds,
    );
    if (picked == null || !mounted) return;

    await MessageChannelService.saveSubscribed(picked);
    // 重新注册：被取消的源整体撤下，新勾上的源立刻可用。
    await _repo.registerSources(subscribedIds: picked);
    if (!mounted) return;
    setState(() => _subscribedIds = picked);
    _syncActiveTab();
  }

  /// 让「当前页签」始终有效：被取消订阅后落到第一个栏目。
  void _syncActiveTab() {
    final tabs = _tabs;
    if (tabs.isEmpty) {
      _repo.setActive('');
      return;
    }
    final active = _repo.activeChannelId;
    if (active != null && tabs.any((t) => t.id == active)) return;
    _repo.setActive(tabs.first.id);
    if (_tabPageController.hasClients) _tabPageController.jumpToPage(0);
  }

  // ---------------- 页签切换 ----------------

  void _switchTo(int i, {bool animate = false}) {
    final tabs = _tabs;
    if (i < 0 || i >= tabs.length) return;
    _repo.setActive(tabs[i].id);
    if (animate && _tabPageController.hasClients) {
      _tabPageController.animateToPage(i,
          duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    }
  }

  // ---------------- 搜索 ----------------

  void _onSearchChanged(String value) {
    setState(() => _searchQuery = value);
    // 防抖与「只重载当前页签」都在仓库里（搜索是仓库级能力，与具体源无关）。
    _repo.onQueryChanged(value);
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _searchQuery = '');
    _repo.clearQuery();
  }

  // ---------------- 详情 ----------------

  Future<void> _openDetail(MessageChannel ch, Message m) async {
    // 先标已读再进详情：仓库会通知，列表红点立刻消失
    // （历史上这里只写存储、不更新内存，返回后红点还在）。
    await _repo.markRead(m);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MessageDetailPage(
        message: m,
        sourceName: ch.name,
        loader: _repo.loadDetail,
      ),
    ));
  }

  // ---------------- 视图 ----------------

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '消息通知',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _booting ? '加载中…' : '共 ${_tabs.length} 个栏目',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Colors.grey.shade500,
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: _openSettings,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: context.borderColor),
              ),
              child: Icon(
                Icons.settings_outlined,
                size: 20,
                color: Colors.grey.shade600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChips() {
    final tabs = _tabs;
    return SizedBox(
      key: _kTabsRow,
      height: 44,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        scrollDirection: Axis.horizontal,
        // 末位固定是「＋」：已订阅栏目插在它之前，故加号始终在最右。
        itemCount: tabs.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          if (index >= tabs.length) return _buildAddChannelButton();
          final t = tabs[index];
          final selected = index == _currentTabIndex;
          return _chipShell(
            selected: selected,
            // 点 chip 时也让 PageView 滑过去，两者永远同步
            onTap: () {
              if (selected) return;
              _switchTo(index, animate: true);
            },
            label: t.name,
          );
        },
      ),
    );
  }

  /// 统一的 chip 外壳（所有栏目共用，保证视觉一致）。
  Widget _chipShell({
    required bool selected,
    required VoidCallback onTap,
    required String label,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      child: FilterChip(
        selected: selected,
        showCheckmark: false,
        backgroundColor: Theme.of(context).cardColor,
        selectedColor: AppTheme.primaryColor,
        side: BorderSide(color: context.borderColor),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        label: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? Colors.white : Colors.grey.shade700,
          ),
        ),
        onSelected: (_) => onTap(),
      ),
    );
  }

  /// 「＋」：打开订阅面板。
  Widget _buildAddChannelButton() {
    return Center(
      key: _kAddChannelBtn,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: _showChannelPicker,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              shape: BoxShape.circle,
              border: Border.all(color: context.borderColor),
            ),
            child: Icon(Icons.add_rounded, size: 19, color: Colors.grey.shade600),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBox(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: context.borderColor),
        ),
        child: TextField(
          controller: _searchController,
          onChanged: _onSearchChanged,
          style: TextStyle(fontSize: 14, color: context.textPrimary),
          decoration: InputDecoration(
            isDense: true,
            hintText: '搜索标题',
            hintStyle: TextStyle(fontSize: 14, color: Colors.grey.shade400),
            prefixIcon:
                Icon(Icons.search_rounded, size: 20, color: Colors.grey.shade400),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.close_rounded,
                        size: 18, color: Colors.grey.shade500),
                    onPressed: _clearSearch,
                  )
                : null,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
    );
  }

  /// 单个页签的内容区。
  ///
  /// 三态严格区分：加载中 / 失败（[ChannelState.error] 非空）/ 空。
  /// 🔴 **绝不能用 `items.isEmpty` 判断失败** —— 那是本项目发作次数最多的 bug。
  Widget _buildChannelContent(MessageChannel ch) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final state = _repo.stateOf(ch.id);

    if (state.loading && state.items.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (state.error != null && state.items.isEmpty) {
      return _channelError(ch, state.error!, isDark);
    }
    if (state.items.isEmpty) {
      return _channelEmpty(ch, isDark, searching: _searchQuery.trim().isNotEmpty);
    }

    return RefreshIndicator(
      color: AppTheme.primaryColor,
      // 下拉刷新 = **增量**（只问一句「有没有新的」），不是全量重爬。
      onRefresh: () => _repo.load(ch.id, mode: FetchMode.incremental),
      child: ListView.separated(
        // 内容不足一屏时也要能下拉刷新
        physics: const AlwaysScrollableScrollPhysics(),
        // 无缝白底：左右不留页面边距（行内自带 20），分割线贯通到屏幕两侧
        padding: MsgStyle.card
            ? const EdgeInsets.fromLTRB(14, 10, 14, 24)
            : const EdgeInsets.fromLTRB(0, 4, 0, 24),
        itemCount: state.items.length + 1,
        separatorBuilder: (_, i) => i < state.items.length - 1
            ? (MsgStyle.card
                ? const SizedBox.shrink()
                : Divider(height: 1, color: context.borderColor))
            : const SizedBox.shrink(),
        itemBuilder: (ctx, i) {
          // 末尾一行：已加载条数（不再有「加载更多」，也就没有分页状态）
          if (i == state.items.length) {
            return _loadedCountLabel(state.items.length);
          }
          final m = state.items[i];
          return MessageCard(
            message: m,
            isUnread: _repo.isUnread(m),
            onTap: () => _openDetail(ch, m),
          );
        },
      ),
    );
  }

  /// 「已加载 N 条」——取代原先的「加载更多… / 已显示全部公告」。
  ///
  /// 列表是懒渲染的（一次只画十来行），200 条和 400 条的渲染成本几乎一样，
  /// 所以不做上滑分页；用户只需要知道「现在手里有多少条」以及
  /// 「要更多就去设置里调大」。
  Widget _loadedCountLabel(int n) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            '已加载 $n 条',
            style: TextStyle(fontSize: 12.5, color: Colors.grey.shade400),
          ),
        ),
      );

  Widget _channelEmpty(MessageChannel ch, bool isDark,
          {bool searching = false}) =>
      Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                searching ? Icons.search_off_rounded : Icons.inbox_outlined,
                size: searching ? 64 : 52,
                color: isDark ? Colors.grey.shade700 : Colors.grey.shade300,
              ),
              const SizedBox(height: 12),
              Text(
                searching ? '未找到相关标题' : '暂无${ch.name}内容',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                searching ? '换个关键词试试' : '下拉可刷新',
                style: TextStyle(
                  fontSize: 12.5,
                  color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _channelError(MessageChannel ch, String msg, bool isDark) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.wifi_off_outlined,
                  size: 48,
                  color: isDark ? Colors.grey.shade700 : Colors.grey.shade300),
              const SizedBox(height: 12),
              Text(
                msg,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13.5, color: Colors.grey.shade500),
              ),
              const SizedBox(height: 14),
              ElevatedButton.icon(
                onPressed: () =>
                    _repo.load(ch.id, mode: FetchMode.incremental),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );

  /// 一个栏目都没订阅时的空态 —— 必须显式给出，否则页面只剩一排「＋」。
  Widget _noChannels(bool isDark) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.inbox_outlined,
                  size: 56,
                  color: isDark ? Colors.grey.shade700 : Colors.grey.shade300),
              const SizedBox(height: 14),
              Text(
                '还没有订阅任何栏目',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '点右上角「＋」挑选想看的栏目',
                style: TextStyle(
                  fontSize: 12.5,
                  color: isDark ? Colors.grey.shade600 : Colors.grey.shade400,
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _showChannelPicker,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('订阅栏目'),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tabs = _tabs;

    return Scaffold(
      // 无缝白底：消息页整体铺白，行与行之间只靠 1px 灰线分隔。
      backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            const SizedBox(height: 12),
            _buildFilterChips(),
            _buildSearchBox(isDark),
            const SizedBox(height: 4),
            Expanded(
              child: _booting
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2.5))
                  : tabs.isEmpty
                      ? _noChannels(isDark)
                      : PageView.builder(
                          controller: _tabPageController,
                          itemCount: tabs.length,
                          onPageChanged: (i) => _switchTo(i),
                          itemBuilder: (ctx, i) =>
                              _buildChannelContent(tabs[i]),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
