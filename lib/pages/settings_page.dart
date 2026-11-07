import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'display_settings_page.dart';
import 'general_settings_page.dart';
import 'legal_doc_page.dart';
import 'message_settings_page.dart';
// v1.0.9：通知提醒与课程提醒两个页面已合并为一个（用户需求 #9：
// 「通知提醒和课程提醒合并」）。旧的两个页面仍留在仓库里但不再有
// 任何入口 —— 合并页 notification_reminder_page.dart 覆盖了它们
// 的全部能力，且把「权限在哪」和「开关在哪」放在同一屏。
import 'notification_reminder_page.dart';

import '../services/app_cache.dart';
import '../services/app_locale.dart';
import '../services/app_update_service.dart';
import '../services/legal_consent.dart';
import '../theme/app_theme.dart';
import '../widgets/settings_rows.dart';
import 'feedback_dialog.dart';

/// App 设置页（唯一入口，v1.0.9 极简版）。
///
/// ## 这一版改了什么
///
/// 用户第二次口径：「设置页怎么还是小字长篇大论，极简化。」
/// 上一版虽然把平铺改成了容器，但每一行右边仍挂着一串灰色小字
/// （「已开启」「18 号 · 系统默认」「3 / 9」），一行里塞了两层信息，
/// 读起来像说明书。这一版的做法是**把右侧小字全部删掉**：
///
///  · 每一行只留「图标 + 名称 + 箭头」，当前值进二级页里看；
///  · 分组不再用大标题，靠卡片间距分组（少一层字就是少一层噪音）；
///  · 版本号与备案号合并成页面底部一行灰字。
///
/// ## 首屏
///
/// 一张卡一件事：通知与提醒 / 界面与显示 / 数据与存储 / 帮助与关于，
/// 之后是退出登录，最后一行是「v1.0.9 · ICP 备案号」。
///
/// 语言搬进「通用设置」，服务管理搬进「外观与个性化」——
/// 这两条是用户点名的，「界面与显示」只剩两个入口。
class SettingsPage extends StatefulWidget {
  final Future<void> Function() onLogout;
  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode) onThemeChanged;

  /// 当前主题色（外部 ValueNotifier，便于本页与全局同步）。
  final ValueNotifier<Color> primaryColor;
  final Future<void> Function(Color) onPrimaryChanged;

  const SettingsPage({
    super.key,
    required this.onLogout,
    required this.themeMode,
    required this.onThemeChanged,
    required this.primaryColor,
    required this.onPrimaryChanged,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 缓存占用字节数（null = 还没算完）。
  int? _cacheBytes;

  /// 版本号。
  String _version = '';

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  /// 只查两项：缓存大小（清理确认框要用）与版本号（页脚要用）。
  ///
  /// 各自 try/catch：查不到就是留空，绝不能因为一项失败就整页打不开
  /// （设置页进不去 = 用户彻底没法退出登录）。
  Future<void> _refreshStatus() async {
    int? cache;
    try {
      cache = await AppCache.sizeBytes();
    } catch (_) {}

    String version = '';
    try {
      version = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _cacheBytes = cache;
      _version = version;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: Text(S.t('set_title'),
            style: const TextStyle(
                fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      // 🔴 SafeArea 必须加：底部那行备案号在 Android 15（targetSdk 35）
      // 强制 edge-to-edge 后会被系统导航条压住 —— 那是合规硬伤。
      body: SafeArea(
        top: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            6,
            20,
            MediaQuery.of(context).padding.bottom + 20,
          ),
          children: [
            // ==================== 通用 ====================
            //
            // 2026-11-03 用户口径（第三次）：「按照 通用 功能 帮助与反馈
            // 直接划分设置页」。所以恢复三个分区小字标题 —— 上一版把它们
            // 一起删掉是误读：用户要简化的是「通知消息页里的注释小字」，
            // 不是设置页的分类。
            SettingsSectionLabel(S.t('sec_general')),
            SettingsCard(
              children: settingsWithDividers(context, [
                SettingsEntryRow(
                  icon: Icons.palette_outlined,
                  title: S.t('item_appearance'),
                  onTap: () => _push(const DisplaySettingsPage()),
                ),
                SettingsEntryRow(
                  icon: Icons.tune_rounded,
                  title: S.t('set_general'),
                  onTap: () => _push(const GeneralSettingsPage()),
                ),
              ]),
            ),

            // ==================== 功能 ====================
            SettingsSectionLabel(S.t('sec_function')),
            SettingsCard(
              children: settingsWithDividers(context, [
                SettingsEntryRow(
                  icon: Icons.notifications_active_outlined,
                  title: S.t('item_notifications'),
                  onTap: () => _push(const NotificationReminderPage()),
                ),
                SettingsEntryRow(
                  icon: Icons.inbox_outlined,
                  title: S.t('item_message'),
                  onTap: () => _push(const MessageSettingsPage()),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            // 存储与危险操作同卡：放一起才看得懂「清理」与「清除」的区别。
            SettingsCard(
              children: settingsWithDividers(context, [
                SettingsEntryRow(
                  icon: Icons.cleaning_services_outlined,
                  title: S.t('item_clear_cache'),
                  onTap: _confirmClearCache,
                ),
                SettingsEntryRow(
                  icon: Icons.delete_forever_outlined,
                  title: S.t('item_clear_all'),
                  onTap: _confirmClearData,
                ),
              ]),
            ),

            // ==================== 帮助与反馈 ====================
            SettingsSectionLabel(S.t('sec_help')),
            SettingsCard(
              children: settingsWithDividers(context, [
                SettingsEntryRow(
                  icon: Icons.feedback_outlined,
                  title: S.t('item_feedback'),
                  onTap: () => showFeedbackDialog(context),
                ),
                SettingsEntryRow(
                  icon: Icons.privacy_tip_outlined,
                  title: S.t('item_privacy'),
                  onTap: () => _openLegal(
                      S.t('item_privacy'), 'assets/legal/privacy_policy.md'),
                ),
                SettingsEntryRow(
                  icon: Icons.description_outlined,
                  title: S.t('item_terms'),
                  onTap: () => _openLegal(
                      S.t('item_terms'), 'assets/legal/user_agreement.md'),
                ),
                SettingsEntryRow(
                  icon: Icons.mail_outline_rounded,
                  title: S.t('item_contact'),
                  onTap: _contactEmail,
                ),
                SettingsEntryRow(
                  icon: Icons.system_update_outlined,
                  title: S.t('item_check_update'),
                  onTap: _checkUpdate,
                ),
              ]),
            ),

            const SizedBox(height: 20),
            // 退出登录：与全 App 一致的卡片外壳 + 危险色文字。
            //
            // 🔴 2026-11-03 修「退出登录按钮外观缺失」：原来是一个裸
            // `TextButton(foregroundColor: danger)` —— 只有一段红字，没有
            // 背景、没有边框、没有圆角，看起来就像没加载完。全局也**没有**
            // `textButtonTheme` 兜底，所以它在真机上就是「一段悬空的文字」。
            //
            // 🔴 2026-11-03 再修「边框怎么又没了」：上一版只给了
            // `boxShadow: cardShadowFor(...)`，而 cardShadowFor 从那天起
            // **只做纵深、不做描边**（描边统一走 Border.all + cardStrokeColor，
            // 因为外扩 1px 的假描边会被 ListView 的硬裁剪切掉）。这里漏了
            // Border.all，于是它就是一块没有轮廓的白片 —— 和卡片对不上。
            Material(
              color: Colors.transparent,
              child: Ink(
                decoration: BoxDecoration(
                  color: context.cardColor,
                  borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                  border: Border.all(
                    color: AppTheme.cardStrokeColor(context.isDark),
                  ),
                  boxShadow: AppTheme.cardShadowFor(context.isDark),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                  onTap: _confirmLogout,
                  child: SizedBox(
                    height: 46,
                    width: double.infinity,
                    child: Center(
                      child: Text(
                        S.t('item_logout'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.danger,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),
            // 版本号 + 备案号合并成一行：两个都是「看着但不用点」的信息，
            // 分两行放就是多一行噪音。
            InkWell(
              onTap: _openIcp,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                child: Text(
                  _version.isEmpty ? kIcpNumber : 'v$_version · $kIcpNumber',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: context.textTertiary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _push(Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.t('item_logout'),
            style: const TextStyle(
                fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
        content: const Text(
          '确定要退出登录吗？\n退出后本机的课表、待办、成绩等数据会被清空。',
          style: TextStyle(fontSize: AppTheme.fontBody, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(S.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.danger,
              foregroundColor: Colors.white,
            ),
            child: Text(S.t('confirm_logout')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.onLogout();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _checkUpdate() async {
    await AppUpdateService.checkManually(context);
  }

  Future<void> _confirmClearCache() async {
    final size = _cacheBytes;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.t('item_clear_cache')),
        content: Text(
          size == null || size <= 0
              ? '当前没有可清理的缓存。\n\n'
                  '清理只影响预览过的资源文件与图片，不会动你下载保存的资料，'
                  '也不会影响账号和课表。'
              : '将释放约 ${AppCache.format(size)}。\n\n'
                  '清理只影响预览过的资源文件与图片，不会动你下载保存的资料，'
                  '也不会影响账号和课表。',
          style: const TextStyle(fontSize: AppTheme.fontBody, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(S.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(S.t('clear')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final freed = await AppCache.clear();
    if (!mounted) return;
    await _refreshStatus();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(freed > 0 ? '已释放 ${AppCache.format(freed)}' : '缓存已清理'),
      ));
  }

  Future<void> _openIcp() async {
    final uri = Uri.parse(kIcpUrl);
    if (!await launchUrl(uri)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('备案号 $kIcpNumber，可在工信部网站查询')),
      );
    }
  }

  void _openLegal(String title, String assetPath) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LegalDocPage(title: title, assetPath: assetPath),
      ),
    );
  }

  /// 联系 / 投诉邮箱：2026-11-04（m19335 #7）起内容暂抹，只留占位。
  ///
  /// 为什么不再拼 `mailto:`：`kLegalContactEmail` 现在是空串，拼出来是
  /// `mailto:?subject=…`（收件人空着），系统邮件 App 打开后用户会盯着一个
  /// 没有收件人的编辑框 —— 比「暂未开通」更让人困惑。等正式邮箱定下来，
  /// 把 [kLegalContactEmail] 填回真值、这里恢复 launchUrl 即可。
  Future<void> _contactEmail() async {
    if (kLegalContactEmail.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('联系邮箱暂未开通，可先在「意见反馈」里留言')),
      );
      return;
    }
    final uri = Uri.parse(
        'mailto:$kLegalContactEmail?subject=${Uri.encodeComponent('掌上锡院投诉反馈')}');
    if (!await launchUrl(uri)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开邮件应用，请手动发送至 $kLegalContactEmail')),
      );
    }
  }

  Future<void> _confirmClearData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.t('item_clear_all')),
        content: const Text(
          '将删除本机保存的账号、课表、成绩、待办、设置等全部数据，并退出登录。\n\n'
          '此操作无法撤销，确定继续吗？',
          style: TextStyle(fontSize: AppTheme.fontBody, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(S.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.danger,
              foregroundColor: Colors.white,
            ),
            child: Text(S.t('clear')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.onLogout();
    if (mounted) Navigator.of(context).pop();
  }
}
