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

/// The month cards: last month's recap on the Month view for the first
/// week, this month's pace on Trends after, and where the views put them.
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

  /// Pumps the dashboard as if today were day [day] of this month, on
  /// [view].
  Future<void> pump(
    WidgetTester tester, {
    required int day,
    String view = 'Month',
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
    if (view != 'Today') await openDashboardView(tester, view);
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

    // Under another month's totals it would read as that month's: browsing
    // back puts it away, coming back brings it back.
    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();
    expect(find.byType(MonthlyRecapCard), findsNothing);
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
    expect(find.byType(MonthlyRecapCard), findsOneWidget);

    // Year view drops it with the other monthly sections.
    await tester.tap(find.text('Year'));
    await tester.pumpAndSettle();
    expect(find.byType(MonthlyRecapCard), findsNothing);
  });

  testWidgets('no recap without last month data', (tester) async {
    await pump(tester, day: 3, lastMonthData: false);
    expect(find.byType(MonthlyRecapCard), findsNothing);
  });

  testWidgets('the recap week keeps the pace off Trends', (tester) async {
    await pump(tester, day: 3, view: 'Trends');
    expect(find.byType(MonthPaceCard), findsNothing);
    expect(find.byType(MonthlyRecapCard), findsNothing);
  });

  testWidgets('after the first week, Trends leads with this month so far', (
    tester,
  ) async {
    await pump(tester, day: 20, view: 'Trends');
    expect(find.byType(MonthlyRecapCard), findsNothing);
    final pace = find.byType(MonthPaceCard);
    expect(pace, findsOneWidget);
    Finder inPace(Finder f) => find.descendant(of: pace, matching: f);
    expect(inPace(find.text('$thisName so far')), findsOneWidget);
    expect(inPace(find.textContaining('1 to 20')), findsOneWidget);
    expect(inPace(find.text(fmtMoney(250))), findsOneWidget);
    expect(inPace(find.text(fmtMoney(400))), findsOneWidget);
    // First on the page, above last month's comparison.
    expect(
      tester.getTopLeft(pace).dy,
      lessThan(tester.getTopLeft(find.text('This month vs last month')).dy),
    );

    // It is about today's month: browsing back puts it away, and coming
    // back brings it back.
    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();
    expect(find.byType(MonthPaceCard), findsNothing);
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
    expect(find.byType(MonthPaceCard), findsOneWidget);

    await tester.tap(find.text('Year'));
    await tester.pumpAndSettle();
    expect(find.byType(MonthPaceCard), findsNothing, reason: 'Year view');
  });

  testWidgets('the Month view has no pace card', (tester) async {
    await pump(tester, day: 20);
    expect(find.byType(MonthPaceCard), findsNothing);
    expect(find.byType(MonthlyRecapCard), findsNothing);
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
    await openDashboardView(tester, 'Month');
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

  testWidgets('Today leads with the balance; the recap sits on Month under '
      'the selector', (tester) async {
    await pump(tester, day: 3, view: 'Today');
    double top(Finder f) => tester.getTopLeft(f).dy;
    final balance = find.byKey(const ValueKey('balance'));
    expect(balance, findsOneWidget);
    expect(find.byType(MonthlyRecapCard), findsNothing);
    expect(find.byTooltip('Previous month'), findsNothing);

    await openDashboardView(tester, 'Month');
    expect(balance, findsNothing);
    final selector = find.byTooltip('Previous month');
    expect(top(selector), lessThan(top(find.byType(MonthlyRecapCard))));
  });
}
