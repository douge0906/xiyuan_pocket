import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lib/services/exam_storage.dart';

/// 考试缓存的守卫与倒计时逻辑测试（v2.4.9 补）。
///
/// 背景：教务维护或改版时，`JwglClient.queryExams` 会**返回空列表而不是抛错**
/// （它把空结果当作「本学期暂无考试安排」这一合法响应）。
/// 页面拿到的就是空列表，若照写缓存，就会把用户已有的考试安排清空 ——
/// 这是本项目最高频的 bug 模式：
///   失败 → 静默返回空 → 空被当有效结果写回 → 抹掉好东西。
///
/// 本测试锁定「空列表不覆盖缓存」这条守卫，防止将来被改回去。
///
/// 被测接口：saveExams / loadExams / loadSemester / nextExam / _parseDate（间接）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('ExamStorage 缓存守卫', () {
    test('saveExams 传空列表：不得覆盖已有缓存', () async {
      await ExamStorage.saveExams(<Map<String, dynamic>>[
        {'name': '高等数学', 'date': '2099-01-01', 'classroom': 'A101'},
      ]);
      expect((await ExamStorage.loadExams()).length, 1,
          reason: '前置条件：已有一场考试');

      // 模拟「教务维护 → 返回空结果」被照写
      await ExamStorage.saveExams(const <Map<String, dynamic>>[]);

      final after = await ExamStorage.loadExams();
      expect(after.length, 1, reason: '空列表不得覆盖已有缓存');
      expect(after.first['name'], '高等数学');
    });

    test('saveExams 非空：正常写入并可原样读回', () async {
      await ExamStorage.saveExams(<Map<String, dynamic>>[
        {'name': '大学英语', 'date': '2099-02-02', 'classroom': 'B202'},
      ], semester: '2098-2099 第1学期');

      final list = await ExamStorage.loadExams();
      expect(list.length, 1);
      expect(list.first['name'], '大学英语');
      expect(await ExamStorage.loadSemester(), '2098-2099 第1学期');
    });

    test('全新安装且无缓存：写入空列表不报错，读取为空', () async {
      await ExamStorage.saveExams(const <Map<String, dynamic>>[]);
      expect(await ExamStorage.loadExams(), isEmpty);
    });

    test('缓存被写成空数组字符串时：读回空而不是抛异常', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'exam_cache_list': '[]',
      });
      expect(await ExamStorage.loadExams(), isEmpty);
    });
  });

  group('ExamStorage.nextExam 取最近一场', () {
    // 造一个「今天 + offset 天」的日期串（与教务返回的 2026-06-15 同格式）
    String dayFromNow(int offset) {
      final now = DateTime.now();
      final t = DateTime(now.year, now.month, now.day)
          .add(Duration(days: offset));
      final mm = t.month.toString().padLeft(2, '0');
      final dd = t.day.toString().padLeft(2, '0');
      return '${t.year}-$mm-$dd';
    }

    test('忽略已过去的考试，取最近的一场', () async {
      await ExamStorage.saveExams(<Map<String, dynamic>>[
        {'name': '三天前考完的', 'date': dayFromNow(-3)},
        {'name': '七天后的', 'date': dayFromNow(7), 'classroom': 'A101'},
        {'name': '三天后的', 'date': dayFromNow(3), 'classroom': 'B202'},
      ]);

      final next = await ExamStorage.nextExam();
      expect(next, isNotNull);
      expect(next!.name, '三天后的', reason: '应取最近的一场，并忽略已过去的');
      expect(next.daysLeft, 3);
      expect(next.classroom, 'B202');
    });

    test('今天的考试：daysLeft 为 0', () async {
      await ExamStorage.saveExams(<Map<String, dynamic>>[
        {'name': '今天考', 'date': dayFromNow(0)},
      ]);
      final next = await ExamStorage.nextExam();
      expect(next, isNotNull);
      expect(next!.daysLeft, 0);
    });

    test('全部已过期：返回 null', () async {
      await ExamStorage.saveExams(<Map<String, dynamic>>[
        {'name': '早考完了', 'date': '2020-01-01'},
      ]);
      expect(await ExamStorage.nextExam(), isNull);
    });

    test('非法日期的那条被跳过，不影响其余条目', () async {
      await ExamStorage.saveExams(<Map<String, dynamic>>[
        {'name': '空日期', 'date': ''},
        {'name': '乱写日期', 'date': '待定'},
        {'name': '正常', 'date': dayFromNow(5)},
      ]);
      final next = await ExamStorage.nextExam();
      expect(next, isNotNull);
      expect(next!.name, '正常');
    });

    test('日期分隔符兼容：斜杠与中文日期同样能解析', () async {
      final now = DateTime.now();
      final t = DateTime(now.year, now.month, now.day)
          .add(const Duration(days: 2));
      final slash =
          '${t.year}/${t.month}/${t.day}';
      final chinese = '${t.year}年${t.month}月${t.day}日';
      await ExamStorage.saveExams(<Map<String, dynamic>>[
        {'name': '斜杠格式', 'date': slash},
      ]);
      var next = await ExamStorage.nextExam();
      expect(next, isNotNull, reason: '2026/6/15 这类斜杠格式应能解析');
      expect(next!.daysLeft, 2);

      await ExamStorage.saveExams(<Map<String, dynamic>>[
        {'name': '中文格式', 'date': chinese},
      ]);
      next = await ExamStorage.nextExam();
      expect(next, isNotNull, reason: '2026年6月15日 这类中文格式应能解析');
      expect(next!.name, '中文格式');
    });

    test('名称为空时回退为「未命名考试」', () async {
      await ExamStorage.saveExams(<Map<String, dynamic>>[
        {'name': '   ', 'date': dayFromNow(1)},
      ]);
      final next = await ExamStorage.nextExam();
      expect(next, isNotNull);
      expect(next!.name, '未命名考试');
    });
  });
}
