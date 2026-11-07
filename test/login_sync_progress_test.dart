import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/login_sync_progress.dart';

/// 登录预取步骤表回归（用户 m20950）。
///
/// 用户原话：「新增 电费自动同步，此步骤触发宿舍号填写。此外出现我的学业
/// 没有自动导入的情况。」—— 两件事都必须在登录后那串「自动同步」里出现，
/// 否则用户又只能看到「同步完成」，实际那两步根本没跑。
///
/// 钉四件事：
/// 1. 步骤表里有 study / elec 两步（顺序在最后，追在既有五步之后）；
/// 2. `order` 直接等于 `values`，所以加枚举成员 = 进度条自动多一行，
///    不存在「加了步骤但界面不显示」的中间态；
/// 3. 每步的 title / action 都不为空（界面直接显示它们）；
/// 4. `skipRest` 能把新步骤也标成失败，不会让对话框卡在「等待中」永远不关。
void main() {
  setUp(LoginSyncProgress.reset);

  group('步骤表', () {
    test('包含学业与电费两步', () {
      final names = LoginSyncStep.values.map((s) => s.name).toList();
      expect(names, contains('study'));
      expect(names, contains('elec'));
    });

    test('顺序固定：课表最先，学业/电费追在既有五步之后', () {
      expect(LoginSyncStep.values.first, LoginSyncStep.courses);
      final i = LoginSyncStep.values.indexOf(LoginSyncStep.card);
      expect(LoginSyncStep.values.indexOf(LoginSyncStep.study), i + 1);
      expect(LoginSyncStep.values.indexOf(LoginSyncStep.elec), i + 2);
    });

    test('order 与 values 一致（加成员即进进度条，不用改两处）', () {
      expect(LoginSyncProgress.order, LoginSyncStep.values);
      expect(LoginSyncProgress.order.length, LoginSyncStep.values.length);
    });

    test('每步都有非空标题与动作文案', () {
      for (final s in LoginSyncStep.values) {
        expect(s.title.trim(), isNotEmpty, reason: '${s.name} 缺 title');
        expect(s.action.trim(), isNotEmpty, reason: '${s.name} 缺 action');
      }
    });
  });

  group('进度推进', () {
    test('reset 后全部 pending，行数与步骤数一致', () {
      final items = LoginSyncProgress.notifier.value;
      expect(items.length, LoginSyncStep.values.length);
      expect(items.every((e) => e.status == LoginSyncStatus.pending), isTrue);
      expect(LoginSyncProgress.hasPending, isTrue);
    });

    test('学业与电费可以各自推进而不影响其它行', () {
      LoginSyncProgress.running(LoginSyncStep.study);
      expect(
        LoginSyncProgress.notifier.value
            .firstWhere((e) => e.step == LoginSyncStep.study)
            .status,
        LoginSyncStatus.running,
      );
      expect(LoginSyncProgress.isRunning, isTrue);

      LoginSyncProgress.done(LoginSyncStep.study, note: '10 个板块');
      LoginSyncProgress.failed(LoginSyncStep.elec, note: '未绑定宿舍');
      final map = {
        for (final e in LoginSyncProgress.notifier.value) e.step: e,
      };
      expect(map[LoginSyncStep.study]!.status, LoginSyncStatus.done);
      expect(map[LoginSyncStep.study]!.note, '10 个板块');
      expect(map[LoginSyncStep.elec]!.status, LoginSyncStatus.failed);
      expect(LoginSyncProgress.isRunning, isFalse);
    });

    test('skipRest 把新步骤也收掉（对话框不会卡住不关）', () {
      LoginSyncProgress.done(LoginSyncStep.courses);
      LoginSyncProgress.skipRest(note: '已跳过');
      expect(LoginSyncProgress.hasPending, isFalse);
      for (final e in LoginSyncProgress.notifier.value) {
        expect(e.status,
            anyOf(LoginSyncStatus.done, LoginSyncStatus.failed));
      }
    });
  });
}
