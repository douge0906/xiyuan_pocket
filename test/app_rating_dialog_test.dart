import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiyuan_pocket/widgets/app_rating_dialog.dart';

/// 五星评价弹窗回归：累计进入课表 3 次后的弹窗必须能正常构建，
/// 且同时给出「五星评价」与「推荐给新同学」两个入口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('五星评价弹窗展示五颗星与推荐入口', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => AppRatingDialog.show(ctx),
            child: const Text('打开'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('掌上锡院用得还顺手吗？'), findsOneWidget);
    expect(find.byIcon(Icons.star_outline_rounded), findsNWidgets(5));
    expect(find.text('推荐给新同学'), findsOneWidget);
    expect(find.text('以后再说'), findsOneWidget);
  });
}
