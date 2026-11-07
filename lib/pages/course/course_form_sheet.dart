import 'package:flutter/material.dart';
import '../../models/course_model.dart';
import '../../services/course_storage.dart';
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
//     模型层的 [kMaxCourseWeeks]（`course_model.dart`），页面改用它；
//     2026-11-04 又从本文件搬到模型层，因为冲突检测与周次下拉也要用。
//   · 保存/删除仍归页面（要写 courseProvider + 重排提醒）→ 经回调回传；
//   · courseField 复用了导入模块的字段组件，避免重复实现。
//
// ⚠️ 保持既有行为：weekType / pattern 在表单里继承课程原值，
//    原实现就没有对应控件，本次不新增（不擅自加功能）。

/// 添加 / 编辑课程表单（底部弹出）。
///
/// 表单关闭后（含退场动画）会自动释放内部控制器。
///
/// [course] 为 null 表示新增；[presetWeekday] 等用于课表格子点击时预填。
/// [onSave] 保存回调、[onDelete] 删除回调（均归页面实现）。
/// 打开添加 / 编辑课程页（v1.6.8：由居中弹窗改为**完整页面**）。
///
/// 表单内容、字段、校验与弹窗版完全一致，只是换了承载容器 —— 弹窗在小屏上
/// 常被键盘顶到只剩半屏，而这张表单很长（一周七天 + 25 个周数方块），
/// 页面版滚动舒展得多。
void showCourseFormSheet(
  BuildContext context, {
  Course? course,
  int? presetWeekday,
  int? presetStartSlot,
  int? presetEndSlot,
  required void Function(Course course) onSave,
  required void Function(Course course) onDelete,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _CourseFormPage(
        course: course,
        presetWeekday: presetWeekday,
        presetStartSlot: presetStartSlot,
        presetEndSlot: presetEndSlot,
        onSave: onSave,
        onDelete: onDelete,
      ),
    ),
  );
}

/// 添加 / 编辑课程页。
class _CourseFormPage extends StatefulWidget {
  const _CourseFormPage({
    this.course,
    this.presetWeekday,
    this.presetStartSlot,
    this.presetEndSlot,
    required this.onSave,
    required this.onDelete,
  });

  final Course? course;
  final int? presetWeekday;
  final int? presetStartSlot;
  final int? presetEndSlot;
  final void Function(Course course) onSave;
  final void Function(Course course) onDelete;

  @override
  State<_CourseFormPage> createState() => _CourseFormPageState();
}

class _CourseFormPageState extends State<_CourseFormPage> {
  late final TextEditingController nameCtl =
      TextEditingController(text: widget.course?.name ?? '');
  late final TextEditingController teacherCtl =
      TextEditingController(text: widget.course?.teacher ?? '');
  late final TextEditingController roomCtl =
      TextEditingController(text: widget.course?.classroom ?? '');
  // 🔴 2026-10-13：widget.course.weekday 在「每天/工作日」课程里是哨兵值（0 / -1），
  // 直接当下拉值会越界（debug 断言崩溃、release 空白）。
  // 这里只取 1..7，模式本身由 pattern 决定。
  //
  // 🔴 2026-10-14 修复：原写法 `(widget.course?.weekday ?? 1) >= 1 && ... ? widget.course!.weekday : 1`
  //    在「新增课程且未预填星期」时（设置页 → 课程管理 → 添加课程）两个条件恒真，
  //    直接走到 `widget.course!` —— widget.course 为 null 抛 TypeError，弹窗整个不出现
  //    （用户现象：点「添加课程」毫无反应）。
  late int weekday;
  late CoursePattern pattern;
  late CourseWeekType weekType;
  late int startSlot;
  late int endSlot;
  late Set<int> selectedWeeks;
  late int colorValue;

