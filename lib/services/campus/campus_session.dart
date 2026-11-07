import 'dart:async';
import 'dart:convert';
import 'dart:io';

// `CampusException` 定义在 jwgl_client.dart，而它自己也 import 本文件 ——
// Dart 允许库级循环 import（两边的类都只在方法体里互相引用）。
// 放在这里而不是把类搬过来：CampusException 是「教务系统」语义的异常，
// 搬进这个纯 HTTP 会话文件反而让依赖方向更乱。
import 'jwgl_client.dart';

/// 极简 HTTP 会话（带 cookie jar）—— 客户端直连校园系统的基础设施。
///
/// 为什么不用 `package:http`：它的 `headers` 是多值合并成 ", " 的字符串，
/// 遇到 `Set-Cookie: a=1; Expires=Wed, 21 Oct...` 这种带逗号的 cookie 会解析错乱。
/// `dart:io` 的 `HttpHeaders` 能拿到每个 header 的独立值，最稳。
///
/// 这是**纯 Dart** 实现（不依赖 Flutter），可以用 `dart run` 直接跑端到端测试。
class CampusResponse {
  final int statusCode;
  final String body;
  final String url; // 最终 URL（跟随重定向后）

  /// 本次响应的 `Location`（未跟随重定向时有值）。
  ///
  /// 平台票这类参数常常只出现在**中间那一跳**的 URL 里，最终落点已经没有它了，
  /// 所以要能逐跳看到 Location。
  final String? location;

  const CampusResponse({
    required this.statusCode,
    required this.body,
    required this.url,
    this.location,
  });

  bool get ok => statusCode >= 200 && statusCode < 300;

  /// 是否被弹回登录页（判断会话是否失效）
  bool get looksLikeLogin => url.toLowerCase().contains('login');
}

/// 从业务页 HTML 里取 `csrftoken` —— **全项目唯一实现**。
///
/// 页面给的是 `<uuid>,<uuid去横线>` 这种两段式，业务接口只认**逗号前**那一段。
/// 原先后端逻辑分散在 `course_fetcher` / `jwgl_client` / `study_client` 三处，
/// 只有 `study_client` 做了 `split(',')`，另外两处原样返回 → 成绩 / 考试 / 教材 /
/// 课表四类查询都会拿到带逗号的令牌。抽成一处，避免再分叉。
String extractCsrfToken(String html) {
  final m = RegExp(r'id="csrftoken"[^>]*value="([^"]+)"').firstMatch(html);
  if (m == null) return '';
  return m.group(1)!.split(',').first.trim();
}

/// **不做 http→https 升级**的主机白名单。
///
/// 目前只有实验课系统 `sygl.cwxu.edu.cn`：它 443 端口是关的（TCP 连接超时），
/// 而 80 端口完全正常。`CampusSession` 默认会把 `*.cwxu.edu.cn` 的 http 升级成
/// https（那是为教务/门户那种「明文会被断连」的站点加的），对 sygl 就是致命误伤。
///
/// 新增条目时要先实测 443 到底通不通，别凭印象加。
const Set<String> httpsOnlyExclusions = <String>{
  'sygl.cwxu.edu.cn',
};

class CampusSession {
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  final HttpClient _client;
  final Map<String, String> cookies = {};

  /// 每一跳实际发出的 URL 改写（WebVPN 用）。
  ///
  /// 为什么必须放在**会话层**而不是调用方：校外走网关时，CAS 换票后平台会 302 到
  /// `http://10.3.100.110/plat/?ticket=…`（相对/绝对内网地址），这一跳如果不改写就
  /// 直接连内网、必然超时 —— 平台票也就拿不到。放在这里能覆盖「起始 URL + 每一跳」。
  ///
  /// 约定：实现必须**幂等**（已改写过的 URL 再传进来要原样返回），因为每跳都会调用。
  final String Function(String url)? urlRewrite;

  /// **单跳**超时：每一跳（连接 / 发送 / 读响应体）各自计时，互不累加。
  /// ⚠️ 2026-10-20 审查：注释原名不副实 —— 重定向链最坏 8 跳 × 25s ≈ 200s，
  ///    不是"总超时"（已知债务，见审查报告）。另：`HttpClient` 只提供连接超时，
  ///    若服务器接了连接却不回数据，不设超时会让界面**无限期卡住**。
  final Duration timeout;

