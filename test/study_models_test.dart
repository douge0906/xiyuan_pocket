import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/models/study_models.dart';

StudyCourse _course({
  String name = '高等数学',
  double credits = 3,
  StudyState state = StudyState.notStarted,
  String score = '',
  String gpa = '',
  String studyYear = '',
  String category = '',
}) {
  return StudyCourse(
    courseNo: 'K001',
    name: name,
    credits: credits,
    hours: '讲课(48)',
    nature: '必修',
    category: category,
    state: state,
    score: score,
    gpa: gpa,
    studyYear: studyYear,
    suggestYear: '2025-2026',
    suggestTerm: '1',
  );
}

StudyBlock _block({
  String id = 'A',
  String name = '通识（必）',
  List<StudyCourse>? courses,
  double? requiredCredits,
  double? earnedCredits,
  int? requiredDoors,
  int? passedDoors,
}) {
  return StudyBlock(
    id: id,
    name: name,
    courses: courses ?? const [],
    requiredCredits: requiredCredits,
    earnedCredits: earnedCredits,
    requiredDoors: requiredDoors,
    passedDoors: passedDoors,
  );
}

StudyArchive _archive(List<StudyBlock> blocks) {
  return StudyArchive(
    mode: StudyMode.full,
    blocks: blocks,
    studentName: '张三',
    major: '2025电气工程及其自动化',
    gradeYear: '2025',
    gpa: 3.62,
    totalCourses: 135,
    passedCourses: 17,
    failedCourses: 0,
    notStartedCourses: 103,
    studyingCourses: 15,
    requiredCredits: 165,
    earnedCredits: 40,
    fetchedAt: DateTime(2026, 11, 2, 15),
  );
}

