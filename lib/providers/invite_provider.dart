import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/control_config.dart';
import '../services/invite_service.dart';

/// 一条脱敏的邀请记录。名单只回服务端脱敏标签，不暴露伪名/学号。
class InviteRelation {
  final String status;
  final String label;
  final String? activatedAt;

  const InviteRelation({
    required this.status,
    required this.label,
    this.activatedAt,
  });

  factory InviteRelation.fromJson(Map<String, dynamic> json) {
    return InviteRelation(
      status: (json['status'] ?? 'pending').toString(),
      label: (json['masked_label'] ?? json['label'] ?? '同学').toString(),
      activatedAt: json['activated_at']?.toString(),
    );
  }
}

const Object _unset = Object();

class InviteState {
  final bool loading;
  final bool available;
  final bool configLoaded;
  final String? code;
  final String? shareUrl;
  final int totalInvited;
  final int activatedCount;
  final List<InviteRelation> relations;
  final bool eggEnabled;

  /// 绑定交互态。
  final bool binding;
  final String? bindMessage;
  final bool bindSuccess;

  const InviteState({
    this.loading = true,
    this.available = true,
    this.configLoaded = false,
    this.code,
    this.shareUrl,
    this.totalInvited = 0,
    this.activatedCount = 0,
    this.relations = const [],
    this.eggEnabled = true,
    this.binding = false,
    this.bindMessage,
    this.bindSuccess = false,
  });

  /// 可空字段用 [_unset] 哨兵区分「没传」和「显式清空」。
  InviteState copyWith({
    bool? loading,
    bool? available,
    bool? configLoaded,
    Object? code = _unset,
    Object? shareUrl = _unset,
    int? totalInvited,
    int? activatedCount,
    List<InviteRelation>? relations,
    bool? eggEnabled,
    bool? binding,
    Object? bindMessage = _unset,
    bool? bindSuccess,
  }) =>
      InviteState(
        loading: loading ?? this.loading,
        available: available ?? this.available,
        configLoaded: configLoaded ?? this.configLoaded,
        code: identical(code, _unset) ? this.code : code as String?,
        shareUrl:
            identical(shareUrl, _unset) ? this.shareUrl : shareUrl as String?,
        totalInvited: totalInvited ?? this.totalInvited,
        activatedCount: activatedCount ?? this.activatedCount,
        relations: relations ?? this.relations,
        eggEnabled: eggEnabled ?? this.eggEnabled,
        binding: binding ?? this.binding,
        bindMessage: identical(bindMessage, _unset)
            ? this.bindMessage
            : bindMessage as String?,
        bindSuccess: bindSuccess ?? this.bindSuccess,
      );

  bool get hasCode => code != null && code!.isNotEmpty;
}

class InviteNotifier extends Notifier<InviteState> {
  /// 首次加载 Future，对齐 grade/user_config provider 范式：build 内只登记，
  /// 首次写 state 一律放在首个 await 之后，避免在 build 未返回前访问 state。
  Future<void>? _pending;

  @override
  InviteState build() {
    _pending = _load();
    return const InviteState();
  }

  Future<void> reload() => _load();

  Future<void> _load({bool clearBindMessage = true}) async {
    _pending = _loadBody(clearBindMessage: clearBindMessage);
    await _pending;
  }

