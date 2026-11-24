import 'package:flutter/material.dart';

/// Web 端的充值页占位实现（2026-11-24）。
///
/// `package:webview_flutter` 只有 android / ios 实现，浏览器里没有 WebView，
/// 所以 web 编译路径**不能**引用它 —— 用条件导入把真实现挡在外面
/// （先例：`lib/pages/tools/campus_map_page.dart`）。
///
/// 真正的 web 充值流程是「跳外部浏览器」：
/// 先开网关登录地址（浏览器自己拿到网关票据 cookie），再开充值页地址
/// （自带 `?token=`，打开即登录）。见 `lib/pages/balance_detail_pages.dart`。
///
/// 这里保留同名同参的类，只是为了**永远不会被构造**：
/// 万一有人误用，页面会直接给出说明，而不是在运行时抛插件异常。
class RechargeWebViewPage extends StatelessWidget {
  const RechargeWebViewPage({
    super.key,
    required this.url,
    this.warmupUrl,
    this.title = '充值',
  });

  /// 最终要展示的页面。
  final String url;

  /// 需要**先访问**的中间页。
  final String? warmupUrl;

  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('网页版请在新打开的浏览器标签页中完成充值'),
        ),
      ),
    );
  }
}
