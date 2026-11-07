import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/todo.dart';
import '../theme/app_theme.dart';
import 'date_pick_dialog.dart';

/// 新增待办弹窗（2026-10-17 第二版）。
///
/// **强制居中盒子**：用户点名的 UI 铁律 —— 表单/弹窗一律用 Dialog，
/// 禁止上滑式底部弹窗；右上角必须能点 × 关闭。
///
/// 第二版改动（用户要求）：
///   · **去掉「类型」选择**；
///   · 时间改成**上下滚轮**（时 / 分），不再用系统时钟盘；
///   · 内容加提示「可省略，填了可以直接点任务查看」。
class AddTodoDialog extends StatefulWidget {
  const AddTodoDialog({
    super.key,
    this.initialDate,
    this.editTodo,
    this.initialTitle,
    this.initialDescription,
    this.initialHour,
    this.initialMinute,
  });

  /// 从某一天进入时预填（可选）。
  final DateTime? initialDate;

  /// 非 null 时进入**编辑模式**（2026-10-31）。
  ///
  /// ⚠️ 原来编辑走的是另一个组件 `AddTodoSheet`（底部抽屉），
  ///    违反项目死律「弹窗一律居中、右上角可关」，而且两套表单字段
  ///    各写各的（滚轮 vs 系统选择器、有无提醒/优先级/重复）。
  ///    现在统一到这一个居中弹窗，编辑与新增**同一套交互**。
  final Todo? editTodo;

  /// 预填标题。
  final String? initialTitle;

  /// 预填描述（内容）。
  final String? initialDescription;

  /// 预填时刻。
  final int? initialHour;

  /// 预填分钟。与 [initialHour] 成对使用。
  final int? initialMinute;

  static Future<Todo?> show(
    BuildContext context, {
    DateTime? initialDate,
    Todo? editTodo,
    String? initialTitle,
    String? initialDescription,
    int? initialHour,
    int? initialMinute,
  }) {
    return showDialog<Todo>(
      context: context,
      barrierDismissible: true,
      builder: (_) => AddTodoDialog(
        initialDate: initialDate,
        editTodo: editTodo,
        initialTitle: initialTitle,
        initialDescription: initialDescription,
        initialHour: initialHour,
        initialMinute: initialMinute,
      ),
    );
  }

  /// 「这条提醒该不该被打回」——把 [_submit] 的守卫逻辑抽成纯函数。
  ///
  /// 规则（2026-11-02）：
  ///   · 没开提醒 → 不拦。
  ///   · 提醒时刻在未来 → 不拦。
  ///   · 提醒时刻已过去，但**编辑的是一条本来就这么旧的历史待办、
  ///     且用户这次没动过时间** → 不拦（用户只想改错别字）。
  ///   · 其余已过期的情况 → 拦下，避免存一条永远不响的提醒。
  @visibleForTesting
  static bool shouldBlockPastReminder({
    required DateTime? reminder,
    required bool isEdit,
    required DateTime? originalReminder,
    required DateTime now,
  }) {
    if (reminder == null) return false;
    if (reminder.isAfter(now)) return false;
    // 原始值一字未动 → 是历史遗留，不是用户这次选的过去时间。
    final untouched = isEdit &&
        originalReminder != null &&
        reminder.isAtSameMomentAs(originalReminder);
    return !untouched;
  }

  @override
  State<AddTodoDialog> createState() => _AddTodoDialogState();

  /// 新建待办时的默认时刻：**下一个整点或半点**。
  ///
  /// 🔴 2026-11-02 之前用的是「此刻」，会制造一个必现死锁：
  ///    用户点「+」不改时间直接保存 → `dueAt` = 此刻整分 →
  ///    `reminder = dueAt - lead` → `reminder.isAfter(now)` 为 false
  ///    （秒数已经走过去）→ 弹「提醒时间已过」→ **存不进去**。
  ///    表现是「打开新增待办就这样，还得先随便改改才能保存」。
  ///
  /// 取整规则：**严格晚于 now 的下一个整点或半点**。
  ///   16:57:30 → 17:00 / 16:27 → 16:30 / 16:29:30 → 16:30 /
  ///   16:30:00 → 17:00 / 23:58 → 次日 00:00。
  ///
  /// 不能用「now + 固定缓冲再取整」：缓冲会把 16:29:30 推到 17:00
  /// （凭空多等半小时），而缓冲太小又会算出等于 now 的时刻 ——
  /// 那样 `reminder.isAfter(now)` 仍为 false，死锁照旧。
  @visibleForTesting
  static DateTime defaultDueAt(DateTime now) {
    const block = 30 * 60; // 半小时 = 1800 秒
    final midnight = DateTime(now.year, now.month, now.day);
    final secs = now.difference(midnight).inSeconds;
    // 向下整除 +1 = 严格大于 now 的下一个边界。
    final next = ((secs ~/ block) + 1) * block;
    return midnight.add(Duration(seconds: next));
  }

