import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/services/monthly_recap.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/monthly_recap_card.dart';

import 'dashboard_test_utils.dart';

/// The Overview's month card: last month's recap for the first week, this
/// month's pace after, and where it sits on the page.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  tearDown(() => recapClock = DateTime.now);

  final now = DateTime.now();
  final lastMonth = DateTime(now.year, now.month - 1);
  final lastName = DateFormat('MMMM').format(lastMonth);
  final thisName = DateFormat('MMMM').format(DateTime(now.year, now.month));

  /// Pumps the dashboard as if today were day [day] of this month.
  Future<void> pump(
    WidgetTester tester, {
    required int day,
    bool lastMonthData = true,
    void Function(String id, DateTime month)? onViewCategory,
  }) async {
    recapClock = () => DateTime(now.year, now.month, day, 10);
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

  Finder inRecap(Finder f) =>
      find.descendant(of: find.byType(MonthlyRecapCard), matching: f);

  testWidgets('the first week shows last month\'s recap: no income, no '
      'close control', (tester) async {
    await pump(tester, day: 3);
    expect(find.byType(MonthlyRecapCard), findsOneWidget);
    expect(find.byType(MonthPaceCard), findsNothing);
    expect(inRecap(find.text('$lastName recap')), findsOneWidget);
    expect(inRecap(find.text(fmtMoney(400))), findsOneWidget);
    expect(inRecap(find.text('Income')), findsNothing);
    expect(inRecap(find.text(fmtMoney(3000))), findsNothing);
    expect(inRecap(find.byIcon(Icons.close)), findsNothing);
  });

  testWidgets('no recap without last month data', (tester) async {
    await pump(tester, day: 3, lastMonthData: false);
    expect(find.byType(MonthlyRecapCard), findsNothing);
  });

  testWidgets('after the first week, this month so far against last', (
    tester,
  ) async {
    await pump(tester, day: 20);
    expect(find.byType(MonthlyRecapCard), findsNothing);
    final pace = find.byType(MonthPaceCard);
    expect(pace, findsOneWidget);
    Finder inPace(Finder f) => find.descendant(of: pace, matching: f);
    expect(inPace(find.text('$thisName so far')), findsOneWidget);
    expect(inPace(find.textContaining('1 to 20')), findsOneWidget);
    expect(inPace(find.text(fmtMoney(250))), findsOneWidget);
    expect(inPace(find.text(fmtMoney(400))), findsOneWidget);
  });

  testWidgets('a long budget name wraps instead of overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    recapClock = () => DateTime(now.year, now.month, 3, 10);
    final p = FinanceProvider();
    await p.load();
    await p.addBudget(
      name: 'Personal spendings and weekend entertainment',
      limit: 100,
      mode: BudgetMode.include,
      categoryIds: {'transport'},
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'transport',
      amount: 400,
      note: 'Metro pass',
      date: DateTime(lastMonth.year, lastMonth.month, 2),
    );
    final s = SettingsProvider();
    await s.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: const MaterialApp(home: Scaffold(body: DashboardScreen())),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      inRecap(find.textContaining('over by ${fmtMoney(300)}')),
      findsOneWidget,
    );
    // A RenderFlex overflow would have failed the test by now.
    expect(tester.takeException(), isNull);
  });

  testWidgets('a top category opens its transactions for that month', (
    tester,
  ) async {
    String? id;
    DateTime? month;
    await pump(
      tester,
      day: 3,
      onViewCategory: (i, m) {
        id = i;
        month = m;
      },
    );
    await tester.tap(inRecap(find.textContaining('Transport')));
    expect(id, 'transport');
    expect(month, lastMonth);
  });

  testWidgets('the month leads: selector, then the month card, balances '
      'lower down', (tester) async {
    await pump(tester, day: 3);
    double top(Finder f) => tester.getTopLeft(f).dy;
    final selector = find.byTooltip('Previous month');
    final card = find.byType(MonthlyRecapCard);
    expect(top(selector), lessThan(top(card)));
    final balance = find.byKey(const ValueKey('balance'));
    await tester.scrollUntilVisible(
      balance,
      300,
      scrollable: verticalScrollable(),
    );
    expect(top(balance), greaterThan(top(card)));
  });
}
