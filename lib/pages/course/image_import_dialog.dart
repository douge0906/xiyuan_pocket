import 'package:flutter/material.dart';

import '../../services/ocr/recognized_course.dart';
import '../../theme/app_theme.dart';
import 'course_form_sheet.dart';

/// 图片识别导入确认面板（任务 T3）：仿照实验课导入选择样式。
///
/// 识别出的候选课程先全部列出，默认只选「时间/周次完整」的候选；用户可以：
///   · 勾选 / 取消某一门；
///   · 点「编辑」打开课程表单改名、改星期/节次/周次/教室/教师；
///   · 全选可导入 / 清空。
/// 未知星期/节次/周次的候选会被标为「需补全」，不能直接导入。
/// 确认后回传选中并修改过的候选，由页面并集写入当前课表（不替换原有课程）。
class ImageImportDialog extends StatefulWidget {
  const ImageImportDialog({
    super.key,
    required this.courses,
    this.autoConverted = 0,
  });

  final List<RecognizedCourse> courses;

  /// 已按实验室对照表自动换掉的教室数（去重后的原值个数）。
  final int autoConverted;

  @override
  State<ImageImportDialog> createState() => _ImageImportDialogState();
}

class _ImageImportDialogState extends State<ImageImportDialog> {
  static const List<String> _weekdays = [
    '',
    '一',
    '二',
    '三',
    '四',
    '五',
    '六',
    '日',
  ];

  late final List<RecognizedCourse> _items;
  late final Set<String> _picked;

  /// 用对象身份做 key，不把列表下标拼进来。删除一条后其它对象的 key 不变，
  /// 不会出现「删第 1 条，后面全部变未选中」的连锁错乱。
  String _key(RecognizedCourse c) => '${identityHashCode(c)}';

  @override
  void initState() {
    super.initState();
    _items = [for (final c in widget.courses) c.copy()];
    // 默认一个都不选：识别结果有可能整段错位（例如把表头当课程名），
    // 全选默认会把错课程直接写进课表。让用户自己逐条确认。
    _picked = <String>{};
  }

  String _sessionLine(RecognizedCourse c) {
    final slotText = c.startSlot >= 1 && c.endSlot >= c.startSlot
        ? '第${c.startSlot}-${c.endSlot}节'
        : '节次未识别';
    final when = c.weekday >= 1 && c.weekday <= 7
        ? '周${_weekdays[c.weekday]} $slotText'
        : '$slotText，星期未识别';
    final wk = c.weeks.isNotEmpty ? c.weeks : '周次未识别';
    return '$when · $wk';
  }

