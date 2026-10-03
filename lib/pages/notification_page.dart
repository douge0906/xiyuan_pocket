import 'dart:async';
import 'package:flutter/material.dart';
import '../models/notice_channel.dart';
import '../models/message_read_storage.dart';
import '../models/school_notice.dart';
import '../services/notice_channel_service.dart';
import '../services/storage_service.dart';
import '../services/school_notice_service.dart';
import 'message/msg_style.dart';
import 'message/message_cards.dart';
import 'school_notice_detail_page.dart';
import '../theme/app_theme.dart';
import '../services/campus_info_service.dart';
import 'campus_info_detail_page.dart';

class NotificationPage extends StatefulWidget {
  const NotificationPage({super.key});

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage>
    with TickerProviderStateMixin {


  // ---------------- 消息渠道（v1.5.1）----------------
  // 可订阅渠道目录（内置清单）+ 用户本地勾选结果。
  List<NoticeChannel> _allChannels = [];
  Set<String> _subscribedIds = {};

  // ---------------- 功能教程锚点（v2.0.0）----------------
  final GlobalKey _kTabsRow = GlobalKey();
  final GlobalKey _kAddChannelBtn = GlobalKey();
  String? _activeChannelId; // 非空表示当前正查看某个已订阅渠道

  /// 各渠道的资讯列表状态（按渠道 id 缓存，切来切去不重复请求）。
  final Map<String, _ChannelState> _channelStates = {};

  Set<String> _readIds = {};

  // 学校公告（独立系统）
  List<SchoolNotice> _notices = [];
  bool _isLoadingNotices = true;
  bool _loadingMore = false;
  int _noticeTotal = -1;
  String? _noticeError;
  static const int _pageSize = 20;


  // 搜索（按标题模糊匹配当前列表）
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _debounce;

  // 新增公告红点基准线（天级）
  String _unreadBaseline = '';

  // 上拉加载
  final ScrollController _scrollController = ScrollController();

  /// 左右滑动切换列表（v1.6.0）。页面顺序与 chip 顺序一致（见 _allTabs）。
  final PageController _tabPageController = PageController(initialPage: 1);

  // ---------------- 消息栏目样式（两套，默认纯白） ----------------
  String _messageStyle = StorageService.kMessageStylePlain;

  Future<void> _loadMessageStyle() async {
    final s = await StorageService.loadMessageStyle();
    MsgStyle.card = s == StorageService.kMessageStyleCard;
    if (!mounted || s == _messageStyle) return;
    setState(() => _messageStyle = s);
  }

  /// 切换栏目样式：两套随时互换，立即生效并持久化。
  Future<void> _openStylePicker() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            const Text('消息栏目样式',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            _styleOption(ctx, StorageService.kMessageStylePlain, '纯白列表',
                '无卡片边框，行与行之间一条细线（默认）'),
            _styleOption(ctx, StorageService.kMessageStyleCard, '圆角盒子',
                '每条消息一个白色圆角卡片'),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (picked == null || picked == _messageStyle) return;
    MsgStyle.card = picked == StorageService.kMessageStyleCard;
    setState(() => _messageStyle = picked);
    await StorageService.saveMessageStyle(picked);
  }

  Widget _styleOption(BuildContext ctx, String value, String title,
      String subtitle) {
    final on = _messageStyle == value;
    return ListTile(
      onTap: () => Navigator.of(ctx).pop(value),
      title: Text(title,
          style: TextStyle(
              fontSize: 14.5,
              fontWeight: on ? FontWeight.w600 : FontWeight.normal)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: on
          ? Icon(Icons.check_rounded, color: AppTheme.primaryColor, size: 20)
          : null,
    );
  }

  @override
  void initState() {
    super.initState();
    _loadMessageStyle();
    _scrollController.addListener(_onScroll);
    _loadReadIds();
    _initSchoolNotices();
    _loadChannels();
  }

  /// 加载可订阅渠道：读本地缓存 + 订阅集合（缓存命中则不联网）。
  Future<void> _loadChannels() async {
    final catalog = await NoticeChannelService.loadCatalog();
    final subscribed = await NoticeChannelService.loadSubscribed();
    if (!mounted) return;
    setState(() {
      _allChannels = catalog.channels;
      _subscribedIds = subscribed;
    });
  }

  /// 当前已订阅的渠道（按目录顺序）。
  List<NoticeChannel> get _subscribedChannels =>
      _allChannels.where((c) => _subscribedIds.contains(c.id)).toList();

  /// 打开渠道勾选面板。
  Future<void> _showChannelPicker() async {
    if (_allChannels.isEmpty) {
      // 目录还没拉到时，尝试强制刷新一次
      final catalog = await NoticeChannelService.loadCatalog(force: true);
      if (!mounted) return;
      setState(() => _allChannels = catalog.channels);
      if (_allChannels.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂无可订阅的渠道，请稍后再试')),
        );
        return;
      }
    }

    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ChannelPickerSheet(
        channels: _allChannels,
        initial: _subscribedIds,
      ),
    );
    if (picked == null) return;

    await NoticeChannelService.saveSubscribed(picked);
    if (!mounted) return;
    setState(() {
      _subscribedIds = picked;
      // 若当前查看的渠道被取消勾选，退回学校公告
      if (_activeChannelId != null && !picked.contains(_activeChannelId)) {
        _activeChannelId = null;
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    _tabPageController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loadingMore || _isLoadingNotices) return;
    if (_noticeTotal >= 0 && _notices.length >= _noticeTotal) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 300) {
      _loadMoreNotices();
    }
  }

  Future<void> _loadReadIds() async {
    final ids = await MessageReadStorage.loadReadIds();
    if (mounted) setState(() => _readIds = ids);
  }

  // ---------------- 学校公告 ----------------

  /// 先显示本地缓存，再后台刷新（"先显示后加载"）。
  Future<void> _initSchoolNotices() async {
    final baseline = await SchoolNoticeService.loadOrInitUnreadBaseline();
    if (mounted) setState(() => _unreadBaseline = baseline);
    final cached = await SchoolNoticeService.loadCachedList();
    if (cached.isNotEmpty && mounted) {
      setState(() {
        _notices = cached;
        _isLoadingNotices = false;
      });
    }
    await _refreshNotices(showLoading: cached.isEmpty);
  }

  /// 新增公告 = 发布日期不早于基准线；未读的新增公告标红点。
  bool _isUnreadNewNotice(SchoolNotice notice) {
    if (_readIds.contains('school_${notice.id}')) return false;
    if (notice.date.isEmpty || _unreadBaseline.isEmpty) return false;
    return notice.date.compareTo(_unreadBaseline) >= 0;
  }

  Future<void> _refreshNotices({bool showLoading = false}) async {
    if (mounted && showLoading) {
      setState(() {
        _isLoadingNotices = true;
        _noticeError = null;
      });
    }
    try {
      final result = await SchoolNoticeService.fetchList(
        limit: _pageSize,
        offset: 0,
        q: _searchQuery,
      );
      if (!mounted) return;
      final searching = _searchQuery.trim().isNotEmpty;
      // ⚠️ fetchList 抓取失败时**不抛异常，直接返回空列表**（见 school_notice_service）。
      // 若不判断就把空列表写回 state / 缓存，会清掉内置快照与上次结果，
      // 用户下次打开消息页只能看到转圈。此处保留已有内容。
      if (!searching && result.items.isEmpty && _notices.isNotEmpty) {
        setState(() => _isLoadingNotices = false);
        return;
      }
      // 缓存仅保存无搜索时的首页，且只在有内容时写（避免覆盖成空）
      if (!searching && result.items.isNotEmpty) {
        SchoolNoticeService.cacheList(result.items);
      }
      setState(() {
        _notices = result.items;
        _noticeTotal = result.total;
        _isLoadingNotices = false;
        _noticeError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingNotices = false;
        // 有缓存数据时静默失败（继续显示旧数据）
        _noticeError = _notices.isEmpty
            ? e.toString().replaceFirst('Exception: ', '')
            : null;
      });
    }
  }

  Future<void> _loadMoreNotices() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final result = await SchoolNoticeService.fetchList(
        limit: _pageSize,
        offset: _notices.length,
        q: _searchQuery,
      );
      if (!mounted) return;
      setState(() {
        _notices.addAll(result.items);
        _noticeTotal = result.total;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() => _searchQuery = value);
      if (true) {
        _refreshNotices(showLoading: true);
      }
      // v2.4.0：渠道内容也要能搜 —— 原来只处理「教务处」分类，
      // 在渠道页输入关键词毫无反应（用户反馈「搜索仅限学校公告」）。
      final cid = _activeChannelId;
      if (cid != null) _loadChannel(cid, force: true);
    });
  }

  void _onNoticeTap(SchoolNotice notice) async {
    final readKey = 'school_${notice.id}';
    await MessageReadStorage.markRead(readKey);
    if (!mounted) return;
    // v2.4.0 修复：此前只写存储、未更新内存 `_readIds` 也未 setState，
    // 导致看完公告返回列表时红点依旧（已读红点不消失）。
    setState(() => _readIds.add(readKey));
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SchoolNoticeDetailPage(notice: notice),
      ),
    );
  }

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
                    '系统公告 · 教务处',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
          ),
          GestureDetector(
            // v1.1.0：消息设置 = 切换栏目样式（纯白列表 / 圆角盒子）
            onTap: _openStylePicker,
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
    final tabs = _allTabs;
    return SizedBox(
        key: _kTabsRow, // v2.0.0 教程高亮锚点
      height: 44,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        scrollDirection: Axis.horizontal,
        // 末位固定是「＋」：已订阅渠道插在它之前，故加号始终在最右（用户要求）。
        itemCount: tabs.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          if (index >= tabs.length) return _buildAddChannelButton();
          final t = tabs[index];
          final selected = index == _currentTabIndex;
          return _chipShell(
            selected: selected,
            onTap: () {
              if (selected) return;
              _switchTo(index);
              if (_tabPageController.hasClients) {
                _tabPageController.animateToPage(index,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOut);
              }
            },
            // 内置页签只剩「学校公告」，渠道页签用渠道名
            label: t.channel?.name ?? '教务处',
          );
        },
      ),
    );
  }

  /// 统一的 chip 外壳（内置分类与渠道共用，保证视觉一致）。
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

  /// 「＋」：打开渠道勾选面板。
  Widget _buildAddChannelButton() {
    return Center(
      key: _kAddChannelBtn, // v2.0.0 教程高亮锚点
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


  // ---------------- 列表左右滑动切换（v1.6.0）----------------
  // 左右滑动在「学校公告 / 已订阅渠道」之间翻页切换。
  //
  // 设计要点：**chip 顺序与页面顺序用同一套索引**（见 _allTabs），
  // 这样「点 chip」和「左右滑」天然对齐，不会出现错位。

  /// 全部页签（顺序即 chip 顺序、也是 PageView 的页面顺序）。
  /// 索引 0 固定为学校公告（教务处），其后是已订阅的校园资讯渠道。
  /// 页签 = 学校公告（教务处直抓）+ 已订阅的校园资讯渠道。
  List<_NoticeTab> get _allTabs => [
        const _NoticeTab(isSchool: true),
        for (final c in _subscribedChannels) _NoticeTab(channel: c),
      ];

  /// 当前选中的页签下标；找不到时回落到 0（学校公告）。
  int get _currentTabIndex {
    final tabs = _allTabs;
    final i = tabs.indexWhere((t) =>
        _activeChannelId != null
            ? t.channel?.id == _activeChannelId
            : t.isSchool);
    return i < 0 ? 0 : i;
  }

  /// 切换到指定页签（chip 点击与 PageView 回调共用）。
  void _switchTo(int i) {
    final tabs = _allTabs;
    if (i < 0 || i >= tabs.length) return;
    final t = tabs[i];
    setState(() {
      if (t.channel != null) {
        _activeChannelId = t.channel!.id;
      } else {
        _activeChannelId = null;
      }
    });
    // 学校公告列表依赖 _scrollController，仅在切到它时复位
    if (t.isSchool && _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

/// 渠道内容区（v2.3.0）：显示该渠道的真实资讯列表。
  ///
  /// 三态：加载中（骨架/转圈）→ 列表 / 空态 / 失败可重试。
  /// 支持下拉刷新（强制走网络）；点击条目进入详情。
  Widget _buildChannelContent(NoticeChannel ch) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final state = _channelStates[ch.id];

    // 首次进入该渠道：触发加载
    if (state == null) {
      _loadChannel(ch.id);
      return const Center(
          child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (state.loading && state.items.isEmpty) {
      return const Center(
          child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (state.error != null && state.items.isEmpty) {
      return _channelError(ch, state.error!, isDark);
    }
    if (state.items.isEmpty) {
      return _channelEmpty(ch, isDark);
    }

    return RefreshIndicator(
      color: AppTheme.primaryColor,
      onRefresh: () => _loadChannel(ch.id, force: true),
      child: ListView.separated(
        // v1.1.0 无缝白底：左右不留页面边距（行内自带 20），分割线贯通到屏幕两侧
        padding: MsgStyle.card
            ? const EdgeInsets.fromLTRB(14, 10, 14, 24)
            : const EdgeInsets.fromLTRB(0, 4, 0, 24),
        itemCount: state.items.length,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          color: context.borderColor,
        ),
        itemBuilder: (ctx, i) {
          final it = state.items[i];
          return InkWell(
            onTap: () => _openCampusInfo(ch, it),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          it.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.45,
                            fontWeight: FontWeight.w500,
                            color: context.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          it.date,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? Colors.grey.shade600
                                : Colors.grey.shade400,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right,
                      size: 18,
                      color: isDark
                          ? Colors.grey.shade700
                          : Colors.grey.shade300),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 加载某渠道的资讯（[force] 为 true 时跳过本地缓存）。
  Future<void> _loadChannel(String columnId, {bool force = false}) async {
    setState(() {
      _channelStates[columnId] =
          (_channelStates[columnId] ?? const _ChannelState()).copyWith(
        loading: true,
        error: null,
      );
    });
    try {
      final items = await CampusInfoService.fetchList(columnId,
          force: force, q: _searchQuery);
      if (!mounted) return;
      setState(() {
        _channelStates[columnId] = _ChannelState(items: items, loading: false);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _channelStates[columnId] = _ChannelState(
          items: _channelStates[columnId]?.items ?? const [],
          loading: false,
          error: '内容加载失败，请检查网络',
        );
      });
    }
  }

  /// 打开资讯详情（**整页**，与「教务处公告详情」观感一致）。
  ///
  /// v2.4.0：原来用 showModalBottomSheet（上滑弹层），用户反馈「上滑式丑陋」，
  /// 且与学校公告详情不一致 → 改为整页 push。
  Future<void> _openCampusInfo(NoticeChannel ch, CampusInfoItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CampusInfoDetailPage(
          columnId: ch.id,
          columnName: ch.name,
          item: item,
        ),
      ),
    );
  }

  Widget _channelEmpty(NoticeChannel ch, bool isDark) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.inbox_outlined,
                  size: 52,
                  color: isDark ? Colors.grey.shade700 : Colors.grey.shade300),
              const SizedBox(height: 12),
              Text(
                '暂无${ch.name}内容',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '下拉可刷新',
                style: TextStyle(
                    fontSize: 12.5,
                    color: isDark
                        ? Colors.grey.shade600
                        : Colors.grey.shade400),
              ),
            ],
          ),
        ),
      );

  Widget _channelError(NoticeChannel ch, String msg, bool isDark) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.wifi_off_outlined,
                  size: 48,
                  color: isDark ? Colors.grey.shade700 : Colors.grey.shade300),
              const SizedBox(height: 12),
              Text(msg,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13.5,
                      color: isDark
                          ? Colors.grey.shade500
                          : Colors.grey.shade500)),
              const SizedBox(height: 14),
              ElevatedButton.icon(
                onPressed: () => _loadChannel(ch.id, force: true),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );

  Widget _buildSearchBox(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: context.borderColor,
          ),
        ),
        child: TextField(
          controller: _searchController,
          onChanged: _onSearchChanged,
          style: TextStyle(
            fontSize: 14,
            color: context.textPrimary,
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: '搜索公告标题',
            hintStyle: TextStyle(fontSize: 14, color: Colors.grey.shade400),
            prefixIcon: Icon(Icons.search_rounded, size: 20, color: Colors.grey.shade400),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.close_rounded, size: 18, color: Colors.grey.shade500),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                      _refreshNotices(showLoading: true);
                    },
                  )
                : null,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
    );
  }

  Widget _buildSchoolNotices() {
    if (_isLoadingNotices) {
      return const Center(
          child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_noticeError != null && _notices.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.wifi_off_outlined, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              _noticeError!,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _refreshNotices(showLoading: true),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重新加载'),
            ),
          ],
        ),
      );
    }
    if (_notices.isEmpty) {
      final searching = _searchQuery.trim().isNotEmpty;
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              searching ? Icons.search_off_rounded : Icons.inbox_outlined,
              size: 64,
              color: Colors.grey.shade300,
            ),
            const SizedBox(height: 16),
            Text(
              searching ? '未找到相关公告' : '暂无公告',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
            ),
          ],
        ),
      );
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return RefreshIndicator(
      onRefresh: () => _refreshNotices(),
      color: AppTheme.textPrimaryLight,
      child: ListView.separated(
        controller: _scrollController,
        // v1.1.0 无缝白底：左右不留页面边距（行内自带 20），分割线贯通到屏幕两侧
        padding: MsgStyle.card
            ? const EdgeInsets.fromLTRB(14, 10, 14, 24)
            : const EdgeInsets.fromLTRB(0, 4, 0, 24),
        itemCount: _notices.length + 1,
        separatorBuilder: (_, i) => i < _notices.length - 1
            ? Divider(height: 1, color: context.borderColor)
            : const SizedBox.shrink(),
        itemBuilder: (context, index) {
          if (index == _notices.length) {
            final endReached =
                _noticeTotal >= 0 && _notices.length >= _noticeTotal;
            if (endReached && _notices.length > _pageSize) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text(
                    '已显示全部公告',
                    style: TextStyle(fontSize: 12.5, color: Colors.grey.shade400),
                  ),
                ),
              );
            }
            if (endReached) return const SizedBox(height: 8);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: _loadingMore
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        '加载更多…',
                        style: TextStyle(
                            fontSize: 12.5, color: Colors.grey.shade400),
                      ),
              ),
            );
          }
          final notice = _notices[index];
          return SchoolNoticeCard(
            notice: notice,
            index: index,
            isDark: isDark,
            isRead: !_isUnreadNewNotice(notice),
            onTap: () => _onNoticeTap(notice),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      // v1.1.0 无缝白底：消息页整体铺白（用户要求两版统一为连续白底，
      // 行与行之间仅靠 1px 灰线分隔，不再有卡片缝里露出的浅灰）。
      backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            const SizedBox(height: 12),
            _buildFilterChips(),
            _buildSearchBox(isDark),
            const SizedBox(height: 4),
            // 左右滑动切换列表（v1.6.0）：页面顺序 = _allTabs 顺序。
            Expanded(
              child: PageView.builder(
                controller: _tabPageController,
                itemCount: _allTabs.length,
                onPageChanged: (i) => _switchTo(i),
                itemBuilder: (ctx, i) {
                  final t = _allTabs[i];
                  if (t.channel != null) {
                    return _buildChannelContent(t.channel!);
                  }
                  return _buildSchoolNotices();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
/// 渠道勾选面板（多选）。
///
/// 交互：勾选 / 取消勾选，点「完成」回传新的订阅集合。
/// 未接通数据源的渠道标「筹备中」，但仍允许勾选 —— 上线后自动出现内容，
/// 这样用户不必等到上线才想起去勾。
class _ChannelPickerSheet extends StatefulWidget {
  final List<NoticeChannel> channels;
  final Set<String> initial;

  const _ChannelPickerSheet({required this.channels, required this.initial});

  @override
  State<_ChannelPickerSheet> createState() => _ChannelPickerSheetState();
}

class _ChannelPickerSheetState extends State<_ChannelPickerSheet> {
  late Set<String> _sel;

  @override
  void initState() {
    super.initState();
    _sel = Set<String>.from(widget.initial);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 14,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '订阅消息渠道',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: context.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '勾选后该渠道会出现在消息页顶部，内容上线后自动显示',
            style: TextStyle(
              fontSize: 12.5,
              color: isDark ? Colors.grey.shade500 : Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: widget.channels.length,
              itemBuilder: (ctx, i) {
                final ch = widget.channels[i];
                final on = _sel.contains(ch.id);
                return InkWell(
                  onTap: () => setState(() {
                    if (on) {
                      _sel.remove(ch.id);
                    } else {
                      _sel.add(ch.id);
                    }
                  }),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      children: [
                        // 自绘复选框：与页面风格一致，不依赖平台样式
                        Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: on ? AppTheme.primaryColor : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: on
                                  ? AppTheme.textPrimaryLight
                                  : (isDark ? Colors.grey.shade600 : Colors.grey.shade300),
                              width: 1.5,
                            ),
                          ),
                          child: on
                              ? const Icon(Icons.check_rounded,
                                  size: 15, color: Colors.white)
                              : null,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                ch.name,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: context.textPrimary,
                                ),
                              ),
                              if (ch.desc.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  ch.desc,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: isDark
                                        ? Colors.grey.shade500
                                        : Colors.grey.shade500,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (!ch.isReady)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF3A3A2A)
                                  : const Color(0xFFFAEEDA),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Text(
                              '筹备中',
                              style: TextStyle(
                                  fontSize: 11, color: Color(0xFF854F0B)),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).pop(_sel),
              child: const Text('完成'),
            ),
          ),
        ],
      ),
    );
  }
}
/// 消息页的一个页签：要么是内置的「学校公告」，要么是已订阅的校园资讯渠道。
///
/// 用它把「chip 顺序」与「PageView 页面顺序」统一到同一个列表（见 `_allTabs`），
/// 两者共用索引后，点 chip 与左右滑动天然对齐。
///
/// 开源版说明：原设计用 `MessageCategory` 枚举区分内置分类（系统公告 / 学校公告）。
/// 移除系统公告后**内置分类只剩学校公告一个**，枚举失去意义 → 退化为布尔
/// [isSchool]，顺便解除了对已删除的 `message_model.dart` 的依赖。
class _NoticeTab {
  /// 是否是内置的「学校公告」页签（与 [channel] 二选一）。
  final bool isSchool;

  /// 已订阅渠道（与 [isSchool] 二选一）。
  final NoticeChannel? channel;

  const _NoticeTab({this.isSchool = false, this.channel});
}


/// 单渠道的加载状态（v2.3.0）。
class _ChannelState {
  final List<CampusInfoItem> items;
  final bool loading;
  final String? error;

  const _ChannelState({
    this.items = const [],
    this.loading = false,
    this.error,
  });

  _ChannelState copyWith({
    List<CampusInfoItem>? items,
    bool? loading,
    String? error,
  }) =>
      _ChannelState(
        items: items ?? this.items,
        loading: loading ?? this.loading,
        error: error,
      );
}