  CampusSession({
    this.timeout = const Duration(seconds: 25),
    this.urlRewrite,
  }) : _client = HttpClient() {
    _client.connectionTimeout = timeout;
    _client.userAgent = defaultUserAgent;
    // 校园系统一律直连，不走系统/环境代理（否则开发机上的死代理会拖垮请求）
    _client.findProxy = (uri) => 'DIRECT';
  }

  void close() => _client.close(force: true);

  /// 导出 cookie（用于持久化会话复用）
  Map<String, String> exportCookies() => Map<String, String>.from(cookies);

  /// 导入 cookie（恢复上次会话）
  void importCookies(Map<String, String> saved) {
    cookies
      ..clear()
      ..addAll(saved);
  }

  String get _cookieHeader =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  void _captureCookies(HttpClientResponse res) {
    res.headers.forEach((name, values) {
      if (name.toLowerCase() != 'set-cookie') return;
      for (final raw in values) {
        final first = raw.split(';').first.trim();
        final eq = first.indexOf('=');
        if (eq <= 0) continue;
        final k = first.substring(0, eq).trim();
        final v = first.substring(eq + 1).trim();
        if (v.isEmpty || v.toLowerCase() == 'deleted') {
          cookies.remove(k);
        } else {
          cookies[k] = v;
        }
      }
    });
  }

  /// 统一入口：把底层的超时 / 网络异常翻译成**用户能看懂**的提示，
  /// 避免界面弹出 `TimeoutException after 0:00:25.000000` 这种天书。
  Future<CampusResponse> _send(
    String method,
    String url, {
    Map<String, String>? form,
    Map<String, String>? headers,
    bool followRedirects = true,
    String? body,
  }) async {
    try {
      return await _sendRaw(method, url,
          form: form,
          headers: headers,
          followRedirects: followRedirects,
          body: body);
    } on TimeoutException {
      // 🔴 抛 CampusException 而不是裸 Exception：
      //    上层（campus_store 的 `on CampusException`、页面的 `'$e'`）都按它
      //    判断，裸 Exception 的 toString 会带上 `Exception: ` 前缀，
      //    用户读到「读取实验课失败：Exception: 连接学校系统超时…」双重前缀。
      throw CampusException('连接学校系统超时（${timeout.inSeconds} 秒），请检查网络后重试');
    } on HandshakeException {
      throw CampusException('与学校系统的安全连接失败，请确认网络环境后重试');
    } on SocketException catch (e) {
      throw CampusException('网络不可达：${e.message}');
    }
  }

