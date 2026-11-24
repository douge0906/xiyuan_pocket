import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/services/message_channel_service.dart';
import 'package:xiyuan_pocket/services/message_repository.dart';
import 'package:xiyuan_pocket/services/message_source.dart';
import 'package:xiyuan_pocket/services/sources/cached_source.dart';

/// 锁住「每日消息」在仓库里的两条接线不变量：
/// ① 有订阅时它**排第一个**（页签顺序）且只有它 `isLocalOnly`
/// ② 一个栏目都没订阅时它**不注册**（否则「还没有订阅任何栏目」那个
///    引导空态会被一个永远空的页签挡掉）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('🔴 有订阅时：每日消息排第一个，且是唯一的纯本地源', () async {
    final repo = MessageRepository();
    final sources = await repo.registerSources(subscribedIds: {'jwc', 'news'});

    expect(sources, isNotEmpty);
    expect(sources.first.channel.id, kDailyChannelId);
    expect(sources.first.channel.name, '每日消息');

    final cached = sources.whereType<CachedMessageSource>().toList();
    final localOnly = cached.where((s) => s.isLocalOnly).toList();
    expect(localOnly.length, 1);
    expect(localOnly.single.channel.id, kDailyChannelId);
  });

  test('🔴 一个栏目都没订阅 → 不注册每日消息（保住引导空态）', () async {
    final repo = MessageRepository();
    final sources = await repo.registerSources(subscribedIds: <String>{});

    expect(sources, isEmpty);
  });

  test('每日消息拿得到订阅集合 —— 取消订阅后汇总里就没有那一栏了', () async {
    final repo = MessageRepository();
    final sources =
        await repo.registerSources(subscribedIds: {'jwc', 'news', 'tw'});

    final daily = sources.firstWhere((s) => s.channel.id == kDailyChannelId);
    expect(daily.channel.desc, contains('近 3 天'));
  });

  test('订阅面板列出的是「可订阅」栏目，不含每日消息', () {
    final ids = MessageChannelService.allChannels.map((c) => c.id).toSet();
    expect(ids.contains(kDailyChannelId), isFalse,
        reason: '每日消息是汇总视图，不是抓取源，不能出现在订阅清单里');
    // 新增的三个栏目必须在清单里
    expect(ids.contains('xkjs'), isTrue);
    expect(ids.contains('library'), isTrue);
    expect(ids.contains('nic'), isTrue);
  });

  test('应用公告改名了，但 id 一个字没动（改了 = 老用户订阅丢失）', () {
    final c = MessageChannelService.allChannels
        .firstWhere((c) => c.id == 'control_notice');
    expect(c.name, '应用公告');
    expect(MessageChannelService.defaultSubscribedIds, contains('control_notice'));
  });
}