void main() {
  group('StudyState 与教务 XDZT 的映射', () {
    test('XDZT 1/2/3/4/5/21 各自落到正确状态', () {
      expect(StudyState.fromXdzt('1'), StudyState.studying);
      expect(StudyState.fromXdzt('2'), StudyState.failed);
      expect(StudyState.fromXdzt('3'), StudyState.notStarted);
      expect(StudyState.fromXdzt('4'), StudyState.passed);
      expect(StudyState.fromXdzt('21'), StudyState.passed);
      expect(StudyState.fromXdzt('5'), StudyState.replaced);
    });

    test('6/7/8（替代与认定）一律算已修·替代', () {
      for (final raw in ['6', '7', '8']) {
        expect(StudyState.fromXdzt(raw), StudyState.replaced,
            reason: 'XDZT=$raw 应为已修·替代');
      }
    });

    test('空值与脏值不崩，兜底为已修', () {
      expect(StudyState.fromXdzt(null), StudyState.passed);
      expect(StudyState.fromXdzt(''), StudyState.passed);
      expect(StudyState.fromXdzt('99'), StudyState.passed);
    });

    test('通过口径：已修 与 已修·替代 都算通过（照抄教务）', () {
      expect(StudyState.passed.isCountedPassed, isTrue);
      expect(StudyState.replaced.isCountedPassed, isTrue);
      expect(StudyState.studying.isCountedPassed, isFalse);
      expect(StudyState.failed.isCountedPassed, isFalse);
      expect(StudyState.notStarted.isCountedPassed, isFalse);
    });

    test('排序权重：未过 → 在读 → 未修 → 已修 → 替代', () {
      final sorted = [
        StudyState.replaced,
        StudyState.notStarted,
        StudyState.passed,
        StudyState.failed,
        StudyState.studying,
      ]..sort((a, b) => a.sortWeight.compareTo(b.sortWeight));
      expect(sorted, [
        StudyState.failed,
        StudyState.studying,
        StudyState.notStarted,
        StudyState.passed,
        StudyState.replaced,
      ]);
    });
  });

  group('StudyCourse', () {
    test('subtitleLine 只拼性质、学分、学时三件事', () {
      final c = _course();
      expect(c.subtitleLine, '必修 · 3学分 · 讲课(48)');
    });

    test('学分不拖 .0 尾巴', () {
      expect(_course(credits: 6).subtitleLine, contains('6学分'));
      expect(_course(credits: 2.5).subtitleLine, contains('2.5学分'));
    });

    test('hasScore：成绩或绩点任一非空即为已出分', () {
      expect(_course(score: '').hasScore, isFalse);
      expect(_course(score: '88').hasScore, isTrue);
      expect(_course(score: '', gpa: '3.5').hasScore, isTrue);
    });

    test('toJson / fromJson 往返不丢字段', () {
      final c = _course(
        name: '高等数学（理）Ⅰ（上）',
        credits: 6,
        state: StudyState.passed,
        score: '92',
        studyYear: '2024-2025',
        category: '通识必修课',
      );
      final back = StudyCourse.fromJson(c.toJson());
      expect(back.courseNo, c.courseNo);
      expect(back.name, c.name);
      expect(back.credits, c.credits);
      expect(back.nature, c.nature);
      expect(back.category, c.category);
      expect(back.state, c.state);
      expect(back.score, c.score);
      expect(back.studyYear, c.studyYear);
      expect(back.stateFromServer, isTrue);
    });

    test('fromJwgl 读大写字段', () {
      final c = StudyCourse.fromJwgl({
        'KCH': '111107010',
        'KCMC': '高等数学（理）Ⅰ（上）',
        'XF': '6.0',
        'XSXXXX': '讲课(96.0)',
        'KCXZMC': '必修',
        'KCLBMC': '通识必修课',
        'XDZT': '4',
        'CJ': '92',
        'MAXCJ': '92',
        'JD': '4.2',
        'XNMC': '2025-2026',
        'XQMMC': '1',
        'JYXDXNMC': '2025-2026',
        'JYXDXQMC': '1',
      });
      expect(c.courseNo, '111107010');
      expect(c.name, '高等数学（理）Ⅰ（上）');
      expect(c.credits, 6.0);
      expect(c.hours, '讲课(96.0)');
      expect(c.nature, '必修');
      expect(c.category, '通识必修课');
      expect(c.state, StudyState.passed);
      expect(c.score, '92');
      expect(c.gpa, '4.2');
      expect(c.studyYear, '2025-2026');
      expect(c.hasScore, isTrue);
    });

    test('fromJwgl 缺字段不抛，学分兜底 0', () {
      final empty = StudyCourse.fromJwgl(const {});
      expect(empty.credits, 0);
      expect(empty.name, '');
      expect(empty.hasScore, isFalse);
      // XDZT 缺失 → fromXdzt(null) 兜底 passed，但 stateFromServer 必须是 false，
      // 否则 UI 会把「客户端兜底猜的」当成教务权威状态。
      expect(empty.state, StudyState.passed);
      expect(empty.stateFromServer, isFalse);
    });

    test('学分是脏值时按 0 处理，不炸', () {
      final c = StudyCourse.fromJwgl({'XF': '--', 'KCMC': 'X'});
      expect(c.credits, 0);
    });
  });

  group('StudyBlock', () {
    test('passedCount 优先用教务下发的 passedDoors', () {
      final b = _block(
        courses: [_course(state: StudyState.notStarted)],
        passedDoors: 14,
      );
      expect(b.passedCount, 14);
    });

    test('教务没给门数（passedDoors=null）时改从课程 XDZT 数', () {
      final b = _block(
        courses: [
          _course(state: StudyState.passed),
          _course(state: StudyState.replaced),
          _course(state: StudyState.studying),
          _course(state: StudyState.notStarted),
        ],
        passedDoors: null,
      );
      expect(b.passedCount, 2, reason: '已修 + 已修·替代 = 2');
    });

    test('courseCredits 是子板块「要求学分 1.0」怪值的替代口径', () {
      final b = _block(
        courses: [
          _course(credits: 6),
          _course(credits: 2.5),
          _course(credits: 0.5),
        ],
      );
      expect(b.courseCredits, 9.0);
    });

    test('hasUnmet / isComplete 按「已通过门数 vs 总门数」判断', () {
      final blocked = _block(
        courses: [
          _course(state: StudyState.passed),
          _course(state: StudyState.failed),
        ],
      );
      expect(blocked.passedCount, 1);
      expect(blocked.courseCount, 2);
      expect(blocked.hasUnmet, isTrue);
      expect(blocked.isComplete, isFalse);
      expect(blocked.progress, 0.5);

      final done = _block(courses: [_course(state: StudyState.passed)]);
      expect(done.hasUnmet, isFalse);
      expect(done.isComplete, isTrue);
      expect(done.progress, 1.0);
    });

    test('空板块不会除零，progress 取 0、isComplete 取 false', () {
      final empty = _block(courses: const []);
      expect(empty.courseCount, 0);
      expect(empty.courseCredits, 0);
      expect(empty.progress, 0);
      expect(empty.isComplete, isFalse);
    });

    test('copyWith 换课程时其余字段保持不变', () {
      final b = _block(requiredCredits: 36, earnedCredits: 30, passedDoors: 5);
      final c = b.copyWith(courses: [_course()]);
      expect(c.id, b.id);
      expect(c.name, b.name);
      expect(c.requiredCredits, 36);
      expect(c.earnedCredits, 30);
      expect(c.passedDoors, 5);
      expect(c.courses.length, 1);
    });

    test('toJson / fromJson 往返不丢字段', () {
      final b = _block(
        requiredCredits: 36,
        earnedCredits: 30.5,
        requiredDoors: 27,
        passedDoors: 14,
        courses: [_course(state: StudyState.passed, score: '88')],
      );
      final back = StudyBlock.fromJson(b.toJson());
      expect(back.id, b.id);
      expect(back.name, b.name);
      expect(back.requiredCredits, 36);
      expect(back.earnedCredits, 30.5);
      expect(back.requiredDoors, 27);
      expect(back.passedDoors, 14);
      expect(back.courses.length, 1);
      expect(back.courses.first.score, '88');
    });
  });

  group('StudyArchive', () {
    test('allCourses 跨板块扁平化', () {
      final a = _archive([
        _block(id: 'A', courses: [_course(name: '甲'), _course(name: '乙')]),
        _block(id: 'B', courses: [_course(name: '丙')]),
      ]);
      expect(a.allCourses.length, 3);
      expect(a.allCourses.map((c) => c.name), ['甲', '乙', '丙']);
    });

    test('filtered 按状态筛板块，空板块被剔除', () {
      final a = _archive([
        _block(id: 'A', courses: [
          _course(name: '甲', state: StudyState.passed),
          _course(name: '乙', state: StudyState.studying),
          _course(name: '丙', state: StudyState.studying),
        ]),
        _block(id: 'B', courses: [_course(name: '丁', state: StudyState.failed)]),
      ]);

      final studying = a.filtered({StudyState.studying});
      expect(studying.length, 1);
      expect(studying.first.id, 'A');
      expect(studying.first.courses.length, 2);
      expect(
        studying.first.courses.every((c) => c.state == StudyState.studying),
        isTrue,
      );

      expect(a.filtered({StudyState.replaced}), isEmpty);
    });

    test('filtered 传空集合返回全部板块', () {
      final a = _archive([_block(id: 'A', courses: [_course()])]);
      expect(a.filtered(const {}).length, 1);
    });

    test('stateCounts 统计正确，未出现的状态计 0', () {
      final a = _archive([
        _block(courses: [
          _course(state: StudyState.passed),
          _course(state: StudyState.studying),
          _course(state: StudyState.studying),
          _course(state: StudyState.failed),
        ]),
      ]);
      final counts = a.stateCounts;
      expect(counts[StudyState.studying], 2);
      expect(counts[StudyState.passed], 1);
      expect(counts[StudyState.failed], 1);
      expect(counts[StudyState.notStarted], 0);
      expect(counts[StudyState.replaced], 0);
    });

    test('isUnconfigured / isFull 只在对应模式为真', () {
      expect(StudyArchive.unconfigured().isUnconfigured, isTrue);
      expect(StudyArchive.unconfigured().isFull, isFalse);
      expect(_archive(const []).isFull, isTrue);
      expect(_archive(const []).isUnconfigured, isFalse);
    });

    test('unconfigured 带默认文案', () {
      expect(StudyArchive.unconfigured().notice, kUnconfiguredNotice);
      expect(StudyArchive.unconfigured(notice: '自定义').notice, '自定义');
    });

    test('sortBlocks 把有未过课程的板块排到最前（在读优先排的要求）', () {
      // 排序发生在抓取层（study_client 的每个出口都调 sortBlocks），
      // 构造函数本身不排序 —— 这样缓存往返不会二次打乱顺序。
      final sorted = StudyArchive.sortBlocks([
        _block(id: 'done', name: '已满', courses: [
          _course(state: StudyState.passed),
        ]),
        _block(id: 'bad', name: '有未过', courses: [
          _course(state: StudyState.failed),
        ]),
        _block(id: 'ing', name: '在读', courses: [
          _course(state: StudyState.studying),
        ]),
      ]);
      expect(sorted.map((b) => b.id), ['bad', 'ing', 'done']);
    });

    test('sortBlocks 是公开静态方法，空板块排到最后', () {
      final sorted = StudyArchive.sortBlocks([
        _block(id: 'empty', name: 'A', courses: const []),
        _block(id: 'has', name: 'B', courses: [
          _course(state: StudyState.notStarted),
        ]),
      ]);
      expect(sorted.first.id, 'has');
      expect(sorted.last.id, 'empty');
    });

    test('sortCourses 同一套权重', () {
      final sorted = StudyArchive.sortCourses([
        _course(name: '已修', state: StudyState.passed),
        _course(name: '未过', state: StudyState.failed),
        _course(name: '在读', state: StudyState.studying),
      ]);
      expect(sorted.map((c) => c.name), ['未过', '在读', '已修']);
    });

    test('encodeArchive / decodeArchive 往返', () {
      final a = _archive([
        _block(
          name: '通识（必）',
          courses: [_course(state: StudyState.passed, score: '88')],
          requiredCredits: 36,
          earnedCredits: 36,
          passedDoors: 14,
        ),
      ]);
      final back = decodeArchive(encodeArchive(a));
      expect(back, isNotNull);
      expect(back!.mode, StudyMode.full);
      expect(back.gpa, 3.62);
      expect(back.major, '2025电气工程及其自动化');
      expect(back.requiredCredits, 165);
      expect(back.earnedCredits, 40);
      expect(back.totalCourses, 135);
      expect(back.blocks.length, 1);
      expect(back.blocks.first.name, '通识（必）');
      expect(back.blocks.first.courses.first.score, '88');
      expect(back.fetchedAt?.year, 2026);
    });

    test('decodeArchive 遇到坏数据返回 null 而不抛', () {
      expect(decodeArchive(''), isNull);
      expect(decodeArchive('{不是 json'), isNull);
      expect(decodeArchive('[1,2,3]'), isNull);
      expect(decodeArchive('null'), isNull);
    });

    test('copyWith 只换 blocks，其余元数据保留', () {
      final a = _archive([_block(id: 'A', courses: [_course()])]);
      final b = a.copyWith(blocks: [_block(id: 'B', courses: [_course()])]);
      expect(b.blocks.first.id, 'B');
      expect(b.gpa, a.gpa);
      expect(b.major, a.major);
      expect(b.requiredCredits, a.requiredCredits);
      expect(b.mode, a.mode);
    });
  });
}
