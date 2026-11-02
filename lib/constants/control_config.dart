/// 控制端（内容下发服务）的固定配置。
///
/// **整个客户端只有这一处硬编码服务端地址。**
/// 把 [kControlBaseUrl] 置空（`''`）即可整体关闭控制端：
/// 所有控制端请求会在发 DNS 之前直接返回，App 退化为纯本地工具。
class ControlConfig {
  ControlConfig._();

  /// 控制端根地址。
  ///
  /// 只用于「内容下发」：版本检查、公告、校历、试卷库、设备登记。
  /// 教务/一卡通等数据**不经过这里**，仍由客户端直连学校系统。
  static const String baseUrl = 'https://con.wxxydouge.icu';

  /// 控制端是否启用（地址为空即关闭）。
  static const bool enabled = baseUrl != '';

  /// 更新下载允许的域名白名单。
  ///
  /// 服务端返回的下载地址必须落在这些域名下，否则拒绝跳转 ——
  /// 防止「检查更新」接口被劫持后指向任意 APK。
  ///
  /// ⚠️ 必须包含 APK 的**真实**托管域名：[kCdnHost]。
  /// 2026-11-02 之前这里只有下面三个，而安装包实际放在
  /// `static.wxxydouge.icu`（EdgeOne CDN，回源到 api 的 /static/），
  /// 于是 `AppUpdateService` 走到白名单判断就静默 return —— 更新提示永不出现。
  static const Set<String> updateDownloadHosts = {
    'con.wxxydouge.icu',
    'api.wxxydouge.icu',
    'down.wxxydouge.icu',
    kCdnHost,
  };

  /// 安装包与静态资源的真实托管域名（EdgeOne CDN，回源 `api.wxxydouge.icu/static/`）。
  ///
  /// 单独抽成常量，避免白名单和「下载地址怎么写」两处各写一遍字符串。
  static const String kCdnHost = 'static.wxxydouge.icu';

  /// 请求超时（秒）。
  static const int timeoutSeconds = 12;

  // ---- 签名规范化前缀（与服务端 security.py 一致）----
  static const String deviceSignPrefix = 'xiyuan-control-device';
  static const String loginSignPrefix = 'xiyuan-control-login';

  // ---- 接口路径（集中一处，便于服务端对拍）----
  static const String pathDeviceRegister = '/api/v1/devices/register';
  static const String pathChallenges = '/api/v1/auth/challenges';
  static const String pathAssertions = '/api/v1/auth/assertions';
  static const String pathRefresh = '/api/v1/auth/refresh';
  static const String pathRevoke = '/api/v1/auth/revoke';
  static const String pathConfigVersions = '/api/v1/config/versions';
  static const String pathAppRelease = '/api/v1/app/release';
  static const String pathMessages = '/api/v1/messages';
  static const String pathSchoolCalendar = '/api/v1/school-calendar';
  static const String pathExamPapers = '/api/v1/exam-papers/folders';
  static const String pathResources = '/api/v1/resources';
  static const String pathResourceUploads = '/api/v1/resource-uploads';
  static const String pathFeedback = '/api/v1/feedback';
  static const String pathHealth = '/healthz';
}
