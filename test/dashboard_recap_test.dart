import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/monthly_recap_card.dart';

/// The monthly recap card on the Overview.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  final now = DateTime.now();
  final lastMonth = DateTime(now.year, now.month - 1);
  final monthName = DateFormat('MMMM').format(lastMonth);

  Future<void> pump(
    WidgetTester tester, {
    bool lastMonthData = true,
    bool hideIncome = false,
    void Function(String id, DateTime month)? onViewCategory,
  }) async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 250,
      note: 'this month',
      date: DateTime(now.year, now.month, 1),
    );
    if (lastMonthData) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'transport',
        amount: 400,
        note: 'Metro pass',
        date: DateTime(lastMonth.year, lastMonth.month, 2),
      );
      await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 3000,
        note: 'Pay',
        date: DateTime(lastMonth.year, lastMonth.month, 1),
      );
    }
    final s = SettingsProvider();
    await s.load();
    await s.setHideIncome(hideIncome);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(
          home: Scaffold(body: DashboardScreen(onViewCategory: onViewCategory)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder inCard(Finder f) =>
      find.descendant(of: find.byType(MonthlyRecapCard), matching: f);

  testWidgets('last month shows as a recap on the Overview, with no close '
      'control', (tester) async {
    await pump(tester);
    expect(find.byType(MonthlyRecapCard), findsOneWidget);
    expect(inCard(find.text('$monthName recap')), findsOneWidget);
    expect(inCard(find.text(fmtMoney(400))), findsOneWidget);
    expect(inCard(find.text(fmtMoney(3000))), findsOneWidget);
    expect(inCard(find.byIcon(Icons.close)), findsNothing);
    expect(inCard(find.byType(CloseButton)), findsNothing);
  });

  testWidgets('no recap without last month data', (tester) async {
    await pump(tester, lastMonthData: false);
    expect(find.byType(MonthlyRecapCard), findsNothing);
  });

  testWidgets('Hide income masks income and saved', (tester) async {
    await pump(tester, hideIncome: true);
    expect(inCard(find.text(kMaskedAmount)), findsNWidgets(2));
    expect(inCard(find.text(fmtMoney(3000))), findsNothing);
    // Spending stays visible.
    expect(inCard(find.text(fmtMoney(400))), findsOneWidget);
  });

  testWidgets('a top category opens its transactions for that month', (
    tester,
  ) async {
    String? id;
    DateTime? month;
    await pump(
      tester,
      onViewCategory: (i, m) {
        id = i;
        month = m;
      },
    );
    await tester.tap(inCard(find.textContaining('Transport')));
    expect(id, 'transport');
    expect(month, lastMonth);
  });
}
