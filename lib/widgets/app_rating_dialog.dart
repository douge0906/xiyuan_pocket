import 'dart:async';

import 'package:flutter/material.dart';

import '../pages/invite/invite_page.dart';
import '../services/auth_gate.dart';
import '../services/invite_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import 'pressable.dart';

/// 累计进入课表页 3 次后弹出的一次性弹窗：
/// 五星体验评价（点星即提交，本地留档 + 服务端静默上报）+ 推荐给新同学。
///
/// 视觉沿用现有 App 卡片：圆角、细边框、主色图标；星级用警示色强调。
class AppRatingDialog extends StatefulWidget {
  const AppRatingDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AppRatingDialog(),
    );
  }

  @override
  State<AppRatingDialog> createState() => _AppRatingDialogState();
}

class _AppRatingDialogState extends State<AppRatingDialog> {
  static const _labels = <int, String>{
    1: '不太满意',
    2: '有待改进',
    3: '还不错',
    4: '很好用',
    5: '非常棒',
  };

  int _score = 0;
  bool _submitted = false;

  /// 「推荐给新同学」进行中，防连点重复 pop。
  bool _going = false;

  Future<void> _rate(int score) async {
    // 点星后可改分：同一版本服务端按用户幂等覆盖，本地也覆盖最近一次。
    if (_submitted && score == _score) return;
    setState(() {
      _score = score;
      _submitted = true;
    });
    await StorageService.saveAppRating(score, DateTime.now().toIso8601String());
    // 服务端静默上报：失败不影响本地记录与后续操作；改分时重新上报，
    // 服务端 ON CONFLICT 覆盖旧值，不会重复计数。
    unawaited(InviteService.submitRating(score));
  }

  Future<void> _openInvite() async {
    if (_going) return;
    setState(() => _going = true);
    final nav = Navigator.of(context);
    try {
      final ok = await AuthGate.ensureLoggedIn(context);
      if (!mounted) return;
      if (!ok) {
        // 未登录/取消登录时保留弹窗，用户还能继续评价或点「以后再说」。
        setState(() => _going = false);
        return;
      }
      nav.pop(_submitted);
      nav.push(
        MaterialPageRoute<void>(builder: (_) => const InvitePage()),
      );
    } catch (_) {
      if (mounted) setState(() => _going = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(color: context.borderColor),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: AppTheme.warning.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    ),
                    child: Icon(Icons.star_rounded,
                        size: 24, color: AppTheme.warning),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('掌上锡院用得还顺手吗？',
                        style: TextStyle(
                            fontSize: AppTheme.fontTitle,
                            fontWeight: FontWeight.w600,
                            color: context.textPrimary)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '点一颗星给个评价，也可以直接把 App 推荐给同班同学。',
                style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    color: context.textSecondary,
                    height: 1.5),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (index) {
                  final value = index + 1;
                  final selected = value <= _score;
                  return Semantics(
                    button: true,
                    label: '$value 星',
                    child: Pressable(
                      onTap: () => _rate(value),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(
                          selected
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          size: 32,
                          color: selected
                              ? AppTheme.warning
                              : context.textTertiary.withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 20,
                child: Center(
                  child: Text(
                    _submitted
                        ? '感谢你的评价 · ${_labels[_score]}'
                        : '1 星很差 · 5 星很棒',
                    style: TextStyle(
                        fontSize: AppTheme.fontSmall,
                        color: _submitted
                            ? AppTheme.success
                            : context.textTertiary),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: FilledButton.icon(
                  onPressed: _going ? null : _openInvite,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: AppTheme.radiusMdAll,
                    ),
                  ),
                  icon: const Icon(Icons.people_alt_rounded,
                      size: 18, color: Colors.white),
                  label: const Text('推荐给新同学',
                      style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: TextButton(
                  onPressed: _going
                      ? null
                      : () => Navigator.of(context).pop(_submitted),
                  child: Text('以后再说',
                      style: TextStyle(color: context.textTertiary)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
