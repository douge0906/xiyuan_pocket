import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/todo.dart';
import '../repositories/todo_repository.dart';
import '../theme/app_theme.dart';

class AddTodoSheet extends StatefulWidget {
  final DateTime initialDate;
  final Todo? editTodo; // 非 null 时进入编辑模式
  const AddTodoSheet({super.key, required this.initialDate, this.editTodo});

  @override
  State<AddTodoSheet> createState() => _AddTodoSheetState();
}

class _AddTodoSheetState extends State<AddTodoSheet> {
  final _titleCtl = TextEditingController();
  final _descCtl = TextEditingController();
  late DateTime _date;
  TimeOfDay? _reminderTime;
  bool _enableReminder = false;
  bool _saving = false;
  bool _success = false;

  bool get _isEdit => widget.editTodo != null;

  @override
  void initState() {
    super.initState();
    // 编辑模式：预填已有数据
    if (widget.editTodo != null) {
      final t = widget.editTodo!;
      _titleCtl.text = t.title;
      _descCtl.text = t.description ?? '';
      _date = t.date;
      if (t.reminderTime != null) {
        _enableReminder = true;
        _reminderTime = TimeOfDay(hour: t.reminderTime!.hour, minute: t.reminderTime!.minute);
      }
    } else {
      _date = widget.initialDate;
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 5)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _reminderTime ?? TimeOfDay.now(),
    );
    if (picked != null) setState(() => _reminderTime = picked);
  }

  Future<void> _save() async {
    if (_saving) return;
    final title = _titleCtl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写待办标题')),
      );
      return;
    }
    if (_enableReminder && _reminderTime == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请选择提醒时间')),
      );
      return;
    }

    DateTime? reminder;
    if (_enableReminder && _reminderTime != null) {
      reminder = DateTime(_date.year, _date.month, _date.day, _reminderTime!.hour, _reminderTime!.minute);
      // 提醒时间已过：明确拦截
      if (!reminder.isAfter(DateTime.now())) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('提醒时间已过，请选择将来的时间')),
        );
        return;
      }
    }

    bool permissionDenied = false;
    if (reminder != null) {
      // v2.4.0：权限被拒时给出引导（此前完全静默，用户会误以为提醒已生效）。
      // 提醒仍会入库与尝试排程，只是明确告知「可能不响」。
      final granted = await TodoRepository.instance.ensureNotificationPermission();
      permissionDenied = !granted;
    }

    final desc = _descCtl.text.trim().isEmpty ? null : _descCtl.text.trim();
    // id 用微秒时间戳，唯一且无随机；notifyId 由 id 确定性推导（见 Todo 模型）。
    final todo = _isEdit
        ? widget.editTodo!.copyWith(
            title: title,
            description: desc,
            date: _date,
            reminderTime: reminder,
            clearReminder: reminder == null, // 关闭提醒时显式清空
          )
        : Todo(
            id: '${DateTime.now().microsecondsSinceEpoch}',
            title: title,
            description: desc,
            date: _date,
            reminderTime: reminder,
          );

    setState(() => _saving = true);
    try {
      // 落库 + 通知调度全部交由仓库编排（新增即排、编辑先取消旧通知再重排）。
      if (_isEdit) {
        await TodoRepository.instance.update(todo);
      } else {
        await TodoRepository.instance.add(todo);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
      return;
    }

    if (!mounted) return;
    setState(() => _success = true);
    // 通知权限被拒：先给出引导（可一键去系统设置），再收起面板。
    if (permissionDenied) {
      await _showPermissionGuide(context);
      if (!mounted) return;
    }
    await Future.delayed(const Duration(milliseconds: 520));
    if (!mounted) return;
    Navigator.of(context).pop(_date);
  }

  /// 权限未授予时的引导弹窗：解释为何需要权限，并提供「去设置」入口。
  Future<void> _showPermissionGuide(BuildContext context) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.notifications_active_outlined,
                color: AppTheme.primaryColor),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('提醒可能无法响铃',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        content: const Text(
          '待办提醒需要「通知权限」和「闹钟/精确闹钟权限」才能正常响铃与震动。'
          '若未授予，提醒可能静音或延迟。请在设置中开启后重试。',
          style: TextStyle(fontSize: 12.5, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('稍后'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (go == true && mounted) {
      await openAppSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1E1E1E) : Colors.white;
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
        child: _success
            ? _buildSuccess(isDark)
            : SingleChildScrollView(
                key: const ValueKey('form'),
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
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _isEdit ? '编辑待办' : '新增待办',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: context.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            _field('标题', TextField(
              controller: _titleCtl,
              decoration: InputDecoration(
                hintText: _isEdit ? '修改待办标题' : '如：交作业',
              ),
            ), isDark),
            const SizedBox(height: 12),
            _field('描述（可选）', TextField(
              controller: _descCtl,
              decoration: const InputDecoration(hintText: '补充说明'),
            ), isDark),
            const SizedBox(height: 12),
            _field('日期', InkWell(
              onTap: _pickDate,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}'),
                     Icon(Icons.calendar_today_rounded, size: 18, color: AppTheme.primaryColor),
                  ],
                ),
              ),
            ), isDark),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text('开启提醒', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? Colors.grey.shade400 : const Color(0xFF374151))),
                ),
                Switch(
                  value: _enableReminder,
                  onChanged: (v) => setState(() => _enableReminder = v),
                  activeColor: AppTheme.primaryColor,
                ),
              ],
            ),
            if (_enableReminder)
              _field('提醒时间', InkWell(
                onTap: _pickTime,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_reminderTime == null
                          ? '选择时间'
                          : '${_reminderTime!.hour.toString().padLeft(2, '0')}:${_reminderTime!.minute.toString().padLeft(2, '0')}'),
                       Icon(Icons.access_time_rounded, size: 18, color: AppTheme.primaryColor),
                    ],
                  ),
                ),
              ), isDark),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppTheme.primaryColor.withAlpha(150),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 24, height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                      )
                    : Text(_isEdit ? '保存修改' : '保存', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  /// 保存成功后的过渡视图：绿色对勾 + 文案，给用户明确的「已添加」反馈。
  Widget _buildSuccess(bool isDark) {
    final dateStr =
        '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';
    return Container(
      height: 320,
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.6, end: 1.0),
            duration: const Duration(milliseconds: 360),
            curve: Curves.elasticOut,
            builder: (_, v, child) => Transform.scale(scale: v, child: child),
            child: const Icon(
              Icons.check_circle_rounded,
              color: Color(0xFF10B981),
              size: 76,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '已添加',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: context.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '待办已保存到 $dateStr',
            style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  Widget _field(String label, Widget child, bool isDark) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: isDark ? Colors.grey.shade400 : const Color(0xFF374151))),
          ),
          child,
        ],
      );

  @override
  void dispose() {
    _titleCtl.dispose();
    _descCtl.dispose();
    super.dispose();
  }
}
