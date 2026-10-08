import 'package:flutter_test/flutter_test.dart';

import 'package:xiyuan_pocket/models/course_model.dart';
import 'package:xiyuan_pocket/services/widget_sync_service.dart';

/// 桌面小组件「今日课表」的显示口径测试（2026-10-08）。
///
/// 背景：有同学反馈「课表时间和小组件不同步」。根因是小组件上那行
/// `timeText` 用 `end.split('-').first` 取了「结束节次的**开始**时刻」：
/// 1-2 节的课本该 08:00–09:40，小组件印成 08:00–**08:55**，少 45 分钟。
/// 更要命的是同一个组件里有两套口径 —— 原生「下一节课」的切换用的是
/// startMinute/endMinute（那套是**对的**），于是会出现「正确高亮着这节课、
/// 底下却印着错的结束时间」。
///
/// 现在显示与判定共用同一份分钟数。这个文件把「全 66 种节次组合」都对一遍，
/// 免得哪天又有人回去拆字符串。
Course _c(int start, int end) => Course(
      id: 't',
      name: '测试课',
      weekday: 1,
      startSlot: start,
      endSlot: end,
      colorValue: 0xFF000000,
    );

/// 默认上课时间表（与 `kDefaultCourseBlocks` / 内置默认表一致）。
/// 这里**硬编码**一份，而不是从被测代码里取 —— 否则就是拿被测对象证明它自己。
const Map<int, (String, String)> kDefaultSlots = {
  1: ('08:00', '08:45'),
  2: ('08:55', '09:40'),
  3: ('10:10', '10:55'),
  4: ('11:05', '11:50'),
  5: ('13:45', '14:30'),
  6: ('14:40', '15:25'),
  7: ('15:55', '16:40'),
  8: ('16:50', '17:35'),
  9: ('18:45', '19:30'),
  10: ('19:40', '20:25'),
  11: ('20:35', '21:20'),
};

/// 规格表转成 `slotTimesFrom` 的产物形态（`"起-止"`）。
///
/// ⚠️ 必须传入**这个**表，不能传空表 `{}`：传空表会走 `_slotMinute` 内部的
/// 兜底分钟表，那是另一条代码路径 —— 用它测「时间区间算错」这类 bug 是测不到的
/// （已经验证过：传空表时把实现改回错误写法，测试红的是兜底分支，不是原始 bug）。
final Map<int, String> kDefaultMap = {
  for (final e in kDefaultSlots.entries) e.key: '${e.value.$1}-${e.value.$2}',
};

void main() {
  group('小组件时间显示（默认时间表）', () {
    test('内置默认表本身与规格一致（顺便钉住 _defaultSlotTimes）', () {
      final built = WidgetSyncService.slotTimesFrom(null);
      for (final e in kDefaultSlots.entries) {
        expect(built[e.key], kDefaultMap[e.key], reason: '第 ${e.key} 节');
      }
    });

    test('🔴 回归：1-2 节的课必须显示 08:00-09:40，不是 08:00-08:55', () {
      final text = WidgetSyncService.timeTextFor(_c(1, 2), kDefaultMap);
      expect(text, '08:00-09:40');
      // 把当年那个错值钉死：它取的是第 2 节的**开始**时刻
      expect(text, isNot('08:00-08:55'));
    });

    test('🔴 全矩阵：66 种节次组合，起止都必须落在「首节开始 → 末节结束」', () {
      for (var a = 1; a <= 11; a++) {
        for (var b = a; b <= 11; b++) {
          final text = WidgetSyncService.timeTextFor(_c(a, b), kDefaultMap);
          final want = '${kDefaultSlots[a]!.$1}-${kDefaultSlots[b]!.$2}';
          expect(text, want, reason: '第 $a-$b 节显示错了');
        }
      }
    });

    test('单节课：起止就是这一节自己的起止', () {
      expect(WidgetSyncService.timeTextFor(_c(1, 1), kDefaultMap), '08:00-08:45');
      expect(
          WidgetSyncService.timeTextFor(_c(11, 11), kDefaultMap), '20:35-21:20');
    });

    test('连堂跨午休、跨晚上也对（5-6 / 9-11）', () {
      expect(WidgetSyncService.timeTextFor(_c(5, 6), kDefaultMap), '13:45-15:25');
      expect(WidgetSyncService.timeTextFor(_c(9, 11), kDefaultMap), '18:45-21:20');
    });

    test('🔴 结束时刻必须是末节的**结束**，逐节验证（当年错的就是这一处）', () {
      for (final e in kDefaultSlots.entries) {
        final slot = e.key;
        final want = '08:00-${e.value.$2}';
        expect(WidgetSyncService.timeTextFor(_c(1, slot), kDefaultMap), want,
            reason: '第 1-$slot 节的结束时刻取错了');
        // 同一节，错的写法会给出「这一节的开始」
        expect(WidgetSyncService.timeTextFor(_c(1, slot), kDefaultMap),
            isNot('08:00-${e.value.$1}'));
      }
    });
  });

  group('时间块 → 节次时间表', () {
    test('没存过 / 空列表 → 回落默认表', () {
      expect(WidgetSyncService.slotTimesFrom(null)[2], '08:55-09:40');
      expect(WidgetSyncService.slotTimesFrom(const [])[2], '08:55-09:40');
    });

    test('用户自定义单节块：按自定义值走', () {
      final map = WidgetSyncService.slotTimesFrom(const [
        {'start': 1, 'end': 1, 'time': '08:10\n08:55'},
        {'start': 2, 'end': 2, 'time': '09:05\n09:50'},
      ]);
      expect(map[1], '08:10-08:55');
      expect(WidgetSyncService.timeTextFor(_c(1, 2), map), '08:10-09:50');
    });

    test('🔴 区间块必须铺满它覆盖的每一节（否则 map[末节] 落空）', () {
      // 一个块覆盖第 1-2 节
      final map = WidgetSyncService.slotTimesFrom(const [
        {'start': 1, 'end': 2, 'time': '08:00\n09:40'},
      ]);
      expect(map[1], '08:00-09:40');
      expect(map[2], '08:00-09:40',
          reason: '区间块没铺到第 2 节 → 跨节课会退化成「第1节-2节」');
      expect(WidgetSyncService.timeTextFor(_c(1, 2), map), '08:00-09:40');
    });

    test('脏数据不崩：缺字段 / end 小于 start / 只有一行 / 缺 start', () {
      final map = WidgetSyncService.slotTimesFrom(const [
        {'start': 1, 'time': '08:00\n08:45'}, // 缺 end → 当成单节
        {'start': 3, 'end': 2, 'time': '10:10\n11:50'}, // end < start → 按 start 收口
        {'start': 4, 'end': 4, 'time': '只有一行'}, // 没有 \n → 跳过
        {'end': 5, 'time': '13:45\n14:30'}, // 缺 start → 跳过
      ]);
      expect(map[1], '08:00-08:45');
      expect(map[3], '10:10-11:50');
      expect(map.containsKey(2), isFalse);
      expect(map.containsKey(4), isFalse);
      expect(map.containsKey(5), isFalse);
      // 被跳过的节次回落到默认表，不会没有时间
      expect(WidgetSyncService.timeTextFor(_c(4, 5), map), '11:05-14:30');
    });

    test('同一节被两个块覆盖 → 后写的赢（不崩即可）', () {
      final map = WidgetSyncService.slotTimesFrom(const [
        {'start': 1, 'end': 2, 'time': '08:00\n09:40'},
        {'start': 2, 'end': 2, 'time': '09:00\n09:45'},
      ]);
      expect(map[2], '09:00-09:45');
    });
  });
}
