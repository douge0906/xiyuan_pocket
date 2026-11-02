import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/exam_storage.dart';
import '../services/storage_service.dart';
import '../services/widget_sync_service.dart';
import '../theme/app_theme.dart';

enum WidgetInfoKind { exam, card }

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
    final title = _isExam ? '考试倒计时' : '校园卡余额';
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
              ],
            ),
    );
  }

}
