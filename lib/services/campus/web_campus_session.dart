import 'dart:convert';

import 'campus_session.dart';
import 'web_campus_client.dart';

/// Web 端会话适配器：实现 [CampusSessionBase]，把 HTTP 方法转发到控制台
/// 有状态会话代理隧道（`/api/v1/campus/session/fetch`）。
///
/// 浏览器里 `dart:io HttpClient` 不可用，cookie 罐由服务端按 session_id 持有；
/// 本类本地只保留一个空 cookie 镜像，业务解析 client 拿到的接口形状与原生
/// [CampusSession] 一致，无需为 Web 另写一套解析。
///
/// 生命周期：登录（start → submit）成功后由 service 层用 ready 的 sessionId
/// 构造；[close] 调代理注销，清掉服务端内存罐。
class WebCampusSession extends CampusSessionBase {
  WebCampusSession(this.sessionId);

  /// 服务端会话凭证（自签随机串），不是 App 设备 token。
  final String sessionId;

  /// Web 端 cookie 由服务端持有，本地不镜像；保留空 map 以满足基类契约。
  @override
  final Map<String, String> cookies = {};

  @override
  String Function(String url)? get urlRewrite => null;

  @override
  Future<CampusResponse> get(
    String url, {
    Map<String, String>? headers,
    bool followRedirects = true,
  }) async {
    return _tunnel('GET', url, headers: headers);
  }

  @override
  Future<CampusResponse> postRaw(
    String url,
    String body, {
    Map<String, String>? headers,
    bool followRedirects = true,
  }) async {
    return _tunnel('POST', url, headers: headers, body: body);
  }

  @override
  Future<CampusResponse> postForm(
    String url,
    Map<String, String> form, {
    Map<String, String>? headers,
    bool followRedirects = true,
  }) async {
    final body = form.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final merged = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
      ...?headers,
    };
    return _tunnel('POST', url, headers: merged, body: body);
  }

  @override
  Future<CampusResponse> postJson(
    String url,
    Object data, {
    Map<String, String>? headers,
    bool followRedirects = true,
  }) async {
    final merged = <String, String>{
      'Content-Type': 'application/json',
      ...?headers,
    };
    return _tunnel('POST', url, headers: merged, body: jsonEncode(data));
  }

  Future<CampusResponse> _tunnel(
    String method,
    String url, {
    Map<String, String>? headers,
    String? body,
  }) async {
    final bodyB64 = body == null
        ? null
        : base64Encode(utf8.encode(body));
    final res = await WebCampusProxy.request(
      sessionId,
      url,
      method: method,
      headers: headers,
      bodyB64: bodyB64,
    );
    return CampusResponse(
      statusCode: res.statusCode,
      body: res.body,
      url: res.url,
      // 隧道在服务端已逐跳跟随，不再向上层回传中间 Location。
      location: null,
    );
  }

  @override
  void close() {
    // 异步注销不阻塞关闭；失败由代理内部吞掉。
    WebCampusProxy.logout(sessionId);
  }

  @override
  Map<String, String> exportCookies() => const {};

  @override
  void importCookies(Map<String, String> saved) {
    // Web 端不本地持久化教务 cookie；会话凭证是 sessionId，由 service 层持有。
  }
}