  /// 提交时这条待办该不该带「自己的」提醒时间。
  ///
  /// 🔴 课程待办（id 以 `course_` 开头）**不写** `reminderTime`：上课提醒
  ///    统一由 `CourseReminderService` 负责（见
  ///    course_todo_service.dart:310 的审查说明），写了会与「距上课 N 分钟」
  ///    重复响铃；而过去的上课时刻又会让 [shouldBlockPastReminder] 把
  ///    「只改错别字」的编辑拦死。其余待办（含新建）一律带准点提醒。
  @visibleForTesting
  static DateTime? submitReminder({
    required DateTime dueAt,
    required Todo? editTodo,
  }) {
    final isCourseTodo = editTodo?.id.startsWith('course_') ?? false;
    return isCourseTodo ? null : dueAt;
  }
}

class _AddTodoDialogState extends State<AddTodoDialog> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _descCtrl = TextEditingController();

  late DateTime _day;
  late int _hour;
  late int _minute;

  /// true 时盒子内容换成日期选择面板（同一个 Dialog 内切换，不叠第二层）。
  bool _pickingDate = false;

  /// 重复规则（2026-10-18）：null=不重复 / 'daily'=每天 / 'weekly'=每周几。
  String? _repeatType;

  /// 优先级：0=普通，1=重要，2=紧急。
  int _priority = 0;

  /// 「每周几」选中的星期（1=周一 … 7=周日）。
  final Set<int> _weekdays = <int>{};
  String? _err;

  /// 编辑模式下的**原始**提醒时刻（2026-11-02）。
  ///
  /// 🔴 为什么必须记住：`_submit` 里有一条「提醒时间已过就打回」的守卫，
  ///    防止用户新建一条永远不响的提醒。但对**已经过去的待办**做编辑时
  ///    这条守卫是误伤 —— 用户只想改个错别字，时间本来就在昨天，
  ///    一保存就被弹「提醒时间已过」，除了改时间无路可走。
  ///    有了原始值就能区分「用户主动改了时间」与「时间本来就过期」：
  ///    前者照旧拦截，后者放行（历史记录不该被强行改期）。
  DateTime? _originalReminder;

  late FixedExtentScrollController _hourCtrl;
  late FixedExtentScrollController _minuteCtrl;

  bool get _isEdit => widget.editTodo != null;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final edit = widget.editTodo;
    if (edit != null) {
      // 编辑模式：预填已有数据。
      _day = DateTime(edit.date.year, edit.date.month, edit.date.day);
      // 时间口径与首页显示一致：`reminderTime ?? dueAt`。
      final t = edit.reminderTime ?? edit.dueAt;
      _hour = t?.hour ?? now.hour;
      _minute = t?.minute ?? now.minute;
      _titleCtrl.text = edit.title;
      _descCtrl.text = edit.description ?? '';
      _priority = edit.priority;
      _repeatType = edit.repeatType;
      _weekdays.addAll(edit.repeatDays);
      _originalReminder = edit.reminderTime;
    } else {
      final base = widget.initialDate ?? now;
      _day = DateTime(base.year, base.month, base.day);
      // 🔴 2026-11-02 修：默认时刻原来是「此刻」（now.hour/now.minute）。
      //
      //    后果是一个必现的死循环：用户点「+」什么都不改直接保存 →
      //    dueAt = 此刻整分 → reminder = dueAt − 0 → `reminder.isAfter(now)`
      //    永远为 false（秒数已经走过去）→ 弹「提醒时间已过」→ 存不进去。
      //    用户看到的是「打开就这样，还得先瞎改一下日期才能保存」。
      //
      //    现在落到**下一个整点或半点**（见 [defaultDueAt]）。
      final rounded = AddTodoDialog.defaultDueAt(now);
      final today = DateTime(now.year, now.month, now.day);
      if (_day == today && rounded.day != today.day) {
        // 只在「用户没指定日期」且跨零点时才推进日期。
        _day = DateTime(rounded.year, rounded.month, rounded.day);
      }
      _hour = rounded.hour;
      _minute = rounded.minute;
      // 预填：标题原样填入，时刻通过 [initialHour]/[initialMinute] 显式传入。
      final pre = widget.initialTitle;
      if (pre != null && pre.isNotEmpty) {
        _titleCtrl.text = pre;
      }
      if (widget.initialHour != null) _hour = widget.initialHour!;
      if (widget.initialMinute != null) _minute = widget.initialMinute!;
      final preDesc = widget.initialDescription;
      if (preDesc != null && preDesc.isNotEmpty) {
        _descCtrl.text = preDesc;
      }
    }
    _hourCtrl = FixedExtentScrollController(initialItem: _hour);
    _minuteCtrl = FixedExtentScrollController(initialItem: _minute);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _hourCtrl.dispose();
    _minuteCtrl.dispose();
    super.dispose();
  }

  // 2026-10-18：日期选择改为**在本弹窗内切换内容**，不再开第二层 Dialog
  //（两层叠加时下层白底会从上层四周透出一圈灰边）。
  void _pickDay() => setState(() => _pickingDate = true);

  DateTime get _pickFirst {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 30));
  }

  DateTime get _pickLast => DateTime.now().add(const Duration(days: 730));

  String get _dayLabel {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = _day.difference(today).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '明天';
    if (diff == -1) return '昨天';
    return '${_day.month}月${_day.day}日';
  }

  /// 「11月2日」旁边的「周一」—— 只报日期时用户还要自己算今天星期几。
  String get _weekdayLabel {
    const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return names[_day.weekday - 1];
  }

  /// 把两个滚轮对齐到当前的 [_hour] / [_minute]（不重建 controller）。
  ///
  /// 放在下一帧做：`_submit` 里刚调过 setState，此时滚轮可能还没有 layout，
  /// 直接 `jumpToItem` 会抛 `_positions.isNotEmpty` 断言。
  void _syncWheels() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_hourCtrl.hasClients && _hourCtrl.selectedItem != _hour) {
        _hourCtrl.jumpToItem(_hour);
      }
      if (_minuteCtrl.hasClients && _minuteCtrl.selectedItem != _minute) {
        _minuteCtrl.jumpToItem(_minute);
      }
    });
  }

  void _submit() {
    // 打什么就存什么：时刻请用日历与滚轮显式选择，不对标题做隐式解析。
    final title = _titleCtrl.value.text.trim();
    if (title.isEmpty) {
      setState(() => _err = '请填写待办名称');
      _syncWheels();
      return;
    }
    // 选了「每周」但一天都没勾 → 拦一下，否则规则等于不生效。
    if (_repeatType == 'weekly' && _weekdays.isEmpty) {
      setState(() => _err = '请至少选择一个星期');
      _syncWheels();
      return;
    }
    final desc = _descCtrl.value.text.trim();
    final base = widget.editTodo;

    // 当天的具体时刻（展示用）。
    final dueAt = DateTime(_day.year, _day.month, _day.day, _hour, _minute);

    // 提醒时间：普通待办 = 当天该时刻（默认开启、准点）；课程待办留空，
    // 上课提醒交由 CourseReminderService 统一排程，避免重复响铃与误拦编辑。
    // 是否真正排铃由「通知与提醒」里的全局开关统一门控。
    final reminder = AddTodoDialog.submitReminder(dueAt: dueAt, editTodo: base);
    // 时间已过：明确拦截，不静默存一条永远不响的提醒。
    // 编辑**已经过期**的待办时放行 —— 用户可能只改错别字，时间本就在过去，
    // 不该逼他顺带改期。判据是「这次有没有动过时间」而非「现在是不是过去」。
    final blocked = AddTodoDialog.shouldBlockPastReminder(
      reminder: reminder,
      isEdit: _isEdit,
      originalReminder: _originalReminder,
      now: DateTime.now(),
    );
    if (blocked) {
      setState(() => _err = '提醒时间已过，请调整日期或时间');
      _syncWheels();
      return;
    }

    // 课程待办 reminderTime 为空 → 必须显式清空，否则 copyWith 的 `??`
    // 语义会保留编辑前可能存在的旧提醒时间。
    final clearReminder = reminder == null;

    // 🔴 编辑时必须以**原对象为基底** copyWith，不能新造一个 Todo。
    //
    // 2026-11-04 修：此前这里 `Navigator.pop(Todo(...))` 全新构造，只搬了
    // title/desc/date/dueAt/reminder/priority/repeat 六个字段，
    // `completed` / `completedDay` / `completedDates` 三个完成态字段全部丢失。
    // 而 `TodoRepository.update` 是 `list[idx] = todo;` 整行覆盖 → 编辑一个
    // 已完成待办，它会变回未完成；编辑一条重复待办，它的全部历史打卡被清空。
    // 新建路径 base 为 null，走 else 分支，行为不变。
    final built = base == null
        ? Todo(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            title: title,
            description: desc.isEmpty ? null : desc,
            date: _day,
            dueAt: dueAt,
            reminderTime: reminder,
            remindLeadMinutes: 0,
            priority: _priority,
            repeatType: _repeatType,
            // 只有「每周」才需要 repeatDays：不重复 / 每天写进去是脏数据
            // （`_weekdays` 在「不重复」「每天」chip 上不会被清空）。
            repeatDays: _repeatType == 'weekly'
                ? (_weekdays.toList()..sort())
                : const <int>[],
          )
        : base.copyWith(
            title: title,
            description: desc.isEmpty ? null : desc,
            clearDescription: desc.isEmpty,
            date: _day,
            dueAt: dueAt,
            reminderTime: reminder,
            clearReminder: clearReminder,
            remindLeadMinutes: 0,
            priority: _priority,
            repeatType: _repeatType,
            clearRepeat: _repeatType == null,
            repeatDays: _repeatType == 'weekly'
                ? (_weekdays.toList()..sort())
                : const <int>[],
          );

    Navigator.of(context).pop(built);
  }

  Widget _priorityChip(String label, int value, Color color) {
    final active = _priority == value;
    return GestureDetector(
      onTap: () => setState(() => _priority = value),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: .12) : Colors.transparent,
          border: Border.all(color: active ? color : const Color(0xFFE5E7EB)),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppTheme.fontSmall,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? color : const Color(0xFF6B7280),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = context.surfaceColor;
    final border = isDark ? const Color(0xFF2C2C2C) : const Color(0xFFE5E7EB);
    final hint = isDark ? const Color(0xFF8B8B8B) : const Color(0xFF9CA3AF);
    final labelColor = isDark ? const Color(0xFFA1A1AA) : const Color(0xFF6B7280);

    InputDecoration deco(String hintText) => InputDecoration(
          hintText: hintText,
          hintStyle: TextStyle(fontSize: AppTheme.fontBody, color: hint),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            borderSide: BorderSide(color: border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            borderSide: BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            borderSide: BorderSide(color: AppTheme.primaryColor),
          ),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        );

    // 小节标题：12px 灰字 + 下方 7px 间距。
    // 作用不是「装饰」，而是把六个区块从「一堆长得一样的方框」
    // 变成「有层级的一组设置」—— 没有标签时用户无法一眼扫到某个字段。
    Widget sectionLabel(String text) => Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 7),
          child: Text(
            text,
            style: TextStyle(
              fontSize: AppTheme.fontSmall,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: labelColor,
            ),
          ),
        );

    // 滚轮：两位数字
    Widget wheelColumn({
      required FixedExtentScrollController ctrl,
      required int count,
      required ValueChanged<int> onChanged,
    }) {
      return SizedBox(
        width: 62,
        // 2026-10-18 第二轮：高度仍接近一行，但**上下各露出一点相邻数字**，
        // 作为「这里可以上下转」的提示；边缘用渐变遮罩淡出，避免硬切边。
        // 54 = 当前行 34 + 上下各 10px 的邻居露头。
        height: 58,
        child: ShaderMask(
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.white,
              Colors.white,
              Colors.transparent,
            ],
            // 淡出区间收窄：让上下邻居露出足够多，能看出「还有数字可以转」。
            stops: [0.0, 0.16, 0.84, 1.0],
          ).createShader(rect),
          blendMode: BlendMode.dstIn,
          child: CupertinoPicker(
            scrollController: ctrl,
            itemExtent: 34,
            // 放大倍数压到最小，否则当前值会被上下裁边。
            useMagnifier: true,
            magnification: 1.04,
            // 仍不画上下分隔线：外层 Container 已有 1px 边框。
            selectionOverlay: const SizedBox.shrink(),
            onSelectedItemChanged: onChanged,
            children: [
              for (int i = 0; i < count; i++)
                Center(
                  child: Text(
                    i.toString().padLeft(2, '0'),
                    style: const TextStyle(
                        fontSize: AppTheme.fontHeading, fontWeight: FontWeight.w500),
                  ),
                ),
            ],
          ),
        ),
      );
    }

  /// 重复方式的小胶囊（不重复 / 每天 / 每周）。
  Widget repeatChip(String label, bool active, VoidCallback onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lineColor =
        isDark ? const Color(0xFF2C2C2C) : const Color(0xFFE5E7EB);
    final txtColor =
        isDark ? const Color(0xFFEDEDED) : const Color(0xFF374151);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppTheme.primaryColor : Colors.transparent,
          border: Border.all(color: active ? AppTheme.primaryColor : lineColor),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppTheme.fontSmall,
            color: active ? Colors.white : txtColor,
          ),
        ),
      ),
    );
  }

  /// 弹窗内容宽度（2026-11-03 自适应）。
  ///
  /// 原来写死 330：`minSdk = 21`，320dp 宽的小屏上 `330 + contentPadding(20×2)`
  /// 直接超出屏幕，弹窗左右被裁、按钮点不到。现在取
  /// `min(330, 屏宽 - 48)`，48 = 两侧各留 24 的呼吸位。
  double dialogWidth() {
    final w = MediaQuery.of(context).size.width;
    final max = w - 48;
    return max < 330 ? (max < 200 ? 200 : max) : 330;
  }

  /// 「每周几」的横向圆点（周一到周日，可多选）。
  Widget weekdayDot(int weekday) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lineColor =
        isDark ? const Color(0xFF2C2C2C) : const Color(0xFFE5E7EB);
    final txtColor =
        isDark ? const Color(0xFFEDEDED) : const Color(0xFF6B7280);
    final active = _weekdays.contains(weekday);
    return GestureDetector(
      onTap: () => setState(() {
        if (!_weekdays.remove(weekday)) _weekdays.add(weekday);
      }),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? AppTheme.primaryColor : Colors.transparent,
          shape: BoxShape.circle,
          border: Border.all(color: active ? AppTheme.primaryColor : lineColor),
        ),
        child: Text(
          const ['一', '二', '三', '四', '五', '六', '日'][weekday - 1],
          style: TextStyle(
            fontSize: AppTheme.fontSmall,
            color: active ? Colors.white : txtColor,
          ),
        ),
      ),
    );
  }

    // 日期选择态：同一个盒子里换成月历面板（标题、圆角、边框保持一致）。
    if (_pickingDate) {
      return AlertDialog(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        ),
        contentPadding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
        content: SizedBox(
          width: dialogWidth(),
          child: DatePickPanel(
            initial: _day,
            first: _pickFirst,
            last: _pickLast,
            onCancel: () => setState(() => _pickingDate = false),
            onConfirm: (picked) {
              setState(() {
                _day = DateTime(picked.year, picked.month, picked.day);
                _pickingDate = false;
              });
            },
          ),
        ),
      );
    }

    return AlertDialog(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 14, 8, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      actionsPadding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      title: Row(
        children: [
          Text(_isEdit ? '编辑待办' : '新增待办',
              style: const TextStyle(fontSize: AppTheme.fontTitle, fontWeight: FontWeight.bold)),
          const Spacer(),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded, size: 20),
            tooltip: '关闭',
          ),
        ],
      ),
      content: SizedBox(
        width: dialogWidth(),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ① 名称 —— 视觉焦点。
              //    原先是带边框的普通输入框，和下面五个同样带边框的方框
              //    长得一模一样，用户进来看不出「先写这里」。
              TextField(
                controller: _titleCtrl,
                style: const TextStyle(
                    fontSize: AppTheme.fontTitle, fontWeight: FontWeight.w500, height: 1.3),
                decoration: InputDecoration(
                  hintText: '要做什么？',
                  hintStyle: TextStyle(fontSize: AppTheme.fontTitle, color: hint),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    borderSide: BorderSide(color: border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    borderSide: BorderSide(color: border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    borderSide:
                        BorderSide(color: AppTheme.primaryColor, width: 1.5),
                  ),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                ),
              ),
              const SizedBox(height: 16),

              // ② 时间 —— 日期与时刻**合成一张卡**。
              //    原来「选择日期」和「两个滚轮」是两个独立方框，
              //    中间还隔了 10px，看起来像两件不相干的事：
              //    用户经常只改了日期、忘了改时间，或者反过来。
              sectionLabel('时间'),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: border),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: _pickDay,
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(11)),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
                        child: Row(
                          children: [
                            Text(_dayLabel,
                                style: const TextStyle(
                                    fontSize: AppTheme.fontBody,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(width: 7),
                            Text(_weekdayLabel,
                                style: TextStyle(fontSize: AppTheme.fontSmall, color: hint)),
                            const Spacer(),
                            Text('改日期',
                                style: TextStyle(
                                    fontSize: AppTheme.fontSmall,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.primaryColor)),
                          ],
                        ),
                      ),
                    ),
                    Divider(height: 1, thickness: 1, color: border),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          wheelColumn(
                            ctrl: _hourCtrl,
                            count: 24,
                            onChanged: (v) => setState(() => _hour = v),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Text(':',
                                style: TextStyle(
                                    fontSize: AppTheme.fontHeading,
                                    fontWeight: FontWeight.w600,
                                    color: labelColor)),
                          ),
                          wheelColumn(
                            ctrl: _minuteCtrl,
                            count: 60,
                            onChanged: (v) => setState(() => _minute = v),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // ③ 优先级
              sectionLabel('优先级'),
              Row(
                children: [
                  _priorityChip('普通', 0, const Color(0xFF6B7280)),
                  const SizedBox(width: 6),
                  _priorityChip('重要', 1, const Color(0xFFF59E0B)),
                  const SizedBox(width: 6),
                  _priorityChip('紧急', 2, const Color(0xFFDC2626)),
                ],
              ),
              const SizedBox(height: 16),

              // ④ 重复（2026-10-18 用户要求：三种情况由点击决定展开）
              //   不重复 / 每天 / 每周 → 点「每周」才展开周一到周日的横向选择。
              sectionLabel('重复'),
              Row(
                children: [
                  repeatChip('不重复', _repeatType == null,
                      () => setState(() => _repeatType = null)),
                  const SizedBox(width: 8),
                  repeatChip('每天', _repeatType == 'daily',
                      () => setState(() => _repeatType = 'daily')),
                  const SizedBox(width: 8),
                  repeatChip('每周', _repeatType == 'weekly', () {
                    setState(() {
                      _repeatType = 'weekly';
                      // 首次点「每周」默认勾上当前这一天，避免空选。
                      if (_weekdays.isEmpty) {
                        _weekdays.add(_day.weekday);
                      }
                    });
                  }),
                ],
              ),
              if (_repeatType == 'weekly') ...[
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (var i = 1; i <= 7; i++) weekdayDot(i),
                  ],
                ),
              ],
              const SizedBox(height: 16),

              // ⑤ 备注
              sectionLabel('备注'),
              TextField(
                controller: _descCtrl,
                maxLines: 2,
                style: const TextStyle(fontSize: AppTheme.fontBody, height: 1.4),
                decoration: deco('可省略，填了可以直接点任务查看'),
              ),
              if (_err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline_rounded,
                          size: 15, color: Color(0xFFB91C1C)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(_err!,
                            style: const TextStyle(
                                fontSize: AppTheme.fontSmall,
                                height: 1.4,
                                color: Color(0xFFB91C1C))),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消', style: TextStyle(fontSize: AppTheme.fontBody, color: labelColor)),
        ),
        ElevatedButton(
          onPressed: _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryColor,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          ),
          child: Text(_isEdit ? '保存修改' : '保存',
              style: const TextStyle(fontSize: AppTheme.fontBody, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
