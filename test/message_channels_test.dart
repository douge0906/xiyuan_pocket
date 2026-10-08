import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/models/message.dart';
import 'package:xiyuan_pocket/services/campus/campus_info_crawler.dart';
import 'package:xiyuan_pocket/services/message_archive.dart';
import 'package:xiyuan_pocket/services/message_channel_service.dart';
import 'package:xiyuan_pocket/services/message_detail_cache.dart';
import 'package:xiyuan_pocket/services/message_migration.dart';
import 'package:xiyuan_pocket/services/message_source.dart';
import 'package:xiyuan_pocket/services/seed_data.dart';

/// 消息系统的「订阅目录 / 老数据迁移」两层。
///
/// 这两层出问题都是**静默**的：
/// * 目录错了 → 用户升级后发现订阅被清空、栏目消失；
/// * 迁移错了 → 用户升级后所有列表变空（看着像「更新完消息就没了」）。
/// 所以每一条都要钉住。
void main() {
  // 种子测试要读 assets（rootBundle），必须有 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('订阅目录', () {
    test('所有对外开放的栏目都必须在抓取器里登记过（防幽灵栏目）', () {
      for (final c in MessageChannelService.allChannels) {
        if (c.id == kJwcChannelId) continue;
        expect(CampusInfoCrawler.columnById(c.id), isNotNull,
            reason: '栏目「${c.id}」在目录里，却没有抓取器 —— 订阅了也抓不到内容');
      }
    });

    test('默认订阅只含教务处（其余栏目靠用户自己勾）', () {
      expect(MessageChannelService.defaultSubscribedIds, {kJwcChannelId});
    });

    test('从未保存过 → 用默认集合', () async {
      final ids = await MessageChannelService.loadSubscribed();
      expect(ids, {kJwcChannelId});
    });

    test('🔴 保存过空集合 → 就是空的，不能自己长回来', () async {
      await MessageChannelService.saveSubscribed({});
      expect(await MessageChannelService.loadSubscribed(), isEmpty);
    });

    test('🔴 教务处真的可以被关掉（所有栏目一律平等）', () async {
      await MessageChannelService.saveSubscribed({'news'});
      final ids = await MessageChannelService.loadSubscribed();
      expect(ids, {'news'});
      expect(ids.contains(kJwcChannelId), isFalse,
          reason: '教务处不是特权栏目，取消订阅必须生效');
    });

    test('已下线的栏目 id 会被过滤掉', () async {
      await MessageChannelService.saveSubscribed({'news', 'ghost_column'});
      expect(await MessageChannelService.loadSubscribed(), {'news'});
    });
  });

  group('老缓存键 → 新档案键的迁移', () {
    test('教务处列表：school_notice_list_cache → message_archive_jwc', () async {
      SharedPreferences.setMockInitialValues({
        'school_notice_list_cache': jsonEncode([
          {
            'id': '5965',
            'title': '关于做好年报工作的通知',
            'date': '2026-09-21',
            'url': 'https://jwc.cwxu.edu.cn/info/1100/5965.htm',
            'has_content': true,
            'views': 14,
          },
        ]),
      });

      await MessageMigration.ensureMigrated();

      final items = await MessageArchive.load(kJwcChannelId);
      expect(items.length, 1);
      expect(items.first.id, '5965');
      expect(items.first.title, '关于做好年报工作的通知');
      expect(items.first.url, 'https://jwc.cwxu.edu.cn/info/1100/5965.htm');
      expect(items.first.badge, '教务处');
    });

    test('教务处详情：url 从列表里补回来（老详情结构里没有 url）', () async {
      SharedPreferences.setMockInitialValues({
        'school_notice_list_cache': jsonEncode([
          {
            'id': '5965',
            'title': 'T',
            'date': '2026-09-21',
            'url': 'https://jwc.cwxu.edu.cn/info/1100/5965.htm',
          },
        ]),
        'school_notice_detail_5965': jsonEncode({
          'title': 'T',
          'date': '2026-09-21',
          'author': '马老师',
          'content': '正文',
        }),
      });

      await MessageMigration.ensureMigrated();

      final d = await MessageDetailCache.load(kJwcChannelId, '5965');
      expect(d, isNotNull);
      expect(d!.author, '马老师');
      expect(d.content, '正文');
      expect(d.url, 'https://jwc.cwxu.edu.cn/info/1100/5965.htm',
          reason: '详情页「查看原文」依赖 url，缺了就等于没有原文入口');
    });

    test('🔴 资讯详情键在「第一个下划线」处切分（id 自身含下划线）', () async {
      SharedPreferences.setMockInitialValues({
        'campus_info_list_news': jsonEncode([
          {
            'id': '1039_21435',
            'title': '活动通知',
            'date': '2026-09-22',
            'url': 'https://www.cwxu.edu.cn/info/1039/21435.htm',
          },
        ]),
        'campus_info_detail_news_1039_21435': jsonEncode({
          'id': '1039_21435',
          'title': '活动通知',
          'date': '2026-09-22',
          'author': '',
          'url': 'https://www.cwxu.edu.cn/info/1039/21435.htm',
          'content': '正文内容',
        }),
      });

      await MessageMigration.ensureMigrated();

      final list = await MessageArchive.load('news');
      expect(list.single.id, '1039_21435');
      expect(list.single.badge, '校园要闻');

      final d = await MessageDetailCache.load('news', '1039_21435');
      expect(d, isNotNull, reason: '切错位置会得到 sourceId=news / id=1039 —— 详情就找不到了');
      expect(d!.sourceId, 'news');
      expect(d.content, '正文内容');
    });

    test('🔴 已有新档案 → 迁移绝不覆盖（不能把更新的数据盖回旧的）', () async {
      SharedPreferences.setMockInitialValues({
        'message_archive_jwc': jsonEncode([
          Message(
            id: 'newer',
            sourceId: kJwcChannelId,
            title: '更新过的档案',
            date: '2026-10-08',
            url: 'u',
          ).toJson(),
        ]),
        'school_notice_list_cache': jsonEncode([
          {'id': 'older', 'title': '老缓存', 'date': '2026-09-21', 'url': 'u'},
        ]),
      });

      await MessageMigration.ensureMigrated();

      final items = await MessageArchive.load(kJwcChannelId);
      expect(items.single.id, 'newer');
    });

    test('迁移只做一次（标记置位后不再重跑）', () async {
      SharedPreferences.setMockInitialValues({
        'school_notice_list_cache': jsonEncode([
          {'id': '5965', 'title': 'T', 'date': '2026-09-21', 'url': 'u'},
        ]),
      });

      await MessageMigration.ensureMigrated();
      // 清掉档案，模拟「档案被清空」；标记已置位 → 不该再迁一次
      await MessageArchive.clear(kJwcChannelId);
      await MessageMigration.ensureMigrated();

      expect(await MessageArchive.load(kJwcChannelId), isEmpty);
    });
  });

  group('内置种子数据的翻译', () {
    /// 真跑一次种子，确认 300KB 的快照被翻译到了**新的档案键**上。
    /// 只测「翻译函数」是没用的 —— 出问题的从来是「写到了哪个键」。
    test('教务处：列表 + 详情都落到新键上，且详情带 url', () async {
      await SeedData.ensureApplied();

      final list = await MessageArchive.load(kJwcChannelId);
      expect(list, isNotEmpty, reason: '首次安装必须能秒出内容（不预置就要干等联网）');
      expect(list.first.badge, '教务处');
      expect(list.first.url, isNotEmpty);

      final d = await MessageDetailCache.load(kJwcChannelId, list.first.id);
      expect(d, isNotNull, reason: '快照里的详情必须能按新键取到');
      expect(d!.url, isNotEmpty,
          reason: '详情没有 url，「查看原文」就没了入口');
      expect(d.content, isNotEmpty);
    });

    test('资讯栏目：各栏目列表也写入了档案', () async {
      await SeedData.ensureApplied();

      var withContent = 0;
      for (final c in MessageChannelService.campusChannels) {
        final items = await MessageArchive.load(c.id);
        if (items.isNotEmpty) {
          withContent++;
          expect(items.first.badge, c.name);
        }
      }
      expect(withContent, greaterThan(0),
          reason: '一个都没有 = 用户勾选栏目后仍然要干等联网');
    });

    test('资讯栏目详情也落到新键上（快照的详情键含下划线，切分要对）', () async {
      await SeedData.ensureApplied();

      // 从某个栏目的档案里取第一条，按新键去读它的详情 ——
      // 键切错位置（例如取最后一个下划线）这里就会是 null。
      for (final c in MessageChannelService.campusChannels) {
        final items = await MessageArchive.load(c.id);
        if (items.isEmpty) continue;
        final d = await MessageDetailCache.load(c.id, items.first.id);
        expect(d, isNotNull,
            reason: '栏目 ${c.id} 的详情键切分错了，点进去会白屏');
        expect(d!.sourceId, c.id);
        expect(d.content, isNotEmpty);
        return;
      }
      fail('没有任何校园资讯栏目的档案可用，无法验证详情键');
    });

    test('已有档案时种子不覆盖（更新的数据不能被旧快照盖回）', () async {
      SharedPreferences.setMockInitialValues({
        'message_archive_$kJwcChannelId': jsonEncode([
          Message(
            id: 'mine',
            sourceId: kJwcChannelId,
            title: '用户自己抓到的',
            date: '2026-10-08',
            url: 'u',
          ).toJson(),
        ]),
      });

      await SeedData.ensureApplied();

      final items = await MessageArchive.load(kJwcChannelId);
      expect(items.single.id, 'mine');
    });
  });
}
