import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// 校园网连接状态：
/// - unknown：检测中
/// - online：已连校园网并通过认证（可上外网）
/// - captive：连上校园网但未认证（被 captive 重定向到登录页）
/// - offCampus：无法访问认证服务器（不在校园网内）
enum CampusNetStatus { unknown, online, captive, offCampus }

/// 校园网检测（Dr.COM 城市热点）。仅负责「是否在校园网 + 是否已认证」的探测，
/// 不承担登录/绑定（已随 v2.2.3 删减，仅保留主页状态小字使用）。
class CampusNetService {
  static const String _authHost = 'http://10.1.99.100:801/eportal';

  /// 外网探测用 HTTP：未认证时网关会拦截 HTTP 并 302 到认证页；
  /// 若用 HTTPS 网关无法 MITM，会直接断连，从而误判「非校园网」。
  /// 必须用**国内可达**的 204 端点（小米 / vivo 的 captive 探测地址，
  /// 国内直连极稳；Google 系列极易被墙，已弃用）。
  static const List<String> _http204 = [
    'http://connect.rom.miui.com/generate_204',
    'http://wifi.vivo.com.cn/generate_204',
  ];

  /// 最近一次检测结果（静态缓存）。首页 Tab 切换会重建 State，
  /// 靠它直显上次结果，避免每次切回都重探、闪「检测中」。
  static CampusNetStatus? _last;
  static CampusNetStatus? get lastStatus => _last;

  /// 复用同一 Dio 实例（避免每次请求重建 HttpClient 适配器）。
  /// 校园网未认证时 Android 会下发 PAC 代理，请求会被 hijack 到奇怪端口，
  /// 所以必须 `DIRECT` 直连。
  static Dio? _shared;
  static Dio get _client {
    final d = _shared ??= Dio(BaseOptions(
      sendTimeout: const Duration(seconds: 3),
      followRedirects: false,
      validateStatus: (_) => true,
    ));
    if (d.httpClientAdapter is IOHttpClientAdapter) {
      (d.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
        return HttpClient()..findProxy = (_) => 'DIRECT';
      };
    }
    return d;
  }

  /// 带短超时、绕过代理的 GET（超时按调用场景区分）。
  static Future<Response<dynamic>> _get(
    String url, {
    Duration connect = const Duration(seconds: 3),
    Duration receive = const Duration(seconds: 3),
  }) =>
      _client.get(url, options: Options(connectTimeout: connect, receiveTimeout: receive));

  /// 检测校园网状态（两路并行，最快约 3s），结果写入静态缓存：
  /// ① 外网 HTTP 204 探测：204=真联网；3xx=被 captive 拦（必在校园网未认证）。
  /// ② 认证服务器可达性：仅校内可达，作为「是否校园网」标志。
  /// 组合：
  /// - 外网 204 且认证可达 → online（校园网已认证）
  /// - 外网 204 但认证不可达 → offCampus（家里/流量，能上网但不是校园网）
  /// - 外网被拦或探测失败，且认证可达 → captive（在校园网未认证）
  /// - 否则 → offCampus
  static Future<CampusNetStatus> detect() async {
    final r = await Future.wait([_externalOnline(), _canReachAuth()]);
    final bool? external = r[0]; // true=联网 / false=被拦 / null=异常
    final bool onCampus = r[1] == true;
    final status = (external == true)
        ? (onCampus ? CampusNetStatus.online : CampusNetStatus.offCampus)
        : (onCampus ? CampusNetStatus.captive : CampusNetStatus.offCampus);
    _last = status;
    return status;
  }

  /// 外网是否可联网：返回 true(204) / false(被 portal 3xx 拦) / null(均失败)。
  static Future<bool?> _externalOnline() async {
    for (final url in _http204) {
      try {
        final resp = await _get(url, connect: const Duration(seconds: 2), receive: const Duration(seconds: 3));
        final c = resp.statusCode;
        if (c == 204) return true;
        // 任意 3xx 都说明有中间人（captive portal）拦截，必在校园网内。
        if (c != null && c >= 300 && c < 400) return false;
      } catch (_) {
        // 该端点不可达，尝试下一个
      }
    }
    return null;
  }

  /// 认证服务器是否可达（仅校园网内可达）。
  /// 只要 TCP 能建立连接（请求未抛异常）即算可达——未认证时网关仍在 801 监听
  /// 认证页，故连接必成功；家里/流量下该私有地址不可达，连接失败。
  /// 因 BaseOptions 已设 `validateStatus: (_) => true`，正常 HTTP 响应不会抛异常，
  /// 只有连接层失败（超时/拒绝）才会进 catch → 返回 false。
  static Future<bool> _canReachAuth() async {
    try {
      await _get('$_authHost/', connect: const Duration(seconds: 2), receive: const Duration(seconds: 2));
      return true;
    } catch (_) {
      return false;
    }
  }
}
