import '../models/course_model.dart';
import '../repositories/todo_repository.dart';
import 'course_storage.dart';

/// 「课程 → 待办」联动服务。
///
/// 课表页会把「今日课程」同步为待办（标题 `【课程】课程名`，id `course_<courseId>_<yyyymmdd>`）。
/// 本服务负责反向联动：**课程结束后把对应的待办自动划掉（标记完成）**。
///
/// 判定完全由「课程自身数据」推导，不依赖任何新增字段，因此对历史待办同样生效：
///   课程待办 id → 反查课程 → 用节次结束时刻表算出结束时间 → 早于当前时间即完成。
class CourseTodoService {
  CourseTodoService._();

  /// 课程待办 id 约定（与课表页 `_syncTodayCoursesToTodos` 保持一致）。
  static String courseTodoId(Course c, DateTime day) =>
      'course_${c.id}_${day.year}${day.month}${day.day}';

  /// 自动完成「今天已结束的课程」对应的待办，返回本次划掉的条数。
  /// 任何异常都静默返回 0，绝不影响主页渲染。
  static Future<int> autoCompleteFinishedCourses({DateTime? now}) async {
    try {
      final n = now ?? DateTime.now();
      final today = DateTime(n.year, n.month, n.day);
      final all = await TodoRepository.instance.getAll();
      final pending = all
          .where((t) => !t.completed && t.id.startsWith('course_'))
          .toList();
      if (pending.isEmpty) return 0;

      final courses = await CourseStorage.loadCourses();
      if (courses.isEmpty) return 0;
      final endMap = await CourseStorage.loadSlotEndMap();

      // 建索引：courseTodoId → Course，避免 O(n²) 反复拼接字符串。
      final byTodoId = <String, Course>{};
      for (final c in courses) {
        byTodoId[courseTodoId(c, today)] = c;
      }

      final finished = <String>{};
      for (final t in pending) {
        // 只处理「今天及更早」的课程待办；未来日期不处理。
        final d = DateTime(t.date.year, t.date.month, t.date.day);
        if (d.isAfter(today)) continue;
        final course = byTodoId[t.id];
        if (course == null) continue;
        final hhmm = endMap[course.endSlot];
        if (hhmm == null) continue;
        final parts = hhmm.split(':');
        final h = int.tryParse(parts[0]);
        final m = parts.length > 1 ? int.tryParse(parts[1]) : null;
        if (h == null || m == null) continue;
        final end = DateTime(d.year, d.month, d.day, h, m);
        if (end.isBefore(n)) finished.add(t.id);
      }
      if (finished.isEmpty) return 0;
      return await TodoRepository.instance.completeMany(finished);
    } catch (_) {
      return 0;
    }
  }
}
