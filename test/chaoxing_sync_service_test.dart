import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/services/chaoxing/chaoxing_sync_service.dart';

/// 学习通同步服务：只测**不需要真实学习通账号**的那部分。
///
/// 真实登录要人机验证 + 短信二次验证，不可能在单测里跑通，所以这里的
/// 目标不是「接口对不对」，而是锁住三条**边界**：
///  ① 没绑定时一律不发请求、不写数据
///  ② id 前缀稳定（待办/考试的清理与抑制全靠它）
///  ③ 只读红线：源码里不许出现签到 / 交作业 / 考试作答这类写接口
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChaoxingSyncService.debugResetCaches();
  });

  group('未绑定时的行为', () {
    test('没绑定 → isBound 为 false、account 为空', () async {
      expect(await ChaoxingSyncService.isBound(), isFalse);
      expect(await ChaoxingSyncService.account(), isEmpty);
    });

    test('没绑定 → syncIfDue 直接返回 null（零网络）', () async {
      expect(await ChaoxingSyncService.syncIfDue(), isNull);
    });

    test('没绑定 → syncNow 报错而不是抛异常', () async {
      final r = await ChaoxingSyncService.syncNow();
      expect(r.error, isNotNull);
      expect(r.addedTodos, 0);
      expect(r.exams, 0);
    });

    test('自动同步默认开着（用户绑完就生效，不用再去拨开关）', () async {
      expect(await ChaoxingSyncService.enabled(), isTrue);
    });

    test('上次同步时间/摘要：从没同步过时是空的', () async {
      expect(await ChaoxingSyncService.lastSyncAt(), isNull);
      expect(await ChaoxingSyncService.lastSummary(), isEmpty);
    });
  });

  group('id 前缀（清理与抑制全靠它）', () {
    test('待办前缀与考试前缀固定且不互相包含', () {
      expect(ChaoxingSyncService.todoIdPrefix, 'chaoxing_');
      expect(ChaoxingSyncService.examIdPrefix, 'chaoxing|');
      expect(
        ChaoxingSyncService.examIdPrefix
            .startsWith(ChaoxingSyncService.todoIdPrefix),
        isFalse,
        reason: '考试 id 若以待办前缀开头，清理待办时会把考试当成待办',
      );
    });

    test('🔴 抑制键按「id + 补零日期」组合，不同日期互不影响', () async {
      // 🔴 必须用**今天或将来**的日期：suppress() 会顺手清掉早于今天的
      //    过期键（那些待办早就过期了，留着没意义）。
      final now = DateTime.now();
      final day = DateTime(now.year, now.month, now.day);
      final other = day.add(const Duration(days: 1));
      const id = 'chaoxing_abc';

      expect(await ChaoxingSyncService.isSuppressed(id, day), isFalse);
      await ChaoxingSyncService.suppress(id, day);
      expect(await ChaoxingSyncService.isSuppressed(id, day), isTrue);

      // 日期必须补零：不补零时 2026-1-12 与 2026-11-02 会撞成同一个键
      //   （课程待办当年就栽在这里）。换个日期就不该命中。
      expect(await ChaoxingSyncService.isSuppressed(id, other), isFalse);

      await ChaoxingSyncService.unsuppress(id, day);
      expect(await ChaoxingSyncService.isSuppressed(id, day), isFalse);
    });

    test('过期日期登记会被顺手清掉（不给历史待办留垃圾键）', () async {
      final now = DateTime.now();
      final longAgo = DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 30));
      const id = 'chaoxing_old';

      await ChaoxingSyncService.suppress(id, longAgo);
      // 登记时就发现是过去 → 立刻被 prune 掉，所以查不到
      expect(await ChaoxingSyncService.isSuppressed(id, longAgo), isFalse);
    });

    test('抑制集合落盘后能读回来（不是内存态）', () async {
      final now = DateTime.now();
      final day = DateTime(now.year, now.month, now.day);
      const id = 'chaoxing_x';
      await ChaoxingSyncService.suppress(id, day);

      // 清掉内存缓存，模拟重启
      ChaoxingSyncService.debugResetCaches();
      expect(await ChaoxingSyncService.isSuppressed(id, day), isTrue);
    });
  });

  group('🔴 只读红线：源码里不许出现写接口', () {
    test('不许出现签到 / 交作业 / 考试作答的 URL', () {
      final src =
          File('lib/services/chaoxing/chaoxing_sync_service.dart').readAsStringSync();
      // 这些一旦被调用就是「替用户提交/签到」，越过了「只同步」这条界。
      const forbidden = <String>[
        'stuSignajax',
        'preSign',
        'addStudentWorkNew',
        'mooc-ans/api/work',
        'reVersionTestStartNew',
        'multimedia/log',
      ];
      for (final f in forbidden) {
        expect(src.contains(f), isFalse, reason: '同步服务里出现了写接口片段：$f');
      }
    });

    test('只调这两个读接口（任务流 + 课程任务）', () {
      final src =
          File('lib/services/chaoxing/chaoxing_sync_service.dart').readAsStringSync();
      expect(src.contains('fetchTaskFeed'), isTrue);
      expect(src.contains('fetchCourseTasks'), isTrue);

      // 判据必须落在「HTTP 提交调用」上，不能落在「有没有出现这个词」上：
      // 本服务有 `cxSubmitted` 状态、有解释 status 语义的注释（`1=submitted`），
      // 还有 `addAll` 这种纯集合操作 —— 按子串判定会全部误杀。
      // 真正要禁的是**发起写请求**：`.submitXxx(` 或 `.post*(`。
      final forbiddenCall = RegExp(r'\.\s*(?:submit[A-Za-z]*|post[A-Za-z]*)\s*\(');
      final hit = forbiddenCall.firstMatch(src);
      expect(
        hit,
        isNull,
        reason: '同步服务里出现了写请求调用：${hit?.group(0)}',
      );
    });
  });
}