  Future<void> _loadBody({bool clearBindMessage = true}) async {
    // 保留上一次绑定提示（手动刷新才清空）；在 await 之前只取局部值，不读 state。
    final keepMessage = clearBindMessage ? null : state.bindMessage;

    try {
      bool eggEnabled = true;
      bool activityActive = true;
      bool configLoaded = false;
      Map<String, dynamic>? me;
      try {
        // 先读开关配置（设备鉴权即可），失败按保守默认：活动开、彩蛋开。
        final cfg = await InviteService.fetchConfig();
        if (cfg != null) {
          configLoaded = true;
          eggEnabled = cfg['egg_enabled'] != false;
          activityActive = cfg['active'] != false;
        }
        me = await InviteService.fetchMe();
      } catch (_) {
        // 任何一步异常都按未连上处理，走降级态，不把 loading 挂住。
        me = null;
      }

      if (me == null) {
        // 关键：这里必须把上一次的邀请码/名单清掉；否则换账号或掉线后
        // 页面会继续显示上一个账号的数据，看起来像「还在线」。
        state = state.copyWith(
          loading: false,
          available: activityActive,
          configLoaded: configLoaded,
          eggEnabled: eggEnabled,
          code: null,
          shareUrl: null,
          totalInvited: 0,
          activatedCount: 0,
          relations: const [],
          bindMessage: keepMessage,
        );
        return;
      }

      // 字段解析整体防御：脏数据不崩页面，按空态兜底。
      String? code;
      List<InviteRelation> relations = const [];
      var totalInvited = 0;
      var activatedCount = 0;
      String? shareUrl;
      try {
        code = me['code']?.toString();
        relations = (me['relations'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((e) => InviteRelation.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        totalInvited =
            (me['total_invited'] as num?)?.toInt() ?? relations.length;
        activatedCount = (me['activated_count'] as num?)?.toInt() ?? 0;
        shareUrl = me['share_url']?.toString();
      } catch (_) {
        relations = const [];
      }

      state = state.copyWith(
        loading: false,
        available: activityActive,
        configLoaded: configLoaded,
        eggEnabled: eggEnabled,
        code: code,
        shareUrl: shareUrl,
        totalInvited: totalInvited,
        activatedCount: activatedCount,
        relations: relations,
        bindMessage: keepMessage,
      );
    } finally {
      // 最后一道保险：任何未预期的异常/中断都不能让转圈永久停住。
      if (state.loading) {
        state = state.copyWith(loading: false);
      }
    }
  }

  /// 兜底链接：服务端未回时按控制端根地址拼一个分享链接。
  String? get shareUrl {
    final raw = state.shareUrl;
    if (raw != null && raw.isNotEmpty) return raw;
    if (!state.hasCode) return null;
    return '${ControlConfig.baseUrl}/invite?c=${state.code}';
  }

  /// 回填邀请码。[source] 为 `manual_code` / `link`。
  Future<bool> bind(String code, String source) async {
    if (code.trim().isEmpty) {
      state = state.copyWith(bindMessage: '请输入邀请码', bindSuccess: false);
      return false;
    }
    state = state.copyWith(binding: true, bindMessage: null, bindSuccess: false);
    final res = await InviteService.bind(code, source);
    if (res == null) {
      state = state.copyWith(
        binding: false,
        bindMessage: '网络异常，请稍后重试',
        bindSuccess: false,
      );
      return false;
    }

    final status = res['status']?.toString();
    // 只有 activated 才算真正生效；pending 只表示关系已记录，不能显示成
    // 「邀请码已生效」让用户误以为已经计入邀请。
    final ok = status == 'activated';
    final message = switch (status) {
      'activated' => res['message']?.toString() ?? '邀请码已生效，已计入邀请',
      'pending' => '邀请码已记录，正在等待激活；可稍后下拉刷新查看',
      _ => _invalidMessage(
          res['reason']?.toString(), res['message']?.toString()),
    };

    state = state.copyWith(
      binding: false,
      bindMessage: message,
      bindSuccess: ok,
    );
    if (ok) {
      // 服务端在绑定成功时直接激活，这里只需刷新统计与名单。
      await _load(clearBindMessage: false);
    }
    return ok;
  }

  String _invalidMessage(String? reason, String? fallback) {
    switch (reason) {
      case 'old_user':
        return '这个账号注册超过 3 天了，只能算老用户';
      case 'same_device':
        return '同一台手机上切换账号不算邀请，换台设备再试';
      case 'self_invite':
        return '不能填写自己的邀请码';
      case 'duplicate':
        return '该账号已经绑定过邀请关系';
      case 'invalid_code':
        return '邀请码无效，请核对后重试';
      case 'risk_reject':
        return '当前账号暂不符合邀请条件';
      default:
        return fallback ?? '绑定未成功，请稍后重试';
    }
  }
}

final inviteProvider =
    NotifierProvider<InviteNotifier, InviteState>(InviteNotifier.new);
