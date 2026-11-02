import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../pages/legal_doc_page.dart';
import '../theme/app_theme.dart';

/// 法务文本中的项目联系邮箱。这里是项目邮箱，不包含个人身份信息。
const String kLegalContactEmail = 'privacy@wxxydouge.icu';

/// ICP 备案号。工信部要求 App 在「关于 / 设置」等可见位置展示备案号，
/// 应用商店上架审核也会核对这一项。
///
/// 真值与总站页脚保持一致（C:/build_ws/xiyuan_main/index.html），
/// 总站部署脚本 `deploy.py` 会校验线上页面确实含这个字符串 —— 改这里必须同步改总站。
const String kIcpNumber = '苏ICP备2026052960号-1';

/// 工信部备案查询地址（备案号点击后跳转）。
const String kIcpUrl = 'https://beian.miit.gov.cn/';

/// 首次启动隐私政策 / 用户协议确认。
class LegalConsentService {
  LegalConsentService._();

  static const String consentVersion = '2026-10-30';
  static const String _key = 'privacy_consent_version';

  static Future<bool> isAccepted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key) == consentVersion;
  }

  static Future<void> accept() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, consentVersion);
  }

  /// 返回 true = 用户同意，可以继续使用；false = 用户拒绝。
  static Future<bool> ensureConsent(BuildContext context) async {
    if (await isAccepted()) return true;
    if (!context.mounted) return false;

    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('隐私政策与用户协议'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '使用掌上锡院前，请阅读并同意《隐私政策》和《用户协议》。\n\n'
                'App 会在你主动使用时，使用学校统一认证账号查询课表、成绩、考试、余额等数据，并保存在本机。\n\n'
                '不同意将无法进入 App。',
                style: TextStyle(fontSize: AppTheme.fontBody, height: 1.55),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const LegalDocPage(
                          title: '隐私政策',
                          assetPath: 'assets/legal/privacy_policy.md',
                        ),
                      ),
                    ),
                    child: const Text('查看隐私政策'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const LegalDocPage(
                          title: '用户协议',
                          assetPath: 'assets/legal/user_agreement.md',
                        ),
                      ),
                    ),
                    child: const Text('查看用户协议'),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('不同意并退出'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('同意并进入'),
          ),
        ],
      ),
    );

    if (accepted == true) {
      await accept();
      return true;
    }
    return false;
  }
}
