import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/utils/offscreen_capture.dart';

/// 离屏长图导出的回归测试。
///
/// 关键断言：**内容高度远超一屏时，图仍然是完整的一张**。
/// 这正是用户报的那个 bug（导出的图只有一屏）。
void main() {
  testWidgets('离屏捕获能把超过一屏的内容完整渲染成 PNG', (tester) async {
    late Future<Uint8List?> pending;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () {
                pending = OffscreenCapture.capture(
                  context,
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 60 行 × 40dp = 2400dp，屏幕只有 600dp 高。
                      for (var i = 0; i < 60; i++)
                        SizedBox(height: 40, child: Text('行 $i')),
                    ],
                  ),
                  width: 320,
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pump();

    // toImage / toByteData 是真异步，必须在 runAsync 里等，否则测试的
    // 假时钟不会推进它。
    final bytes = await tester.runAsync(() => pending);
    expect(bytes, isNotNull, reason: '离屏渲染应当产出 PNG 字节');
    // PNG 魔数
    expect(bytes!.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

    // 🔴 核心断言：图必须是「整张长图」，不是一屏。
    // PNG 的 IHDR 里 width 在 16..19、height 在 20..23（big-endian）。
    int be32(int at) =>
        (bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3];
    final w = be32(16);
    final h = be32(20);
    // 内容 2400dp，pixelRatio 3 → 7200px；宽度 320dp → 960px。
    expect(w, 960, reason: '宽度应当刚好是 content 宽度 × pixelRatio');
    expect(h, 7200, reason: '高度必须是全部 2400dp 内容，而不是一屏 600dp');
  });

  testWidgets('内容为空时不崩（返回 null 即可）', (tester) async {
    late Future<Uint8List?> pending;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () {
                pending = OffscreenCapture.capture(
                  context,
                  const SizedBox.shrink(),
                  width: 320,
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.runAsync(() => pending);
    // 高度为 0 → 走 null 分支，不抛异常即为通过。
    expect(tester.takeException(), isNull);
  });
}