  @override
  void initState() {
    super.initState();
    // 初始化放在 initState：这里能用局部变量 c，Dart 的空安全推断才认得出
    // 「c != null && … ? c.weekType : …」之后 c 一定非空（写成 widget.course
    // 的话每次访问都是 getter 调用，推断失效，会报 unchecked_use_of_nullable_value）。
    final c = widget.course;
    pattern = c?.pattern ?? CoursePattern.fixed;
    // 🔴 weekday 的取值：
    //    · fixed（固定星期）→ 取 1..7 的真实星期；
    //    · daily / workday → 保持哨兵（0 / -1），由 pattern 决定渲染哪些天。
    //
    //    之前这里统一回落成 1 → 「每天」的课程被改写成「周一」，
    //    而 pattern 仍是 daily → 课表只画周一、提醒却按 7 天算。
    final rawWeekday = c?.weekday ?? 1;
    weekday = widget.presetWeekday ??
        ((pattern == CoursePattern.fixed && rawWeekday >= 1 && rawWeekday <= 7)
            ? rawWeekday
            : 1);
    weekType = c?.weekType ?? CourseWeekType.every;
    startSlot = widget.presetStartSlot ?? c?.startSlot ?? 1;
    endSlot = widget.presetEndSlot ?? c?.endSlot ?? 2;
    if (endSlot < startSlot) endSlot = startSlot;
    // 周数选择（方块点击式）：每周时按所选周数；单/双周时忽略具体周数。
    selectedWeeks = (c != null && c.weekType == CourseWeekType.every)
        ? (parseWeeks(c.weeks) ?? {for (int i = 1; i <= 16; i++) i})
        : {for (int i = 1; i <= 16; i++) i};
    colorValue = c?.colorValue ?? coursePalette[0];
  }

