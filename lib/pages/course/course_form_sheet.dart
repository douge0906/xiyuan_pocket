import 'package:flutter/material.dart';
import '../../models/course_model.dart';
import '../../theme/app_theme.dart';
import '../../widgets/course_day_header.dart';
import '../../widgets/course_grid_widgets.dart';
import 'course_import_dialogs.dart' show courseField;

// 课程表单与详情浮层（v1.0.0 从 course_table_home_page.dart 剥离）。
//
// 抽出两块：**添加/编辑表单**（_showCourseSheet，299 行）与**课程详情卡**
// （_showCourseDetail，98 行），以及只被它们使用的三个辅助
// （_detailRow / _confirmDeleteCourse / _expandSection）。
//
// 抽取时确认的耦合点与处理：
//   · _maxWeeks 是**页面共享常量**（选择周数、跳转周次都要用）→ 提升为
//     本模块顶层公开常量 [kMaxCourseWeeks]，页面改用它，两处共用同一值；
//   · 保存/删除仍归页面（要写 courseProvider + 重排提醒）→ 经回调回传；
//   · courseField 复用了导入模块的字段组件，避免重复实现。
//
// ⚠️ 保持既有行为：weekType / pattern 在表单里继承课程原值，
//    原实现就没有对应控件，本次不新增（不擅自加功能）。

/// 一学期最大周数（原 course_table_home_page 的 `_maxWeeks`）。
const int kMaxCourseWeeks = 25;

