import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/dorm_service.dart';
import '../services/net_mode.dart';
import '../theme/app_theme.dart';

/// 充值页（官方 H5，**App 内置**）。
///
/// 为什么不用系统浏览器：校外跳的是 WebVPN 网关地址，浏览器里没有 App 的登录态，
/// 会先要求手动登录一次；两块式「先开登录页再开充值页」在 Android 上还会互相顶掉
/// （2026-10-26 实测「无法进入页面」）。
///
/// 做法：把 App 已持有的**网关 cookie 注入 WebView**，然后直接加载充值页 ——
/// 不跳浏览器、不用二次登录、校内校外同一套逻辑。
class RechargeWebViewPage extends StatefulWidget {
  const RechargeWebViewPage({
    super.key,
    required this.url,
    this.warmupUrl,
    this.title = '充值',
  });

  /// 最终要展示的页面。
  final String url;

  /// 需要**先访问**的中间页（一卡通用它建立平台会话，之后才能进充值页）。
  /// 加载完成后会自动再跳到 [url]。
  final String? warmupUrl;

  final String title;

  @override
  State<RechargeWebViewPage> createState() => _RechargeWebViewPageState();
}

class _RechargeWebViewPageState extends State<RechargeWebViewPage> {
  late final WebViewController _ctl;
  bool _loading = true;

  /// 首次加载：显示居中的简约 loading（后续跳转只用顶部细条，不打断视线）。
  bool _firstLoad = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted && !_loading) setState(() => _loading = true);
          },
          onPageFinished: (_) async {
            final pending = _pendingUrl;
            if (pending != null) {
              _pendingUrl = null;
              // 中转页可能自己就跳到了目标页，那就别再多刷一次
              final cur = (await _ctl.currentUrl()) ?? '';
              if (cur.contains('cardRecharge')) {
                if (mounted) {
                  setState(() {
                    _loading = false;
                    _firstLoad = false;
                  });
                }
              } else {
                await _ctl.loadRequest(Uri.parse(pending));
              }
              return;
            }
            if (mounted) {
              setState(() {
                _loading = false;
                _firstLoad = false;
              });
            }
          },
          onWebResourceError: (e) {
            // 只有主框架加载失败才算错误（子资源失败很常见，不打扰用户）
            if (e.isForMainFrame == true && mounted) {
              setState(() {
                _loading = false;
                _error = e.description;
              });
            }
          },
        ),
      );
    _prepare();
  }

  Future<void> _prepare() async {
    // 校外：把网关登录态注入 WebView，页面直接就是已登录状态
    if (NetMode.current == CampusNetMode.webvpn) {
      final cookies = DormService.vpnCookies;
      if (cookies.isNotEmpty) {
        final cm = WebViewCookieManager();
        for (final e in cookies.entries) {
          try {
            await cm.setCookie(WebViewCookie(
              name: e.key,
              value: e.value,
              domain: 'webvpn.cwxu.edu.cn',
              path: '/',
            ));
          } catch (_) {
            // 单个 cookie 失败不致命：页面会退化成要求登录
          }
        }
      }
    }
    if (!mounted) return;
    try {
      final warm = widget.warmupUrl;
      if (warm != null && warm.isNotEmpty) {
        // 两步走：先让平台用 ticket 建会话，落点由我们自己再定一次
        _pendingUrl = widget.url;
        await _ctl.loadRequest(Uri.parse(warm));
      } else {
        await _ctl.loadRequest(Uri.parse(widget.url));
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// warmup 完成后要跳的主地址（null = 直接加载的就是主地址）。
  String? _pendingUrl;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      // 顶栏做窄：WebView 页面要尽量把高度留给内容
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(46),
        child: AppBar(
          toolbarHeight: 46,
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: context.scaffoldColor,
          surfaceTintColor: Colors.transparent,
          centerTitle: true,
          shape: Border(bottom: BorderSide(color: context.borderColor)),
          titleSpacing: 0,
          title: Text(widget.title,
              style: TextStyle(
                  fontSize: AppTheme.fontTitle,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary)),
          actions: [
            IconButton(
              tooltip: '重新加载',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.refresh_rounded,
                  size: 20, color: context.textSecondary),
              onPressed: () => _ctl.reload(),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _ctl),
          // 首次加载：居中简约 loading
          if (_loading && _firstLoad)
            Positioned.fill(
              child: ColoredBox(
                color: context.scaffoldColor,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: context.textTertiary,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text('正在打开充值页…',
                          style: TextStyle(
                              fontSize: AppTheme.fontSmall, color: context.textTertiary)),
                    ],
                  ),
                ),
              ),
            ),
          // 后续跳转：只在顶部走一条细线，不遮挡内容
          if (_loading && !_firstLoad)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_error != null)
            Positioned.fill(
              child: ColoredBox(
                color: context.scaffoldColor,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('页面加载失败',
                            style: TextStyle(
                                fontSize: AppTheme.fontTitle,
                                fontWeight: FontWeight.w600,
                                color: context.textPrimary)),
                        const SizedBox(height: 8),
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: AppTheme.fontSmall,
                                color: context.textTertiary)),
                        const SizedBox(height: 16),
                        OutlinedButton(
                          onPressed: () {
                            setState(() => _error = null);
                            _prepare();
                          },
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
