import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/countdown_store.dart';
import '../services/exam_storage.dart';
import '../services/storage_service.dart';
import '../services/widget_sync_service.dart';
import '../theme/app_theme.dart';
import '../widgets/widget_appearance_editor.dart';
import 'countdown_page.dart';

enum WidgetInfoKind { exam, card, countdown }

/// 考试倒计时 / 校园卡余额小组件的数据与刷新页。
///
/// 真正的小组件由 Android 原生 Provider 渲染；这里负责展示当前数据并手动同步。
class WidgetInfoPage extends StatefulWidget {
  const WidgetInfoPage({super.key, required this.kind});

  final WidgetInfoKind kind;

  @override
  State<WidgetInfoPage> createState() => _WidgetInfoPageState();
}

class _WidgetInfoPageState extends State<WidgetInfoPage> {
  bool _loading = true;
  String _headline = '';
  String _detail = '';

  bool get _isExam => widget.kind == WidgetInfoKind.exam;
  bool get _isCountdown => widget.kind == WidgetInfoKind.countdown;

  String get _widgetKindName => _isExam
      ? 'exam'
      : _isCountdown
          ? 'countdown'
          : 'card';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String headline = '';
    String detail = '';
    if (_isExam) {
      final exam = await ExamStorage.nextExam();
      headline = exam?.name ?? '暂无考试安排';
      detail = exam == null
          ? '打开考试安排查询并同步后再来看'
          : '${exam.date.year}-${exam.date.month.toString().padLeft(2, '0')}-'
              '${exam.date.day.toString().padLeft(2, '0')} · '
              '${exam.daysLeft <= 0 ? '今天' : '还有 ${exam.daysLeft} 天'}'
              '${exam.classroom.isEmpty ? '' : ' · ${exam.classroom}'}';
    } else if (_isCountdown) {
      // 2026-11-05（用户 m24837）：倒数日组件的数据页。
      // 显示的是「组件当前会渲染什么」——默认取今天及以后最近的 3 条。
      await CountdownStore.instance.ensureLoaded();
      final now = DateTime.now();
      final shown = CountdownStore.instance.forWidget(now);
      final total = CountdownStore.instance.items.length;
      headline = shown.isEmpty
          ? '还没有倒数日'
          : '${shown.length} 条倒数日';
      detail = shown.isEmpty
          ? '去倒数日页添加，或点下方「添加」'
          : [
              for (final e in shown)
                '${e.title} · ${e.label(now)}',
            ].join('\n');
      if (total > shown.length) {
        detail = '$detail\n（库里共 $total 条）';
      }
    } else {
      final cache = await StorageService.loadCardBalanceCache();
      headline = cache == null
          ? '¥ --'
          : '¥ ${cache.balance.toStringAsFixed(2)}';
      detail = cache == null
          ? '登录后会自动刷新余额'
          : '更新于 ${cache.savedAt.month}-${cache.savedAt.day} '
              '${cache.savedAt.hour.toString().padLeft(2, '0')}:'
              '${cache.savedAt.minute.toString().padLeft(2, '0')}';
    }
    if (!mounted) return;
    setState(() {
      _headline = headline;
      _detail = detail;
      _loading = false;
    });
  }

  Future<void> _refresh() async {
    if (_isExam) {
      await WidgetSyncService.syncExamWidget();
    } else if (_isCountdown) {
      await WidgetSyncService.syncCountdownWidget();
    } else {
      try {
        await ApiService.fetchCardBalance();
      } catch (_) {
        // 未登录或网络异常：继续把已有缓存推给小组件
      }
      await WidgetSyncService.syncCardWidget();
    }
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('小组件数据已刷新')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 2026-11-05（用户 m24837）：三种信息组件统一走这个页，
    // 倒数日组件也在这里设置外观（用户要求：个性化设置在对应小组件页面）。
    final title = _isExam
        ? '考试倒计时组件'
        : _isCountdown
            ? '倒数日组件'
            : '校园卡余额组件';
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: context.surfaceColor,
                    borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                    border: Border.all(color: context.borderColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _isExam
                                ? Icons.event_note_rounded
                                : _isCountdown
                                    ? Icons.hourglass_bottom_rounded
                                    : Icons.credit_card_rounded,
                            size: 20,
                            color: AppTheme.primaryColor,
                          ),
                          const SizedBox(width: 8),
                          Text(title,
                              style: TextStyle(
                                  fontSize: AppTheme.fontSmall,
                                  fontWeight: FontWeight.w600,
                                  color: context.textSecondary)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(_headline,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: context.textPrimary)),
                      const SizedBox(height: 4),
                      Text(_detail,
                          style: TextStyle(
                              fontSize: AppTheme.fontSmall, color: context.textTertiary)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _refresh,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusSm)),
                    side: BorderSide(color: context.borderColor),
                  ),
                  child: Text('立即刷新小组件数据',
                      style: TextStyle(
                          fontSize: AppTheme.fontBody, color: context.textPrimary)),
                ),
                const SizedBox(height: 12),
                // 2026-11-05（用户 m24837）：倒数日组件的添加/管理入口。
                // 「添加」跳倒数日页；「管理」同页。用户在组件页就能完成
                // 「新建 → 绑定 → 调整外观」的完整闭环，不用来回切页面。
                if (_isCountdown) ...[
                  OutlinedButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const CountdownPage()),
                      );
                    },
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusSm)),
                      side: BorderSide(color: context.borderColor),
                    ),
                    child: Text('添加 / 管理倒数日',
                        style: TextStyle(
                            fontSize: AppTheme.fontBody, color: context.textPrimary)),
                  ),
                  const SizedBox(height: 12),
                ],
                // 外观设置：放在这个组件自己的页面里（用户明确要求）。
                WidgetAppearanceEditor(
                  kind: _widgetKindName,
                  title: '组件外观',
                  onSync: () => _isExam
                      ? WidgetSyncService.syncExamWidget()
                      : _isCountdown
                          ? WidgetSyncService.syncCountdownWidget()
                          : WidgetSyncService.syncCardWidget(),
                ),
              ],
            ),
    );
  }

}
