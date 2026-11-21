import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xiyuan_pocket/services/resource_store.dart';

void main() {
  test('课程名归一化：空白、括号、连接符都忽略', () {
    expect(normalizeResourceName(' 高等数学（A） '), '高等数学a');
    expect(normalizeResourceName('高等 数学-A'), '高等数学a');
  });

  test('课程 + 教材组合键：同课不同教材必须分开', () {
    expect(resourceKey('高等数学', '上册'), resourceKey(' 高等数学 ', '上册'),
        reason: '空白差异不应拆成两张卡');
    expect(resourceKey('高等数学', '上册'),
        isNot(resourceKey('高等数学', '下册')));
    expect(normalizeResourceBook(' 高等数学 上册 '), '高等数学上册');
  });

  test('缓存里同课不同教材会保留两张卡片', () async {
    SharedPreferences.setMockInitialValues({
      'resource_center_cache_v1': jsonEncode({
        'courses': [
          {
            'courseName': '高等数学',
            'bookName': '上册',
            'files': [
              {'id': 1, 'name': '上册.pdf', 'area': 'textbook', 'size': 100}
            ]
          },
          {
            'courseName': '高等数学',
            'bookName': '下册',
            'files': [
              {'id': 2, 'name': '下册.pdf', 'area': 'textbook', 'size': 100}
            ]
          }
        ]
      }),
    });
    final result = await ResourceStore.loadCachedResult();
    expect(result.courses, hasLength(2));
    expect(result.courses.map((c) => c.book), containsAll(['上册', '下册']));
  });

  test('资源文件解析 uploadId，供举报定位上传批次', () async {
    SharedPreferences.setMockInitialValues({
      'resource_center_cache_v1': jsonEncode({
        'courses': [
          {
            'courseName': '高等数学',
            'bookName': '上册',
            'files': [
              {
                'id': 1,
                'uploadId': 9,
                'name': '教材.pdf',
                'area': 'textbook',
                'size': 100
              }
            ]
          }
        ]
      }),
    });
    final result = await ResourceStore.loadCachedResult();
    expect(result.courses.first.resources.first.uploadId, 9);
  });

  test('本地缓存可独立读出课程与试卷答案', () async {
    SharedPreferences.setMockInitialValues({
      'resource_center_cache_v1': jsonEncode({
        'courses': [
          {
            'courseName': '高等数学',
            'bookName': '高数上册',
            'files': [
              {'id': 1, 'name': '教材.pdf', 'area': 'textbook', 'size': 100},
              {'id': 2, 'name': '试卷.pdf', 'area': 'exam_paper', 'size': 200},
              {
                'id': 3,
                'name': '答案.pdf',
                'area': 'answer',
                'size': 50,
                'parentId': 2
              }
            ]
          }
        ]
      }),
      'resource_center_cache_at_v1': '2026-10-29T10:00:00+08:00',
    });
    final result = await ResourceStore.loadCachedResult();
    expect(result.courses, hasLength(1));
    expect(result.courses.first.name, '高等数学');
    expect(result.courses.first.of(ResourceKind.examPaper), hasLength(1));
    expect(result.courses.first.of(ResourceKind.answer).first.parentId, 2);
    expect(result.syncedAt, isNotNull);
  });

  test('贡献者署名随文件解析出来；缺字段当匿名', () async {
    SharedPreferences.setMockInitialValues({
      'resource_center_cache_v1': jsonEncode({
        'courses': [
          {
            'courseName': '高等数学',
            'files': [
              {
                'id': 1,
                'name': '教材.pdf',
                'area': 'textbook',
                'size': 100,
                'contributor': '小姜'
              },
              {'id': 2, 'name': '试卷.pdf', 'area': 'exam_paper', 'size': 200},
              {
                'id': 3,
                'name': '答案.pdf',
                'area': 'answer',
                'size': 50,
                'contributor': ''
              }
            ]
          }
        ]
      }),
    });
    final result = await ResourceStore.loadCachedResult();
    final entries = result.courses.first.resources;
    expect(entries[0].contributor, '小姜');
    expect(entries[1].contributor, '', reason: '老缓存没有该字段，要兜底成空串');
    expect(entries[2].contributor, '');
  });

  test('署名记忆：存了能读回，存空串等于清掉', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await ResourceStore.loadContributor(), '');
    await ResourceStore.saveContributor('  小姜  ');
    expect(await ResourceStore.loadContributor(), '小姜',
        reason: '两端空格要去掉');
    await ResourceStore.saveContributor('   ');
    expect(await ResourceStore.loadContributor(), '',
        reason: '存空白等于清掉，下次默认匿名');
  });

  test('课程资源按教材/试卷/答案分组', () {
    final course = ResourceCourse(
      name: '高等数学',
      book: '高数上册',
      resources: const [
        ResourceEntry(name: '教材.pdf', kind: ResourceKind.textbook),
        ResourceEntry(name: '期末.pdf', kind: ResourceKind.examPaper),
        ResourceEntry(name: '期末答案.pdf', kind: ResourceKind.answer),
      ],
    );
    expect(course.of(ResourceKind.textbook).length, 1);
    expect(course.of(ResourceKind.examPaper).length, 1);
    expect(course.of(ResourceKind.answer).length, 1);
  });
}
