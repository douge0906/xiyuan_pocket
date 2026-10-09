import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/services/course_storage.dart';

/// 多课表 · 步骤 2：存储层多表改造 + 老数据搬家。
///
/// 这一层最要命的地方是**搬家**：老用户机器上只有一份课表，存在
/// `course_table_courses` / `course_semester_start` 两个老键里。
/// 升级后第一次读，必须把它原样变成一份「我的课表」，
/// **一门课、一天都不能少**，而且老键要留着（万一要回滚）。
Course _c(String id, String name) => Course(
      id: id,
      name: name,
      teacher: '张老师',
      classroom: 'A101',
      weekday: 1,
      startSlot: 1,
      endSlot: 2,
      colorValue: 0xFFD2E5F8, // 浅色调色板里的颜色，避免触发调色板迁移
      source: CourseSource.server,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('老数据搬家', () {
    test('🔴 老结构 → 一份「我的课表」，课程一门不少、开学日保留', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'course_table_courses':
            jsonEncode([_c('a', '高等数学').toJson(), _c('b', '线性代数').toJson()]),
        'course_semester_start': '2026-09-07',
      });

      final courses = await CourseStorage.loadCourses();
      expect(courses.length, 2);
      expect(courses.map((c) => c.name), ['高等数学', '线性代数']);

      final tables = await CourseStorage.loadTables();
      expect(tables.length, 1, reason: '应该正好搬成一份');
      expect(tables.first.name, '我的课表');
      expect(tables.first.semesterStart, DateTime(2026, 9, 7));
      // 老结构没有「来源」概念 → 当成用户定过，别去打扰老用户
      expect(tables.first.semesterStartConfirmedByUser, isTrue);

      expect(await CourseStorage.loadSemesterStart(), DateTime(2026, 9, 7));
    });

    test('🔴 搬家后老键仍在（回滚保险，不删不改）', () async {
      final legacyJson = jsonEncode([_c('a', '高等数学').toJson()]);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'course_table_courses': legacyJson,
        'course_semester_start': '2026-09-07',
      });

      await CourseStorage.loadCourses();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('course_table_courses'), legacyJson);
      expect(prefs.getString('course_semester_start'), '2026-09-07');
    });

    test('没有老数据 → 也要有一份「我的课表」（不能处于「没有激活表」的状态）', () async {
      final tables = await CourseStorage.loadTables();
      expect(tables.length, 1);
      expect((await CourseStorage.loadCourses()), isEmpty);
      expect(await CourseStorage.loadSemesterStart(), isNull);
    });

    test('搬家只发生一次：再读不会又冒出一份', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'course_table_courses': jsonEncode([_c('a', '高等数学').toJson()]),
      });
      await CourseStorage.loadCourses();
      await CourseStorage.loadTables();
      expect((await CourseStorage.loadTables()).length, 1);
      expect((await CourseStorage.loadCourses()).length, 1);
    });

    test('老数据损坏 → 回退老备份键', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'course_table_courses': '{不是合法 JSON',
        'course_table_courses_bak': jsonEncode([_c('a', '高等数学').toJson()]),
      });
      expect((await CourseStorage.loadCourses()).length, 1);
    });
  });

  group('多表增删改查', () {
    test('新建一份会立刻切过去（导入完就是这个状态）', () async {
      await CourseStorage.loadCourses(); // 先触发搬家，得到一份空占位
      final id = await CourseStorage.createTable(
          name: '张同学的课表', courses: [_c('z', '大学物理')]);

      final tables = await CourseStorage.loadTables();
      expect(tables.length, 1, reason: '🔴 唯一的空占位要被复用，不能凭空多出一张空表');
      expect(tables.first.name, '张同学的课表');
      expect((await CourseStorage.activeTable()).id, id);
      expect((await CourseStorage.loadCourses()).map((c) => c.name), ['大学物理']);
    });

    test('🔴 已有课表时导入 → 真的新增一份，原表原样保留', () async {
      // 先有一份**有内容**的课表（不是空占位）
      final idMine = await CourseStorage.createTable(
          name: '我的课表', courses: [_c('m1', '我的课')]);

      final idNew = await CourseStorage.createTable(
          name: '张同学的课表', courses: [_c('z1', '大学物理')]);

      final tables = await CourseStorage.loadTables();
      expect(tables.length, 2, reason: '有内容的表不能被顶掉');
      expect(tables.map((t) => t.name), ['我的课表', '张同学的课表']);

      // 切回去，原表内容一门不少
      await CourseStorage.switchTable(idMine);
      expect((await CourseStorage.loadCourses()).map((c) => c.name), ['我的课']);

      await CourseStorage.switchTable(idNew);
      expect((await CourseStorage.loadCourses()).map((c) => c.name), ['大学物理']);
    });

    test('🔴 两份互不干扰：改这份的课程，那份原样不动', () async {
      await CourseStorage.createTable(name: 'A', courses: [_c('a1', '甲课')]);
      final idB = await CourseStorage.createTable(name: 'B', courses: [_c('b1', '乙课')]);

      // 当前在 B，往里加一门
      await CourseStorage.upsertCourse(_c('b2', '乙课二'));
      expect((await CourseStorage.loadCourses()).map((c) => c.name), ['乙课', '乙课二']);

      // 切回 A
      final tables = await CourseStorage.loadTables();
      final idA = tables.firstWhere((t) => t.name == 'A').id;
      expect(await CourseStorage.switchTable(idA), isTrue);
      expect((await CourseStorage.loadCourses()).map((c) => c.name), ['甲课'],
          reason: 'A 不该被 B 的改动影响');

      // 再切回 B，B 的改动还在
      await CourseStorage.switchTable(idB);
      expect((await CourseStorage.loadCourses()).length, 2);
    });

    test('每份课表有自己的开学日', () async {
      await CourseStorage.createTable(name: 'A');
      await CourseStorage.saveSemesterStart(DateTime(2026, 9, 7), byUser: true);
      final idB = await CourseStorage.createTable(name: 'B');
      await CourseStorage.saveSemesterStart(DateTime(2027, 2, 22), byUser: true);

      expect(await CourseStorage.loadSemesterStart(), DateTime(2027, 2, 22));
      final tables = await CourseStorage.loadTables();
      final idA = tables.firstWhere((t) => t.name == 'A').id;
      await CourseStorage.switchTable(idA);
      expect(await CourseStorage.loadSemesterStart(), DateTime(2026, 9, 7));

      await CourseStorage.switchTable(idB);
      expect(await CourseStorage.loadSemesterStart(), DateTime(2027, 2, 22));
    });

    test('开学日来源：byUser 决定要不要提醒确认', () async {
      await CourseStorage.createTable(name: 'A');
      await CourseStorage.saveSemesterStart(DateTime(2026, 9, 7));
      expect((await CourseStorage.activeTable()).semesterStartConfirmedByUser, isFalse);

      await CourseStorage.saveSemesterStart(DateTime(2026, 9, 7), byUser: true);
      expect((await CourseStorage.activeTable()).semesterStartConfirmedByUser, isTrue);
    });

    test('改名', () async {
      final id = await CourseStorage.createTable(name: '旧名字');
      expect(await CourseStorage.renameTable(id, '新名字'), isTrue);
      expect((await CourseStorage.activeTable()).name, '新名字');
      expect(await CourseStorage.renameTable(id, '   '), isFalse, reason: '空名字不接受');
    });

    test('切换：不存在的 id 返回 false，且不影响当前', () async {
      final id = await CourseStorage.createTable(name: 'A');
      expect(await CourseStorage.switchTable('不存在的id'), isFalse);
      expect((await CourseStorage.activeTable()).id, id);
    });

    test('🔴 最后一份不许删', () async {
      await CourseStorage.loadCourses(); // 搬出一份
      final only = (await CourseStorage.loadTables()).first.id;
      expect(await CourseStorage.deleteTable(only), isFalse);
      expect((await CourseStorage.loadTables()).length, 1);
      expect((await CourseStorage.loadCourses()), isEmpty, reason: '拒绝删除后不能被清空');
    });

    test('🔴 删掉的正好是当前激活那份 → 自动切到剩下的第一份', () async {
      await CourseStorage.createTable(name: 'A', courses: [_c('a1', '甲课')]);
      final idB = await CourseStorage.createTable(name: 'B'); // 当前在 B
      expect((await CourseStorage.activeTable()).id, idB);

      expect(await CourseStorage.deleteTable(idB), isTrue);
      final now = await CourseStorage.activeTable();
      expect(now.name, 'A', reason: '不能留下「激活的表已被删」这种状态');
      expect((await CourseStorage.loadCourses()).map((c) => c.name), ['甲课']);
    });

    test('🔴 id 不能撞车（Windows 上 DateTime.now() 只有毫秒精度）', () async {
      final ids = <String>{};
      for (var i = 0; i < 30; i++) {
        ids.add(await CourseStorage.createTable(
            name: 't$i', courses: [_c('x$i', '课$i')]));
      }
      expect(ids.length, 30,
          reason: 'id 一撞：切表分不清、「删一份」会把同 id 的连坐删掉，'
              '然后 next.first 抛 Bad state: No element（已实际复现过）');
    });

    test('🔴 同一毫秒内连建多个，id 也不能相同', () {
      // 必须**同步紧挨着**生成：走 createTable() 中间隔着 await，早就跨毫秒了。
      //
      // ⚠️ 局限（如实记录）：这条只能**概率性**抓到 bug。Windows 的时钟精度是
      // 动态的（可能 0.5ms，也可能 15.6ms），所以「纯时间戳」的实现在这里
      // 有时会撞、有时不会。真正可靠的证据是：修之前连跑全量会偶发
      // `Bad state: No element`，修之后连跑 6 次全绿。
      // 加自增序号后，这个性质就不再依赖时钟了。
      final ids = <String>{};
      for (var i = 0; i < 50; i++) {
        ids.add(CourseStorage.newTableIdForTest());
      }
      expect(ids.length, 50,
          reason: 'id 一撞：「切表」分不清，「删一份」会把同 id 的连坐删掉');
    });

    test('🔴 删一份永远不能让列表空掉', () async {
      await CourseStorage.createTable(name: 'A', courses: [_c('a1', '甲课')]);
      for (final t in await CourseStorage.loadTables()) {
        await CourseStorage.deleteTable(t.id);
      }
      expect((await CourseStorage.loadTables()).isNotEmpty, isTrue);
    });

    test('删掉非激活那份 → 激活不变', () async {
      // 两份都要有内容：空表会被 createTable 当成占位复用掉（见上一条）
      final idA =
          await CourseStorage.createTable(name: 'A', courses: [_c('a1', '甲课')]);
      final idB =
          await CourseStorage.createTable(name: 'B', courses: [_c('b1', '乙课')]);
      expect(await CourseStorage.deleteTable(idA), isTrue);
      expect((await CourseStorage.activeTable()).id, idB);
      expect((await CourseStorage.loadCourses()).map((c) => c.name), ['乙课']);
    });
  });

  group('抗损坏', () {
    test('🔴 多表主键坏掉 → 回退备份，课表不丢', () async {
      await CourseStorage.createTable(name: 'A', courses: [_c('a1', '甲课')]);
      await CourseStorage.createTable(name: 'B', courses: [_c('b1', '乙课')]); // 触发备份
      final prefs = await SharedPreferences.getInstance();
      final bak = prefs.getString('course_tables_v2_bak');
      expect(bak, isNotNull, reason: '第二次写之前应该备份了上一版');

      await prefs.setString('course_tables_v2', '{坏掉的 JSON');
      expect((await CourseStorage.loadTables()).length, 1);
      expect((await CourseStorage.loadCourses()).map((c) => c.name), ['甲课']);
    });

    test('🔴 多表里某一份坏掉 → 只跳过那一份，别的照常', () async {
      await CourseStorage.createTable(name: '好的', courses: [_c('a1', '甲课')]);
      final prefs = await SharedPreferences.getInstance();
      final j = jsonDecode(prefs.getString('course_tables_v2')!) as Map<String, dynamic>;
      (j['tables'] as List).add({'name': '没有 id 的坏表'});
      await prefs.setString('course_tables_v2', jsonEncode(j));

      final tables = await CourseStorage.loadTables();
      expect(tables.length, 1);
      expect(tables.first.name, '好的');
    });

    test('🔴 activeId 指向不存在的那份 → 落到第一份（不允许没有激活表）', () async {
      await CourseStorage.createTable(name: '好的', courses: [_c('a1', '甲课')]);
      final prefs = await SharedPreferences.getInstance();
      final j = jsonDecode(prefs.getString('course_tables_v2')!) as Map<String, dynamic>;
      j['activeId'] = '早就删掉的id';
      await prefs.setString('course_tables_v2', jsonEncode(j));

      expect((await CourseStorage.activeTable()).name, '好的');
      expect((await CourseStorage.loadCourses()).map((c) => c.name), ['甲课']);
    });
  });
}