  @override
  void dispose() {
    nameCtl.dispose();
    teacherCtl.dispose();
    roomCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: context.scaffoldColor,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text(
          widget.course == null ? '添加课程' : '编辑课程',
          style: TextStyle(
              fontSize: AppTheme.fontHeading,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : AppTheme.textPrimaryLight),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
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
              const SizedBox(height: 12),
              Text(
                widget.course == null ? '添加课程' : '编辑课程',
                style: TextStyle(
                    fontSize: AppTheme.fontHeading,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : AppTheme.textPrimaryLight), // 顶层函数无 context
              ),
              const SizedBox(height: 12),
              courseField('课程名称', TextField(
                controller: nameCtl,
                decoration: const InputDecoration(hintText: '如：高等数学'),
              ), isDark),
              const SizedBox(height: 8),
              courseField('教师', TextField(
                controller: teacherCtl,
                decoration: const InputDecoration(hintText: '选填'),
              ), isDark),
              const SizedBox(height: 8),
              courseField('教室', TextField(
                controller: roomCtl,
                decoration: const InputDecoration(hintText: '如：尚善楼 201'),
              ), isDark),
              const SizedBox(height: 8),
              courseField('星期', DropdownButtonFormField<int>(
                value: weekday,
                items: List.generate(
                    7, (i) => DropdownMenuItem(value: i + 1, child: Text(courseDayLabels[i]))),
                onChanged: (v) => setState(() => weekday = v ?? weekday),
                decoration: const InputDecoration(),
              ), isDark),
              const SizedBox(height: 8),
              _expandSection(
                context,
                title: '节数：第 $startSlot 节 到 第 $endSlot 节',
                isDark: isDark,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('从第几节开始',
                        style: TextStyle(
                            fontSize: AppTheme.fontSmall,
                            color: isDark ? Colors.grey.shade400 : const Color(0xFF6B7280))),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: List.generate(12, (i) {
                        final n = i + 1;
                        final on = startSlot == n;
                        return CourseNumberChip(
                          label: '$n',
                          selected: on,
                          onTap: () => setState(() {
                            startSlot = n;
                            if (endSlot < startSlot) endSlot = startSlot;
                          }),
                        );
                      }),
                    ),
                    const SizedBox(height: 8),
                    Text('到第几节结束',
                        style: TextStyle(
                            fontSize: AppTheme.fontSmall,
                            color: isDark ? Colors.grey.shade400 : const Color(0xFF6B7280))),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: List.generate(12, (i) {
                        final n = i + 1;
                        final disabled = n < startSlot;
                        final on = endSlot == n && !disabled;
                        return CourseNumberChip(
                          label: '$n',
                          selected: on,
                          disabled: disabled,
                          onTap: disabled ? null : () => setState(() => endSlot = n),
                        );
                      }),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
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
                                fontSize: AppTheme.fontSmall,
                                color: isDark
                                    ? Colors.grey.shade500
                                    : const Color(0xFF9CA3AF))),
                      )
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: List.generate(
                                CourseStorage.weekCountCache, (i) {
                              final w = i + 1;
                              final on = selectedWeeks.contains(w);
                              return CourseNumberChip(
                                label: '$w',
                                selected: on,
                                onTap: () => setState(() {
                                  if (on) {
                                    selectedWeeks.remove(w);
                                  } else {
                                    selectedWeeks.add(w);
                                  }
                                }),
                              );
                            }),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              TextButton(
                                onPressed: () => setState(() => selectedWeeks = {
                                      for (int i = 1;
                                          i <= CourseStorage.weekCountCache;
                                          i++)
                                        i
                                    }),
                                child: const Text('全选', style: TextStyle(fontSize: AppTheme.fontSmall)),
                              ),
                              TextButton(
                                // 🔴 2026-11-04 审查 P0：这里原来是
                                //    `selectedWeeks.clear()`。清空之后保存，
                                //    `formatWeeks({})` 返回空串 → `weeks = ''`
                                //    → `parseWeeks('')` 返回 null → 而 null 在
                                //    `isActiveOnWeek` 里的语义是「每周都上」。
                                //    用户操作是「一周都不上」，落库却是「全部周都上」，
                                //    而且没有任何提示 —— 这门课随后会出现在全部 25 周
                                //    的课表、提醒、待办和桌面小组件里。
                                //    改成「重置为第 1 周」：保留一个合法的非空选择，
                                //    想改周次直接点 chip 即可。
                                onPressed: () => setState(() => selectedWeeks = {1}),
                                child: const Text('清空', style: TextStyle(fontSize: AppTheme.fontSmall)),
                              ),
                            ],
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              _expandSection(
                context,
                title: '主题色',
                isDark: isDark,
                leading: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    // v1.6.9：跟随课节色块色彩方案，选到的颜色 = 课表里真实看到的颜色
                    color: courseColorFor(colorValue, CourseStorage.schemeCache),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: isDark ? Colors.grey.shade600 : context.borderColor),
                  ),
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: coursePalette.map((c) {
                    final selected = c == colorValue;
                    return GestureDetector(
                      onTap: () => setState(() => colorValue = c),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: courseColorFor(c, CourseStorage.schemeCache),
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
              const SizedBox(height: 14),
              Row(
                children: [
                  if (widget.course != null)
                    Expanded(
                      child: OutlinedButton(
                        // v2.4.0：与课程格长按删除保持一致，删除前二次确认，
                        // 避免编辑页里误触「删除」即刻丢课。
                        // 2026-11-04 审查 P2：**先问再关页**。原来顺序反了
                        // （先 pop 再弹框），点「取消」时编辑页已经没了。
                        // （widget.course 是 getter，空安全推断不跨它 —— 需 ! ）
                        onPressed: () async {
                          final course = widget.course;
                          if (course == null) return;
                          final ok = await askDeleteCourse(context, course);
                          if (!ok) return;
                          // 用 `context.mounted` 而不是 State.mounted：
                          // 这里跨了 await，lint 只认与 BuildContext 绑定的那个。
                          if (!context.mounted) return;
                          Navigator.of(context).pop();
                          widget.onDelete(course);
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: const BorderSide(color: Colors.red),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(AppTheme.radiusMd)),
                        ),
                        child: const Text('删除'),
                      ),
                    ),
                  if (widget.course != null) const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: () {
                        final name = nameCtl.text.trim();
                        if (name.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
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
                          // 🔴 2026-11-04 审查 P0：空集合会被 `formatWeeks`
                          //    写成空串，而空串在 `parseWeeks` 里等于 null、
                          //    在 `isActiveOnWeek` 里等于「每周都上」——
                          //    与用户「清空」的意图正好相反。落盘前必须拦住，
                          //    否则救不回来（界面上看不出哪门课是坏的）。
                          if (selectedWeeks.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('请至少选择一周')));
                            return;
                          }
                          weeksText = formatWeeks(selectedWeeks);
                        }
                        final newCourse = Course(
                          id: widget.course?.id ?? 'm_${DateTime.now().microsecondsSinceEpoch}',
                          name: name,
                          teacher: teacherCtl.text.trim(),
                          classroom: roomCtl.text.trim(),
                          // daily / workday 保留哨兵（0 / -1），
                          // 由 pattern 决定渲染；fixed 才用具体星期。
                          weekday: pattern == CoursePattern.fixed
                              ? weekday
                              : (pattern == CoursePattern.daily ? 0 : -1),
                          startSlot: startSlot,
                          endSlot: endSlot,
                          weeks: weeksText,
                          colorValue: colorValue,
                          source: widget.course?.source ?? CourseSource.manual,
                          weekType: weekType,
                          pattern: pattern,
                        );
                        Navigator.of(context).pop();
                        widget.onSave(newCourse);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppTheme.radiusMd)),
                      ),
                      child: Text(widget.course == null ? '添加' : '保存'),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
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
  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: context.cardColor,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(
            color: isDark ? Colors.white12 : const Color(0xFFE8E8EE)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题行 + 右上角关闭
              Row(
                children: [
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      // v1.6.9：详情卡里的小色块同样跟随色彩方案
                      color: courseColorFor(course.colorValue,
                          CourseStorage.schemeCache),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      course.name,
                      style: TextStyle(
                          fontSize: AppTheme.fontTitle,
                          fontWeight: FontWeight.bold,
                          color: context.textPrimary),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    icon: Icon(Icons.close_rounded,
                        size: 20,
                        color: isDark
                            ? Colors.grey.shade500
                            : const Color(0xFF9CA3AF)),
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (course.teacher.isNotEmpty)
                        _detailRow(Icons.person_outline_rounded, '教师',
                            course.teacher, isDark),
                      if (course.classroom.isNotEmpty)
                        _detailRow(Icons.place_outlined, '地点',
                            course.classroom, isDark),
                      _detailRow(Icons.schedule_rounded, '节次',
                          '第${course.startSlot}-${course.endSlot}节', isDark),
                      _detailRow(
                          Icons.date_range_outlined,
                          '周次',
                          course.weeks.isEmpty ? '全部' : course.weeks,
                          isDark),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
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
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusMd)),
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
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusMd)),
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
    ),
  );
}

