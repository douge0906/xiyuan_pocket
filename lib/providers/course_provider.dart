import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/course_model.dart';
import '../services/course_storage.dart';

/// 课表状态：**应用内唯一的课表数据源**。
///
/// 为什么要有它（引入 Riverpod 的第一块）：
///   - 首页 / 课表页 / 后续页面读的是**同一份**课表，任何一处改动，
///     其它页面**自动**看到新数据，不再依赖「回到页面时手动重新读一遍」。
///   - 所有写操作统一走本类 → 落盘、桌面小组件同步、上课提醒重排
///     都收口在一处，不会出现"改了这里忘了那里"。
///   - 页面不再各自 `CourseStorage.loadCourses()`，代码更薄。
///
/// 兼容性：底层仍然是 [CourseStorage]（SharedPreferences）负责持久化，
/// 本类只是在它之上加了一层「可订阅的状态」，**不改变存储格式**，
/// 因此与老版本的用户数据完全兼容，升级不丢课表。
class CourseState {
  final List<Course> courses;
  final DateTime semesterStart;
  final bool loading;

  const CourseState({
    this.courses = const [],
    required this.semesterStart,
    this.loading = true,
  });

  /// 今天所处的教学周
  int get currentWeek =>
      CourseStorage.teachingWeek(DateTime.now(), semesterStart);

  /// 今天要上的课（按节次排序）
  List<Course> get todayCourses {
    final now = DateTime.now();
    final week = CourseStorage.teachingWeek(now, semesterStart);
    final list = courses.where((c) => c.occursOn(now.weekday, week)).toList();
    list.sort((a, b) => a.startSlot.compareTo(b.startSlot));
    return list;
  }

  CourseState copyWith({
    List<Course>? courses,
    DateTime? semesterStart,
    bool? loading,
  }) =>
      CourseState(
        courses: courses ?? this.courses,
        semesterStart: semesterStart ?? this.semesterStart,
        loading: loading ?? this.loading,
      );
}

class CourseNotifier extends Notifier<CourseState> {
  @override
  CourseState build() {
    // 首帧先用默认值渲染，异步补齐真实数据（避免白屏）
    Future.microtask(load);
    return CourseState(
      semesterStart: CourseStorage.defaultSemesterStart(DateTime.now()),
    );
  }

  /// 从本地存储重新载入（启动时、或外部直接改过存储后调用）
  Future<void> load() async {
    final courses = await CourseStorage.loadCourses();
    final start = await CourseStorage.loadSemesterStart() ??
        CourseStorage.defaultSemesterStart(DateTime.now());
    state = CourseState(courses: courses, semesterStart: start, loading: false);
  }

  /// 所有写操作的**唯一出口**：先落盘（内部会同步桌面小组件），再更新状态。
  /// 状态一变，所有 `ref.watch(courseProvider)` 的页面自动重建。
  Future<List<Course>> _commit(List<Course> courses) async {
    await CourseStorage.saveCourses(courses);
    state = state.copyWith(courses: courses, loading: false);
    return courses;
  }

  Future<List<Course>> upsert(Course course) async =>
      _commit(await CourseStorage.upsertCourse(course));

  Future<List<Course>> remove(String id) async =>
      _commit(await CourseStorage.deleteCourse(id));

  Future<List<Course>> replaceAll(List<Course> courses) async =>
      _commit(courses);

  Future<List<Course>> mergeServer(List<Course> serverCourses) async =>
      _commit(await CourseStorage.mergeServerCourses(serverCourses));

  Future<List<Course>> clear() async => _commit(const <Course>[]);

  Future<DateTime> setSemesterStart(DateTime date) async {
    final aligned = CourseStorage.mondayOf(date);
    await CourseStorage.saveSemesterStart(aligned);
    state = state.copyWith(semesterStart: aligned, loading: false);
    return aligned;
  }
}

final courseProvider =
    NotifierProvider<CourseNotifier, CourseState>(CourseNotifier.new);
