import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lib/services/textbook_storage.dart';

/// 教材缓存的守卫测试（v2.4.9 补）。
///
/// 与 `exam_storage_test.dart` 锁的是同一条铁律：
/// **抓取失败时门面方法会给出空列表，空列表绝不能覆盖已有缓存**
/// （否则「失败 → 静默返回空 → 空被当有效结果写回 → 抹掉好东西」）。
/// `TextbookStorage.saveBooks` 内有 `if (books.isEmpty) return;` —— 这里锁定它。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('saveBooks 传空列表：不得覆盖已有缓存', () async {
    await TextbookStorage.saveBooks(<Map<String, dynamic>>[
      {'name': '测绘工程CAD', 'book': '测绘工程CAD/吕翠华/武汉大学出版社'},
    ]);
    expect((await TextbookStorage.loadBooks()).length, 1,
        reason: '前置条件：已有一条教材');

    // 模拟「抓取失败 → 空结果」被照写
    await TextbookStorage.saveBooks(const <Map<String, dynamic>>[]);

    final after = await TextbookStorage.loadBooks();
    expect(after.length, 1, reason: '空列表不得覆盖已有缓存');
    expect(after.first['name'], '测绘工程CAD');
  });

  test('saveBooks 非空：正常写入，并记录学期与更新时间', () async {
    await TextbookStorage.saveBooks(<Map<String, dynamic>>[
      {'name': '大学物理', 'book': '大学物理/张三/高等教育出版社'},
    ], semester: '2098-2099 第1学期');

    expect((await TextbookStorage.loadBooks()).length, 1);
    expect(await TextbookStorage.loadSemester(), '2098-2099 第1学期');
    expect(await TextbookStorage.loadUpdatedAt(), isNotNull);
  });

  test('全新安装且无缓存：写空列表不报错，读取为空', () async {
    await TextbookStorage.saveBooks(const <Map<String, dynamic>>[]);
    expect(await TextbookStorage.loadBooks(), isEmpty);
    expect(await TextbookStorage.loadSemester(), isNull);
  });
}
