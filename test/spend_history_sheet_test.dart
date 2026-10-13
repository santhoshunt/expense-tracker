import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/spend_history.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/chart_popup.dart';
import 'package:expense_tracker/widgets/monthly_bar_chart.dart';
import 'package:expense_tracker/widgets/spend_history_sheet.dart';

/// The category and merchant history sheet, and the bar chart's
/// single-series mode it draws with. Dates are fixed past months; amounts
/// and notes are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  /// January to December 2025: wholly in the past, so no month runs.
  final months = [for (var m = 1; m <= 12; m++) DateTime(2025, m)];

  const food = HistorySubject.category('food', 'Food & Dining');
  const education = HistorySubject.category('education', 'Education');

  /// Food in March, July and December 2025; nothing else.
  Future<FinanceProvider> ledger() async {
    final p = FinanceProvider();
    await p.load();
    for (final (amount, date) in [
      (1200.0, DateTime(2025, 3, 10)),
      (800.0, DateTime(2025, 7, 5)),
      (450.0, DateTime(2025, 12, 2)),
    ]) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: amount,
        note: 'test meal',
        date: date,
      );
    }
    return p;
  }

  /// Pumps a button that opens the sheet, and opens it.
  Future<void> open(
    WidgetTester tester,
    FinanceProvider p, {
    HistorySubject subject = food,
    bool yearView = false,
    VoidCallback? onViewTransactions,
    Size size = const Size(400, 900),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: p,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showSpendHistorySheet(
                    context,
                    subject: subject,
                    months: months,
                    windowLabel: yearView ? '2025' : '12 months to Dec 2025',
                    yearView: yearView,
                    icon: Icons.restaurant,
                    color: Colors.orange,
                    onViewTransactions: onViewTransactions,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the label, the window and the three tiles', (
    tester,
  ) async {
    await open(tester, await ledger());
    expect(find.text('Food & Dining'), findsOneWidget);
    expect(find.text('12 months to Dec 2025'), findsOneWidget);
    expect(find.byType(MonthlyBarChart), findsOneWidget);
    expect(find.text('Usual month'), findsOneWidget);
    expect(find.text('Middle of up to 6 whole months'), findsOneWidget);
    expect(find.text('Biggest'), findsOneWidget);
    expect(find.text(fmtMoney(1200)), findsOneWidget);
    expect(find.text('Mar 2025'), findsOneWidget);
    // December 2025 is over, so the tile names it rather than "so far".
    expect(find.text('In December'), findsOneWidget);
    expect(find.text('This month so far'), findsNothing);
    expect(find.text(fmtMoney(450)), findsOneWidget);
  });

  testWidgets('View transactions closes the sheet and calls back once', (
    tester,
  ) async {
    var calls = 0;
    await open(tester, await ledger(), onViewTransactions: () => calls++);
    final view = find.text('View transactions');
    await tester.ensureVisible(view);
    await tester.pumpAndSettle();
    await tester.tap(view);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Food & Dining'), findsNothing);
    expect(find.text('View transactions'), findsNothing);
  });

  testWidgets('a category with no spend says so and offers no button', (
    tester,
  ) async {
    await open(
      tester,
      await ledger(),
      subject: education,
      onViewTransactions: () {},
    );
    expect(
      find.text('Nothing spent on Education in these months.'),
      findsOneWidget,
    );
    expect(find.byType(MonthlyBarChart), findsNothing);
    expect(find.text('None yet'), findsOneWidget);
    expect(find.text('View transactions'), findsNothing);
  });

  testWidgets('Year view totals the year in the third tile', (tester) async {
    var calls = 0;
    await open(
      tester,
      await ledger(),
      yearView: true,
      onViewTransactions: () => calls++,
    );
    expect(find.text('Year total'), findsOneWidget);
    expect(find.text(fmtMoney(2450)), findsOneWidget);
    expect(find.text('In December'), findsNothing);
    expect(find.text('View transactions'), findsOneWidget);
  });

  for (final yearView in [false, true]) {
    testWidgets('fits 320dp at text x2, year view $yearView', (tester) async {
      await open(
        tester,
        await ledger(),
        yearView: yearView,
        onViewTransactions: () {},
        size: const Size(320, 640),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Food & Dining'), findsOneWidget);
    });
  }

  testWidgets('a single-series bar opens one row, with no income', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                child: MonthlyBarChart(
                  months: months,
                  seriesOf: (m) => m.month == 3 ? 1200.0 : 300.0,
                  seriesLabel: 'Spent',
                  barColor: Colors.orange,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final box = tester.getRect(find.byType(MonthlyBarChart));
    // The third of twelve groups is March.
    await tester.tapAt(Offset(box.left + box.width * 2.5 / 12, box.center.dy));
    await tester.pumpAndSettle();

    Finder inPopup(String text) =>
        find.descendant(of: find.byType(ChartPopup), matching: find.text(text));
    expect(inPopup('March 2025'), findsOneWidget);
    expect(inPopup('Spent'), findsOneWidget);
    expect(inPopup(fmtMoney(1200)), findsOneWidget);
    expect(find.text('Income'), findsNothing);
    expect(find.text('Expense'), findsNothing);
    expect(find.text('Net'), findsNothing);
  });
}