/// 添加 / 编辑课程表单（底部弹出）。
///
/// 表单关闭后（含退场动画）会自动释放内部控制器。
///
/// [course] 为 null 表示新增；[presetWeekday] 等用于课表格子点击时预填。
/// [onSave] 保存回调、[onDelete] 删除回调（均归页面实现）。
void showCourseFormSheet(
  BuildContext context, {
  Course? course,
  int? presetWeekday,
  int? presetStartSlot,
  int? presetEndSlot,
  required void Function(Course course) onSave,
  required void Function(Course course) onDelete,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final nameCtl = TextEditingController(text: course?.name ?? '');
  final teacherCtl = TextEditingController(text: course?.teacher ?? '');
  final roomCtl = TextEditingController(text: course?.classroom ?? '');
  int weekday = presetWeekday ?? course?.weekday ?? 1;
  CoursePattern pattern = course?.pattern ?? CoursePattern.fixed;
  CourseWeekType weekType = course?.weekType ?? CourseWeekType.every;
  int startSlot = presetStartSlot ?? course?.startSlot ?? 1;
  int endSlot = presetEndSlot ?? course?.endSlot ?? 2;
  if (endSlot < startSlot) endSlot = startSlot;
  // 周数选择（方块点击式）：每周时按所选周数；单/双周时忽略具体周数。
  Set<int> selectedWeeks = (course != null && course.weekType == CourseWeekType.every)
      ? (parseWeeks(course.weeks) ?? {for (int i = 1; i <= 16; i++) i})
      : {for (int i = 1; i <= 16; i++) i};
  int colorValue = course?.colorValue ?? coursePalette[0];

  // 等弹窗完全关闭（含退场动画）后再释放控制器：
  // 若在调用处直接 dispose，退场动画期间 TextField 仍会读取 controller，
  // 会抛 'A TextEditingController was used after being disposed'。
  // v1.1.1：改为**居中弹窗**（用户要求，此前是底部上滑的 sheet）
  showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setModal) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 660),
          child: Container(
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(20),
        ),
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                course == null ? '添加课程' : '编辑课程',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : AppTheme.textPrimaryLight), // 顶层函数无 context
              ),
              const SizedBox(height: 16),
              courseField('课程名称', TextField(
                controller: nameCtl,
                decoration: const InputDecoration(hintText: '如：高等数学'),
              ), isDark),
              const SizedBox(height: 12),
              courseField('教师', TextField(
                controller: teacherCtl,
                decoration: const InputDecoration(hintText: '选填'),
              ), isDark),
              const SizedBox(height: 12),
              courseField('教室', TextField(
                controller: roomCtl,
                decoration: const InputDecoration(hintText: '如：尚善楼 201'),
              ), isDark),
              const SizedBox(height: 12),
              courseField('星期', DropdownButtonFormField<int>(
                value: weekday,
                items: List.generate(
                    7, (i) => DropdownMenuItem(value: i + 1, child: Text(courseDayLabels[i]))),
                onChanged: (v) => setModal(() => weekday = v ?? weekday),
                decoration: const InputDecoration(),
              ), isDark),
              const SizedBox(height: 12),
              _expandSection(
                context,
                title: '节数：第 $startSlot 节 到 第 $endSlot 节',
                isDark: isDark,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('从第几节开始',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: isDark ? Colors.grey.shade400 : const Color(0xFF6B7280))),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: List.generate(12, (i) {
                        final n = i + 1;
                        final on = startSlot == n;
                        return CourseNumberChip(
                          label: '$n',
                          selected: on,
                          onTap: () => setModal(() {
                            startSlot = n;
                            if (endSlot < startSlot) endSlot = startSlot;
                          }),
                        );
                      }),
                    ),
                    const SizedBox(height: 12),
                    Text('到第几节结束',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: isDark ? Colors.grey.shade400 : const Color(0xFF6B7280))),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: List.generate(12, (i) {
                        final n = i + 1;
                        final disabled = n < startSlot;
                        final on = endSlot == n && !disabled;
                        return CourseNumberChip(
                          label: '$n',
                          selected: on,
                          disabled: disabled,
                          onTap: disabled ? null : () => setModal(() => endSlot = n),
                        );
                      }),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _expandSection(
                context,
                title: weekType == CourseWeekType.every
                    ? (selectedWeeks.isEmpty
                        ? '请选择上课周数'
                        : '上课周数：${formatWeeks(selectedWeeks)}')
                    : '上课周数：${weekType.label}（1-16周）',
                isDark: isDark,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (weekType != CourseWeekType.every)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text('选择「单周」或「双周」时，默认覆盖 1-16 周，无需再选具体周数。',
                            style: TextStyle(
                                fontSize: 12.5,
                                color: isDark
                                    ? Colors.grey.shade500
                                    : const Color(0xFF9CA3AF))),
                      )
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: List.generate(kMaxCourseWeeks, (i) {
                              final w = i + 1;
                              final on = selectedWeeks.contains(w);
                              return CourseNumberChip(
                                label: '$w',
                                selected: on,
                                onTap: () => setModal(() {
                                  if (on) {
                                    selectedWeeks.remove(w);
                                  } else {
                                    selectedWeeks.add(w);
                                  }
                                }),
                              );
                            }),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              TextButton(
                                onPressed: () => setModal(() => selectedWeeks = {
                                      for (int i = 1; i <= kMaxCourseWeeks; i++) i
                                    }),
                                child: const Text('全选', style: TextStyle(fontSize: 12.5)),
                              ),
                              TextButton(
                                onPressed: () => setModal(() => selectedWeeks.clear()),
                                child: const Text('清空', style: TextStyle(fontSize: 12.5)),
                              ),
                            ],
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _expandSection(
                context,
                title: '主题色',
                isDark: isDark,
                leading: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: Color(colorValue),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: isDark ? Colors.grey.shade600 : context.borderColor),
                  ),
                ),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: coursePalette.map((c) {
                    final selected = c == colorValue;
                    return GestureDetector(
                      onTap: () => setModal(() => colorValue = c),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: Color(c),
                          shape: BoxShape.circle,
                          border: selected
                              ? Border.all(
                                  color: context.textPrimary,
                                  width: 2.5)
                              : null,
                        ),
                        child: selected
                            ? const Icon(Icons.check_rounded, color: Colors.white, size: 18)
                            : null,
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  if (course != null)
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          // v2.4.0：与课程格长按删除保持一致，删除前二次确认，
                          // 避免编辑弹窗里误触「删除」即刻丢课。
                          onDelete(course);
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: const BorderSide(color: Colors.red),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        child: const Text('删除'),
                      ),
                    ),
                  if (course != null) const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: () {
                        final name = nameCtl.text.trim();
                        if (name.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(content: Text('请填写课程名称')));
                          return;
                        }
                        // 周次文本（与 parseWeeks 互转）
                        String weeksText;
                        if (weekType == CourseWeekType.odd) {
                          weeksText = '1-16周(单)';
                        } else if (weekType == CourseWeekType.even) {
                          weeksText = '1-16周(双)';
                        } else {
                          weeksText = formatWeeks(selectedWeeks);
                        }
                        final newCourse = Course(
                          id: course?.id ?? 'm_${DateTime.now().microsecondsSinceEpoch}',
                          name: name,
                          teacher: teacherCtl.text.trim(),
                          classroom: roomCtl.text.trim(),
                          weekday: weekday,
                          startSlot: startSlot,
                          endSlot: endSlot,
                          weeks: weeksText,
                          colorValue: colorValue,
                          source: course?.source ?? CourseSource.manual,
                          weekType: weekType,
                          pattern: pattern,
                        );
                        Navigator.of(ctx).pop();
                        onSave(newCourse);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: Text(course == null ? '添加' : '保存'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
      ),
      ),
  ).whenComplete(() {
    nameCtl.dispose();
    teacherCtl.dispose();
    roomCtl.dispose();
  });
}

