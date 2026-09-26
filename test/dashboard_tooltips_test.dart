import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/services/monthly_recap.dart';
import 'package:expense_tracker/services/spend_comparison.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/budget_detail_sheet.dart';
import 'package:expense_tracker/widgets/monthly_bar_chart.dart';
import 'package:expense_tracker/widgets/spend_comparison_cards.dart';

import 'dashboard_test_utils.dart';

/// The dashboard and accounts "i" tips: each opens its explanation with the
/// user's own figures, and a tip inside a tappable card does not fire the
/// card.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Past the recap week, whatever today is: the recap card repeats the
    // "Spent" label these tests tap.
    final now = DateTime.now();
    recapClock = () => DateTime(now.year, now.month, 20, 10);
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  tearDown(() => recapClock = DateTime.now);

  Future<void> pumpDashboard(
    WidgetTester tester,
    FinanceProvider p, {
    void Function(TxType, DateTime)? onViewTransactions,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: DashboardScreen(onViewTransactions: onViewTransactions),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openTip(WidgetTester tester, String title) async {
    final tip = find.bySemanticsLabel('About $title');
    await tester.scrollUntilVisible(tip, 200, scrollable: verticalScrollable());
    await tester.pumpAndSettle();
    await tester.tap(tip);
    await tester.pumpAndSettle();
  }

  group('dashboard', () {
    testWidgets('Net balance works the bank-minus-card sum', (tester) async {
      final p = FinanceProvider();
      await p.load();
      final bank = await p.addAccount(name: 'Bank', type: AccountType.bank);
      await p.setManualBalance(bank, 50000);
      final card = await p.addAccount(
        name: 'Card',
        type: AccountType.creditCard,
      );
      await p.setManualBalance(card, 12000);
      await pumpDashboard(tester, p);

      await openTip(tester, 'Net balance');
      expect(
        find.textContaining('Savings and closed accounts'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Now: ${fmtMoney(50000)} in banks − ${fmtMoney(12000)} on cards '
          '= ${fmtMoney(38000)}',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Balance breakdown'),
        findsNothing,
        reason: 'the tip must not open the card behind it',
      );
    });

    testWidgets('Available balance works the ledger sum', (tester) async {
      final p = FinanceProvider();
      await p.load();
      final now = DateTime.now();
      await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 10000,
        note: 'pay',
        date: DateTime(now.year, now.month, 1),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 2500,
        note: 'food',
        date: DateTime(now.year, now.month, 1),
      );
      await pumpDashboard(tester, p);

      await openTip(tester, 'Available balance');
      expect(
        find.text(
          '${fmtMoney(10000)} in − ${fmtMoney(2500)} out = ${fmtMoney(7500)}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a stat card tip does not open its transactions', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      final now = DateTime.now();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 900,
        note: 'lunch',
        date: DateTime(now.year, now.month, 1),
      );
      final opened = <TxType>[];
      await pumpDashboard(
        tester,
        p,
        onViewTransactions: (t, _) => opened.add(t),
      );
      await openDashboardView(tester, 'Month');

      await openTip(tester, 'Spent');
      expect(find.textContaining('a split bill counts only'), findsOneWidget);
      expect(opened, isEmpty);

      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spent'));
      await tester.pumpAndSettle();
      expect(opened, [TxType.expense], reason: 'the card itself still taps');
    });

    testWidgets('Recent transactions heading explains itself', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 900,
        note: 'lunch',
        date: DateTime.now(),
      );
      await pumpDashboard(tester, p);

      await openTip(tester, 'Recent transactions');
      expect(
        find.text('Your 5 newest confirmed transactions.'),
        findsOneWidget,
      );
    });

    testWidgets('the six-month chart ends at the selected month', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      final now = DateTime.now();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 900,
        note: 'lunch',
        date: DateTime(now.year, now.month, 1),
      );
      await pumpDashboard(tester, p);
      await openDashboardView(tester, 'Trends');

      MonthlyBarChart chart() =>
          tester.widget<MonthlyBarChart>(find.byType(MonthlyBarChart));
      await tester.scrollUntilVisible(
        find.byType(MonthlyBarChart),
        300,
        scrollable: verticalScrollable(),
      );
      expect(chart().shownMonths.last, DateTime(now.year, now.month));

      await tester.scrollUntilVisible(
        find.byTooltip('Previous month'),
        -300,
        scrollable: verticalScrollable(),
      );
      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(MonthlyBarChart),
        300,
        scrollable: verticalScrollable(),
      );
      expect(chart().shownMonths, hasLength(6));
      expect(chart().shownMonths.last, DateTime(now.year, now.month - 1));
    });
  });

  group('comparison cards', () {
    MonthComparison made({
      required SpendCompare previous,
      List<CategoryCompare> categories = const [],
      int usualMonths = 6,
    }) => MonthComparison(
      month: DateTime(2026, 9),
      previousMonth: DateTime(2026, 8),
      throughDay: 12,
      partial: true,
      usualMonths: usualMonths,
      paceDays: 12,
      vsPrevious: previous,
      vsUsual: previous,
      categories: categories,
    );

    Future<void> show(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

    Future<void> tapTip(WidgetTester tester, String title) async {
      await tester.tap(find.bySemanticsLabel('About $title'));
      await tester.pumpAndSettle();
    }

    testWidgets('the projection is worked with its real inputs', (
      tester,
    ) async {
      await show(
        tester,
        PreviousMonthCard(
          comparison: made(
            previous: const SpendCompare(
              actual: 30000,
              reference: 25000,
              actualFull: 48000,
              referenceFull: 40000,
              state: CompareState.ok,
            ),
          ),
        ),
      );
      await tapTip(tester, 'This month vs last month');
      expect(
        find.text(
          '${fmtMoney(30000)} so far × (${fmtMoney(40000)} ÷ '
          '${fmtMoney(25000)}) = ${fmtMoney(48000)} projected',
        ),
        findsOneWidget,
      );
    });

    test('with nothing last month the example shows the flat pace', () {
      final line = projectionExample(
        made(
          previous: const SpendCompare(
            actual: 12000,
            reference: 0,
            actualFull: 30000,
            referenceFull: 0,
            state: CompareState.newThisMonth,
          ),
        ),
      );
      expect(
        line,
        '${fmtMoney(12000)} so far × (30 days ÷ 12 days on record) = '
        '${fmtMoney(30000)} projected',
      );
    });

    test('no projection, no example', () {
      expect(
        projectionExample(
          made(
            previous: const SpendCompare(
              actual: 500,
              reference: 400,
              actualFull: null,
              referenceFull: 900,
              state: CompareState.ok,
            ),
          ),
        ),
        isNull,
      );
    });

    testWidgets('categories vs usual works the top row', (tester) async {
      await show(
        tester,
        CategoryComparisonCard(
          comparison: made(
            previous: const SpendCompare(
              actual: 8400,
              reference: 6900,
              actualFull: null,
              referenceFull: 6900,
              state: CompareState.ok,
            ),
            categories: [
              CategoryCompare(
                category: categoryById('food'),
                actual: 8400,
                usual: 6900,
                state: CompareState.ok,
              ),
            ],
          ),
        ),
      );
      await tapTip(tester, 'Categories vs usual');
      expect(
        find.text(
          '${categoryById('food').label}: ${fmtMoney(8400)} this month vs '
          '${fmtMoney(6900)} usual = +${fmtMoney(1500)}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('categories vs usual with no history shows the shortfall', (
      tester,
    ) async {
      await show(
        tester,
        CategoryComparisonCard(
          comparison: made(
            usualMonths: 1,
            previous: const SpendCompare(
              actual: 800,
              reference: 0,
              actualFull: null,
              referenceFull: 0,
              state: CompareState.newThisMonth,
            ),
            categories: [
              CategoryCompare(
                category: categoryById('food'),
                actual: 800,
                usual: 0,
                state: CompareState.newThisMonth,
              ),
            ],
          ),
        ),
      );
      expect(find.text(usualShortfallNote(1)), findsOneWidget);
      expect(find.text('New this month'), findsNothing);
      expect(find.text(categoryById('food').label), findsNothing);
    });
  });

  group('accounts', () {
    Future<void> pumpAccounts(WidgetTester tester, FinanceProvider p) async {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(body: AccountsScreen(onViewAccount: (_) {})),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the net header counts and works bank and card accounts', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      final bank = await p.addAccount(name: 'Bank', type: AccountType.bank);
      await p.setManualBalance(bank, 50000);
      final card = await p.addAccount(
        name: 'Card',
        type: AccountType.creditCard,
      );
      await p.setManualBalance(card, 12000);
      await p.addAccount(name: 'RD', type: AccountType.savings);
      await pumpAccounts(tester, p);

      expect(
        find.text('Net across 2 bank and card accounts · tap for breakdown'),
        findsOneWidget,
        reason: 'the savings account is not part of the net figure',
      );
      await tester.tap(find.bySemanticsLabel('About Net balance'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          '${fmtMoney(50000)} in banks − ${fmtMoney(12000)} on cards = '
          '${fmtMoney(38000)}',
        ),
        findsOneWidget,
      );
      expect(find.text('Balance breakdown'), findsNothing);
    });

    testWidgets('every bank tile explains its balance and links to its own '
        'balance dialog', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.addAccount(name: 'Bank A', type: AccountType.bank);
      await p.addAccount(name: 'Bank B', type: AccountType.bank);
      await pumpAccounts(tester, p);
      final tips = find.bySemanticsLabel('About Balance');
      expect(tips, findsNWidgets(2));

      await tester.tap(tips.last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set the balance →'));
      await tester.pumpAndSettle();
      expect(find.text('Set balance'), findsOneWidget);
    });

    testWidgets('a card with an unknown outstanding says dues unknown', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      final card = await p.addAccount(
        name: 'Card',
        type: AccountType.creditCard,
      );
      await p.setCardCycle(card, dueDay: 5);
      await pumpAccounts(tester, p);
      expect(p.accountOutstanding(p.accountById(card)!), isNull);
      expect(find.text('Dues unknown'), findsOneWidget);
      expect(find.text('No dues'), findsNothing);
    });
  });

  group('budget sheet', () {
    testWidgets('steps into a month with data ahead and draws the limit', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      final now = DateTime.now();
      final thisMonth = DateTime(now.year, now.month);
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'entertainment',
        amount: 300,
        note: 'this month',
        date: DateTime(now.year, now.month, 1),
      );
      // A row re-dated into next month, the case the dashboard arrow
      // already reaches.
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'entertainment',
        amount: 200,
        note: 'next month',
        date: DateTime(now.year, now.month + 1, 1),
      );
      const budget = SpendBudget(
        id: 'b1',
        name: 'Fun money',
        limit: 1000,
        mode: BudgetMode.include,
        categoryIds: {'entertainment'},
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () =>
                        showBudgetDetailSheet(context, budget, thisMonth),
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

      expect(find.byKey(const ValueKey('budget-limit-line')), findsOneWidget);
      await tester.tap(find.byTooltip('Next month'));
      await tester.pumpAndSettle();
      expect(
        find.text(fmtMonth(DateTime(now.year, now.month + 1))),
        findsOneWidget,
      );
    });
  });
}
