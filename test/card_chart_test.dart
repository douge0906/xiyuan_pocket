import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiyuan_pocket/services/dorm_service.dart';
import 'package:xiyuan_pocket/widgets/card_spending_chart.dart';

CardTxn _txn(int daysAgo, double yuan, {bool income = false}) {
  final t = DateTime.now().subtract(Duration(days: daysAgo));
  return CardTxn(
    time: t.toIso8601String().substring(0, 19),
    title: '测试',
    place: '',
    amountYuan: yuan,
    isIncome: income,
    balanceYuan: 100,
  );
}

void main() {
  testWidgets('两天以上有支出 → 显示趋势与合计', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CardSpendingChart(items: [
          _txn(1, 12.5),
          _txn(0, 8),
          _txn(0, 20, income: true), // 收入不计入
        ]),
      ),
    ));
    expect(find.text('消费趋势'), findsOneWidget);
    expect(find.textContaining('共 ¥20.50'), findsOneWidget);
  });

  testWidgets('只有一天消费 → 不显示（画不出趋势）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: CardSpendingChart(items: [_txn(0, 8)])),
    ));
    expect(find.text('消费趋势'), findsNothing);
  });

  testWidgets('空列表 → 不显示', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: CardSpendingChart(items: [])),
    ));
    expect(find.text('消费趋势'), findsNothing);
  });
}