/// 点击课程卡弹出的详情卡（对齐参考 App A）：色块+标题，教师/地点/节次/周次，
/// 底部「删除」「编辑」；编辑按钮再打开原编辑表单。
void showCourseDetailSheet(
  BuildContext context,
  Course course, {
  required void Function(Course course) onDelete,
  required void Function(Course course) onEdit,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: Color(course.colorValue),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    course.name,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: context.textPrimary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (course.teacher.isNotEmpty)
              _detailRow(Icons.person_outline_rounded, '教师', course.teacher, isDark),
            if (course.classroom.isNotEmpty)
              _detailRow(Icons.place_outlined, '地点', course.classroom, isDark),
            _detailRow(Icons.schedule_rounded, '节次',
                '第${course.startSlot}-${course.endSlot}节', isDark),
            _detailRow(Icons.date_range_outlined, '周次',
                course.weeks.isEmpty ? '全部' : course.weeks, isDark),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      onDelete(course);
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Text('删除'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      onEdit(course);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Text('编辑'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// 删除前二次确认（原 `_confirmDeleteCourse`；表单与详情卡共用）。
Future<void> confirmDeleteCourse(
  BuildContext context,
  Course course, {
  required void Function(Course course) onConfirmed,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除课程'),
      content: const Text('确定要删除这门课程吗？'),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('删除', style: TextStyle(color: Colors.red)),
        ),
      ],
    ),
  );
  if (confirmed == true) onConfirmed(course);
}

/// 详情卡里的一行「图标 + 标签 + 值」。
Widget _detailRow(IconData icon, String label, String value, bool isDark) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: isDark ? Colors.grey.shade500 : const Color(0xFF6B7280)),
          const SizedBox(width: 10),
          Text(label,
              style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.grey.shade400 : const Color(0xFF6B7280))),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white : AppTheme.textPrimaryLight), // 顶层函数无 context
            ),
          ),
        ],
      ),
    );

/// 折叠展开项（节数 / 周数 / 主题色）。
Widget _expandSection(
  BuildContext context, {
  required String title,
  required Widget child,
  required bool isDark,
  Widget? leading,
}) {
  return Container(
    decoration: BoxDecoration(
      color: isDark ? Colors.grey.shade900 : Colors.grey.shade50,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.borderColor),
    ),
    child: Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: Text(
          title,
          style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.grey.shade300 : const Color(0xFF374151)),
        ),
        leading: leading,
        iconColor: AppTheme.primaryColor,
        collapsedIconColor: isDark ? Colors.grey.shade500 : Colors.grey.shade600,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [child],
      ),
    ),
  );
}