  Future<CampusResponse> _sendRaw(
    String method,
    String url, {
    Map<String, String>? form,
    Map<String, String>? headers,
    bool followRedirects = true,
    String? body,
  }) async {
    // ⚠️ 必须**手动**跟重定向：dart:io 自动跟随时，中间 302 响应里下发的
    //    Set-Cookie（CAS/教务的会话就藏在这一步）会拿不到。
    var currentUrl = url;
    // `rawUrl` 始终保存**未包装**的原始地址，`target` 才是实际请求地址。
    // 两者必须分开：相对 Location（如 `/plat/?ticket=…`）只能相对原始地址解析，
    // 若相对包装后的地址解析会吃掉 `/http/<hex>` 前缀、退化成网关根路径
    // （2026-10-25 自查发现 —— VPN 换票链正是断在这一跳）。
    var rawUrl = url;
    // 跳数上限 12：参考实现（cas.rs sso_follow）用 10 跳，WebVPN 登录链
    // （login → token-login → 门户）比普通 SSO 更长，留足余量。
    for (var hop = 0; hop < 12; hop++) {
      // 每跳都过一遍改写（WebVPN 幂等包装）；CampusResponse.url 也是改写后的
      // 最终地址，调用方从它取 query 参数（如平台票）不受影响。
      final target = urlRewrite?.call(rawUrl) ?? rawUrl;
      currentUrl = target;
      var uri = Uri.parse(target);
      // 参考实现（Wxxy-CampusHub/cas.rs sso_follow）实测：cwxu 域名的 http 明文
      // 会被服务端直接断连，302 链里遇到要**升到 https**（只升不降，避免来回跳）。
      //
      // 🔴 但这条规则不是全局成立的：实验课系统 `sygl.cwxu.edu.cn` **只开了 80**，
      // 443 直接连不通（实测 curl exit 28、TCP 连接超时），强行升级 = 整个功能
      // 永远超时。所以按站点白名单排除，别为了统一好看把它一起升级。
      if (uri.scheme == 'http' &&
          uri.host.endsWith('.cwxu.edu.cn') &&
          !httpsOnlyExclusions.contains(uri.host)) {
        uri = uri.replace(scheme: 'https');
        currentUrl = uri.toString();
      }
      final req = await _client
          .openUrl(hop == 0 ? method : 'GET', uri)
          .timeout(timeout);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.userAgentHeader, defaultUserAgent);
      if (cookies.isNotEmpty) {
        req.headers.set(HttpHeaders.cookieHeader, _cookieHeader);
      }
      headers?.forEach((k, v) => req.headers.set(k, v));

      // 表单/正文只挂在第一跳上（302 之后按浏览器惯例退化为 GET）
      if (hop == 0) {
        if (form != null) {
          req.headers.contentType = ContentType(
              'application', 'x-www-form-urlencoded',
              charset: 'utf-8');
          req.add(utf8.encode(_encodeForm(form)));
        } else if (body != null) {
          req.add(utf8.encode(body));
        }
      }

      final res = await req.close().timeout(timeout);
      _captureCookies(res);

      final location = res.headers.value(HttpHeaders.locationHeader);
      final isRedirect =
          res.statusCode >= 300 && res.statusCode < 400 && location != null;
      if (isRedirect && followRedirects) {
        await res.drain<void>().timeout(timeout); // 消费响应体，避免占住连接
        // 关键：相对**原始**地址解析，再由下一跳的 rewrite 统一包装
        rawUrl = nextHop(rawUrl, location);
        currentUrl = rawUrl;
        continue;
      }

      // 🔴 不能硬解 utf8：站点有一部分页面/错误页是 gb2312，硬解会抛
      //    `FormatException: Missing extension byte`，然后被各调用方的
      //    `catch (_)` 吞掉，表象是「HTTP 状态 0 / 接口没数据」——
      //    实验课 `UserCenter.asmx` 的 404 页就是这样把真因藏了两个月。
      //    这里改成容错解码：合法 utf8 内容逐字节不变，坏字节不会炸。
      final bytes = await res
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(timeout);
      final text = utf8.decode(bytes, allowMalformed: true);
      return CampusResponse(
        statusCode: res.statusCode,
        body: text,
        url: currentUrl,
        location: location,
      );
    }
    return CampusResponse(statusCode: 310, body: '', url: currentUrl);
  }

  /// 计算下一跳地址：相对 Location 相对**原始（未包装）**地址解析。
  ///
  /// 抽成纯函数是为了单测 —— VPN 模式下这一步算错会吃掉 `/http/<hex>` 前缀。
  static String nextHop(String rawUrl, String location) =>
      Uri.parse(rawUrl).resolve(location).toString();

  static String _encodeForm(Map<String, String> form) => form.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');

  Future<CampusResponse> get(
    String url, {
    Map<String, String>? headers,
    bool followRedirects = true,
  }) =>
      _send('GET', url, headers: headers, followRedirects: followRedirects);

  /// 发送站点要求的原始 POST 正文。
  ///
  /// 实验课旧 ASMX 的正文是 `{kzJson:'…'}` 这种 JS 字面量，不是合法 JSON。
  /// 用 [postJson] 会多包一层 JSON 字符串引号；本方法按原样发送。
  Future<CampusResponse> postRaw(
    String url,
    String body, {
    Map<String, String>? headers,
    bool followRedirects = true,
  }) =>
      _send('POST', url,
          body: body, headers: headers, followRedirects: followRedirects);

  Future<CampusResponse> postForm(
    String url,
    Map<String, String> form, {
    Map<String, String>? headers,
    bool followRedirects = true,
  }) =>
      _send('POST', url,
          form: form, headers: headers, followRedirects: followRedirects);

  /// JSON POST（个别接口必须 JSON body，如取消订单）。
  Future<CampusResponse> postJson(
    String url,
    Object data, {
    Map<String, String>? headers,
    bool followRedirects = true,
  }) =>
      _send('POST', url,
          body: jsonEncode(data),
          headers: {...?headers, 'Content-Type': 'application/json'},
          followRedirects: followRedirects);

  /// 取 JSON（解析失败返回 null）
  static Map<String, dynamic>? tryJson(String body) {
    try {
      final v = jsonDecode(body);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// 取 JSON 的**通用形态**：顶层可能是 `{...}` 也可能是 `[...]`。
  ///
  /// 正方多数模块返回 `{items:[...]}`，但部分模块（如教材预订）直接返回数组；
  /// 用 [tryJson] 会把数组判成「非预期内容」而丢掉全部数据。
  static Object? tryJsonAny(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
}
