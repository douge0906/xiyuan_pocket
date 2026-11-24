import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiyuan_pocket/pages/tools/resource_text_preview_page.dart';

/// 「我的下载」页里点本地 docx 的兜底链路。
///
/// 正文是服务端抽的（`GET /api/v1/resources/files/<id>/text`），断网或者
/// 服务端没抽出来时，这个文件明明就在本机 —— 必须给一个「用其他应用打开」
/// 的出口。以前这里不传 onDownload，用户只能看到一句失败文案然后卡住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 设备身份读不到 → fetchResourceTextPreview 会立刻返回失败，
    // 于是页面直接落到「错误 + 兜底按钮」那一支，不用真的联网。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      if (call.method == 'read') return null;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  testWidgets('拿到不了正文时，本地文件那条路要能给出「用其他应用打开」的出口',
      (tester) async {
    var tapped = 0;
    await tester.pumpWidget(MaterialApp(
      home: ResourceTextPreviewPage(
        title: '实验报告.docx',
        fileId: 8,
        onDownload: () async => tapped++,
        downloadLabel: '用其他应用打开本地文件',
      ),
    ));
    await tester.pumpAndSettle();

    // 兜底按钮必须真的渲染出来，且文案是给本地文件用的那句。
    final fallback = find.text('用其他应用打开本地文件');
    expect(fallback, findsOneWidget,
        reason: '正文抽不出来时，本地文件没有第二个出口');

    await tester.tap(fallback);
    await tester.pumpAndSettle();
    expect(tapped, 1, reason: '按钮必须真的接上回调，否则点了没反应');

    // 「重试」仍然在，两者不冲突。
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('没给兜底时不硬塞按钮（资源中心里有些文件确实没有本地副本）',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ResourceTextPreviewPage(title: '课件.pdf', fileId: 9),
    ));
    await tester.pumpAndSettle();

    expect(find.text('下载后用 Word 打开'), findsNothing);
    expect(find.text('用其他应用打开本地文件'), findsNothing);
    expect(find.text('重试'), findsOneWidget, reason: '重试是唯一出口，不能没有');
  });
}