  String _missingText(RecognizedCourse c) {
    final missing = <String>[];
    if (c.weekday < 1 || c.weekday > 7) missing.add('星期');
    if (c.startSlot < 1 || c.endSlot < c.startSlot || c.endSlot > 12) {
      missing.add('节次');
    }
    if (c.weeks.trim().isEmpty) missing.add('周次');
    return missing.isEmpty ? '' : '需补全：${missing.join('、')}';
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _toggle(RecognizedCourse c) {
    if (!c.isReadyToImport) {
      _toast('这门课还缺少${_missingText(c)}，请先点「编辑」补全');
      return;
    }
    final key = _key(c);
    setState(() {
      if (_picked.contains(key)) {
        _picked.remove(key);
      } else {
        _picked.add(key);
      }
    });
  }

  void _openEditor(int index) {
    final c = _items[index];
    final oldKey = _key(c);
    showCourseFormSheet(
      context,
      course: c.toDraftCourse(),
      onSave: (edited) {
        if (!mounted) return;
        setState(() {
          _items[index] = RecognizedCourse(
            name: edited.name,
            teacher: edited.teacher,
            classroom: edited.classroom,
            // 编辑课程的页面没有班级/学年输入框，但这两个字段不能因此丢失；
            // 候选卡片上的班级、学年仍要能写进正式 Course。
            className: c.className,
            academicYear: c.academicYear,
            academicTerm: c.academicTerm,
            weekday: edited.weekday,
            startSlot: edited.startSlot,
            endSlot: edited.endSlot,
            weeks: edited.weeks,
          );
          // 编辑后对象变了，选中状态跟着新对象走；若编辑后仍缺字段，
          // 不能恢复选中，避免把不完整时间再次带进课表。
          if (_picked.remove(oldKey) && _items[index].isReadyToImport) {
            _picked.add(_key(_items[index]));
          }
        });
      },
      // 候选场景的「删除」= 从本次导入列表里移除，不写回课表。
      onDelete: (_) {
        if (!mounted) return;
        setState(() {
          // 其它候选的 key 基于对象身份，不会因为列表前移而变化。
          _picked.remove(_key(_items[index]));
          _items.removeAt(index);
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : context.textPrimary;
    final sub = isDark ? Colors.grey.shade400 : const Color(0xFF6B7280);
    final width = (MediaQuery.of(context).size.width - 96).clamp(280.0, 420.0);
    final pickedCount = _items.where((c) => _picked.contains(_key(c))).length;

    return AlertDialog(
      backgroundColor: context.cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(color: AppTheme.cardStrokeColor(isDark)),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 12, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      title: Row(
        children: [
          Icon(Icons.image_search_rounded,
              size: 20, color: AppTheme.primaryColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text('识别到的课程',
                style: TextStyle(
                    fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w600)),
          ),
          Text('$pickedCount / ${_items.length} 门',
              style: TextStyle(fontSize: AppTheme.fontSmall, color: sub)),
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
      content: SizedBox(
        width: width,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                  widget.autoConverted > 0
                      ? '勾选要添加的课程；${widget.autoConverted} 个实验室已换成「楼栋+房号」，'
                          '点「编辑」可改。'
                      : '勾选要添加的课程；点「编辑」可修改识别结果。',
                  style: TextStyle(fontSize: AppTheme.fontSmall, color: sub)),
              const SizedBox(height: 8),
              // 识别结果可能整段错位（把表头当课程名）或漏读周次/节次，
              // 导入前必须让用户知道要逐条核对，不能默认信任。
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: context.warningColor.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  border: Border.all(
                      color: context.warningColor.withValues(alpha: .35)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline_rounded,
                        size: 16, color: context.warningColor),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '识别结果有出错风险，请仔细校对后再勾选本班级的实验课。',
                        style: TextStyle(
                            fontSize: AppTheme.fontSmall,
                            height: 1.4,
                            color: context.warningColor),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('候选课程',
                      style: TextStyle(
                          fontSize: AppTheme.fontSmall,
                          fontWeight: FontWeight.w600,
                          color: fg)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() => _picked = {
                          for (final c in _items)
                            if (c.isReadyToImport) _key(c)
                        }),
                    child: const Text('全选可导入'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _picked = <String>{}),
                    child: const Text('清空'),
                  ),
                ],
              ),
              for (var i = 0; i < _items.length; i++)
                _courseCard(context, i, _items[i], isDark, fg, sub),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消', style: TextStyle(color: Colors.grey)),
        ),
        FilledButton(
          onPressed: pickedCount == 0
              ? null
              : () {
                  final picked = <RecognizedCourse>[];
                  for (var i = 0; i < _items.length; i++) {
                    if (_picked.contains(_key(_items[i]))) {
                      picked.add(_items[i]);
                    }
                  }
                  Navigator.of(context).pop(picked);
                },
          child: const Text('添加'),
        ),
      ],
    );
  }

  Widget _courseCard(
    BuildContext context,
    int index,
    RecognizedCourse c,
    bool isDark,
    Color fg,
    Color sub,
  ) {
    final key = _key(c);
    final on = _picked.contains(key);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          onTap: () => _toggle(c),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
            decoration: BoxDecoration(
              color: on
                  ? AppTheme.primaryColor.withValues(alpha: 0.08)
                  : context.subtleFill,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              border: Border.all(
                color: on ? AppTheme.primaryColor : context.borderColor,
                width: on ? 1.4 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  on
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: on ? AppTheme.primaryColor : sub,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.name,
                          style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              fontWeight: FontWeight.w600,
                              color: fg)),
                      const SizedBox(height: 4),
                      Text(_sessionLine(c),
                          style: TextStyle(
                              fontSize: AppTheme.fontCaption, color: sub)),
                      if (!c.isReadyToImport)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            _missingText(c),
                            style: TextStyle(
                              fontSize: AppTheme.fontCaption,
                              color: AppTheme.danger,
                            ),
                          ),
                        ),
                      if (c.className.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text('班级：${c.className}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: AppTheme.fontCaption,
                                  color: AppTheme.primaryColor)),
                        ),
                      if (c.classroom.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text('教室：${c.classroom}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: AppTheme.fontCaption, color: sub)),
                        ),
                      if (c.teacher.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text('教师：${c.teacher}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: AppTheme.fontCaption, color: sub)),
                        ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => _openEditor(index),
                  child: const Text('编辑',
                      style: TextStyle(fontSize: AppTheme.fontSmall)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
