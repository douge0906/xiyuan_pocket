import 'package:package_info_plus/package_info_plus.dart';

import '../constants/control_config.dart';
import 'control_api.dart';
import 'control_service.dart';
import 'device_identity.dart';
import 'storage_service.dart';

/// 邀请拉新服务端链路。
///
/// 与控制端其它请求同一套降级口径：未登录不发、断网/超时/非 2xx 静默返回 null，
/// 不弹错误、不阻塞课表/成绩等主流程。会话过期时先静默续期一次再请求。
class InviteService {
  InviteService._();

  /// 上报元信息：版本号 + 平台，服务端只用于事件追溯，不含学号姓名。
  static Future<Map<String, String>> _meta() async {
    String version = '';
    try {
      final info = await PackageInfo.fromPlatform();
      version = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // 取不到版本号不影响主链路，留空即可。
    }
    return {'app_version': version, 'platform': 'android'};
  }

  /// 拉取我的邀请码、链接、统计与脱敏名单。
  static Future<Map<String, dynamic>?> fetchMe() async {
    try {
      if (!await ControlApi.allowed()) return null;
      await _ensureFreshSession();
      return ControlApi.getJson(
        ControlConfig.pathInviteMe,
        useSessionToken: true,
      );
    } catch (_) {
      return null;
    }
  }

  /// 拉取活动/彩蛋开关配置；设备鉴权即可，失败由调用方用内置默认。
  static Future<Map<String, dynamic>?> fetchConfig() async {
    try {
      return ControlApi.getJson(
        ControlConfig.pathInviteConfig,
        requireLogin: false,
      );
    } catch (_) {
      return null;
    }
  }

  /// 回填邀请码绑定关系。返回服务端原始结构；null 表示本次未连上。
  static Future<Map<String, dynamic>?> bind(
    String code,
    String source,
  ) async {
    try {
      if (!await ControlApi.allowed()) return null;
      await _ensureFreshSession();
      final meta = await _meta();
      return ControlApi.postJson(
        ControlConfig.pathInviteBind,
        {
          'code': code.trim().toUpperCase(),
          'source': source,
          ...meta,
        },
        useSessionToken: true,
      );
    } catch (_) {
      return null;
    }
  }

  /// 五星体验评分：不阻塞 UI，失败静默（本地仍会保留本次评分）。
  static Future<void> submitRating(int rating) async {
    try {
      if (!await ControlApi.allowed()) return;
      await _ensureFreshSession();
      final meta = await _meta();
      await ControlApi.postJson(
        ControlConfig.pathAppRating,
        {'rating': rating, ...meta},
        useSessionToken: true,
      );
    } catch (_) {
      // 静默：评分失败不影响主流程。
    }
  }

  /// 确保请求前有可用会话。
  ///
  /// 顺序：access 已有 → 直接用；否则先用 refresh 续期；refresh 也拿不到
  /// （老用户升级、旧版本从未建立过控制端会话）时，用本机学号重新断言登录一次，
  /// 补齐控制端会话。任一步失败都按无会话降级，不向上抛。
  static Future<void> _ensureFreshSession() async {
    try {
      final access = await DeviceIdentity.loadAccessToken();
      if (access != null && access.isNotEmpty) return;

      await ControlService.refreshSession();
      final afterRefresh = await DeviceIdentity.loadAccessToken();
      if (afterRefresh != null && afterRefresh.isNotEmpty) return;

      // 老用户新增本服务：本机已登教务账号，但控制端会话缺失，补断言登录。
      final cfg = await StorageService.loadUserConfig();
      final studentId = cfg.username.trim();
      if (studentId.isNotEmpty) {
        await ControlService.loginWithStudentId(studentId);
      }
    } catch (_) {
      // 会话补齐异常按无会话处理，不向上抛。
    }
  }
}