/// 只弹「删除课程？」确认框，返回用户的选择；不执行删除。
///
/// 2026-11-04 审查 P2：编辑页原来先 `Navigator.pop()` 再调 `onDelete`，
/// 而 `onDelete` 里才弹确认框 —— 用户看到的是「页面先关掉、确认框才冒出来」，
/// 点「取消」也回不去已经关掉的编辑页，等于问了个无效问题。
/// 现在把「问」和「删」拆开，调用方先问、拿到 true 再决定要不要 pop。
Future<bool> askDeleteCourse(BuildContext context, Course course) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除课程'),
      content: Text('确定要删除「${course.name}」吗？'),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('删除', style: TextStyle(color: Colors.red)),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// 删除前二次确认（原 `_confirmDeleteCourse`；详情卡等就地删除的场景用）。
Future<void> confirmDeleteCourse(
  BuildContext context,
  Course course, {
  required void Function(Course course) onConfirmed,
}) async {
  if (await askDeleteCourse(context, course)) onConfirmed(course);
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
                  fontSize: AppTheme.fontBody,
                  color: isDark ? Colors.grey.shade400 : const Color(0xFF6B7280))),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                  fontSize: AppTheme.fontBody,
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
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      border: Border.all(color: context.borderColor),
    ),
    child: Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: Text(
          title,
          style: TextStyle(
              fontSize: AppTheme.fontBody,
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