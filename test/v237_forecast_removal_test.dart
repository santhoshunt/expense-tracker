import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/dashboard_layout.dart';
import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/services/comparison_series.dart';
import 'package:expense_tracker/services/forward_series.dart';
import 'package:expense_tracker/services/spend_comparison.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/monthly_recap_card.dart';
import 'package:expense_tracker/widgets/spend_comparison_cards.dart';

import 'dashboard_test_utils.dart';

/// v2.3.7: no guessed figures. The Overview's Month-end forecast, the
/// everyday spending the Ahead balance subtracted, and the Trends
/// predictions (On track for, At least, the chart's dashed line) are gone.
/// Every name and amount here is made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<void> spend(
    FinanceProvider p,
    DateTime date,
    double amount, {
    String category = 'food',
  }) => p.addTransaction(
    type: TxType.expense,
    categoryId: category,
    amount: amount,
    note: 'test',
    date: date,
  );

  Future<void> pumpDashboard(
    WidgetTester tester,
    FinanceProvider p,
    SettingsProvider s,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
  }

  /// Three past months of everyday food spending and some this month,
  /// dated relative to the real clock and never in the future: the history
  /// the old everyday estimate was built from.
  Future<FinanceProvider> everydayLedger(DateTime now) async {
    final p = FinanceProvider();
    await p.load();
    for (var k = 3; k >= 1; k--) {
      for (final day in [2, 9, 16, 23]) {
        await spend(p, DateTime(now.year, now.month - k, day), 650);
      }
    }
    await spend(p, DateTime(now.year, now.month, 1), 900);
    return p;
  }

  group('Overview', () {
    testWidgets('the Monthly budget card ends at its verdict', (tester) async {
      final now = DateTime.now();
      final p = await everydayLedger(now);
      final s = SettingsProvider();
      await s.load();
      await s.setMonthlyBudget(500);
      await pumpDashboard(tester, p, s);

      expect(find.text('Monthly budget'), findsOneWidget);
      expect(find.textContaining(' over the cap'), findsOneWidget);
      // No "About ₹X by 30 Nov" or "At least ₹X by 30 Nov" headline.
      final monthEnd = fmtDateCompact(DateTime(now.year, now.month + 1, 0));
      expect(find.textContaining('by $monthEnd'), findsNothing);
      expect(find.text('Everyday spending'), findsNothing);
      expect(find.text('Month-end forecast'), findsNothing);
      expect(
        find.byKey(const ValueKey('presence-month-forecast')),
        findsNothing,
      );
    });

    testWidgets('no Month-end forecast without a cap', (tester) async {
      final p = await everydayLedger(DateTime.now());
      final s = SettingsProvider();
      await s.load();
      await pumpDashboard(tester, p, s);

      expect(find.text('Month-end forecast'), findsNothing);
      expect(find.text('Monthly budget'), findsNothing);
      expect(find.textContaining('Spent so far, with'), findsNothing);
    });
  });

  group('stored layouts naming the removed forecast', () {
    const stored = {
      'pages': {
        'overview': {
          'order': ['monthlyBudget', 'forecast', 'recap', 'week'],
          'hidden': ['forecast', 'budgets'],
        },
      },
      'open': {'forecast': true, 'usual': true},
    };

    test('the page layout drops it quietly', () {
      final l = DashboardPageLayout.fromJson(
        DashboardPage.overview,
        (stored['pages'] as Map)['overview'],
      );
      // Budgets and Who owes you, missing from the stored order, go back
      // after their default neighbours.
      expect(l.order, [
        DashboardSection.monthlyBudget,
        DashboardSection.recap,
        DashboardSection.budgets,
        DashboardSection.owed,
        DashboardSection.week,
      ]);
      expect(l.hidden, {DashboardSection.budgets});
    });

    test('preferences load it', () async {
      SharedPreferences.setMockInitialValues({
        'dashboard_layout_v1': jsonEncode(stored),
      });
      final s = SettingsProvider();
      await s.load();
      final l = s.dashboardLayout(DashboardPage.overview);
      expect(l.order.first, DashboardSection.monthlyBudget);
      expect(l.hidden, {DashboardSection.budgets});
      expect(s.sectionOpen(DashboardSection.usual), isTrue);
      expect(s.dashboardLayoutKey, isNot(contains('forecast')));
    });

    test('an older backup restores it', () async {
      final s = SettingsProvider();
      await s.load();
      await s.applyBackupMap({'dashboardLayout': stored});
      final l = s.dashboardLayout(DashboardPage.overview);
      expect(l.order, contains(DashboardSection.recap));
      expect(l.hidden, {DashboardSection.budgets});
      expect(s.dashboardLayoutKey, isNot(contains('forecast')));
    });
  });

  group('Ahead', () {
    test('a day with no known items keeps the day before it', () async {
      final now = DateTime(2026, 10, 20, 10);
      final p = FinanceProvider();
      await p.load();
      // July till September: steady everyday spending, the history the old
      // everyday estimate took off every day ahead.
      for (final m in [7, 8, 9]) {
        for (final day in [2, 9, 16, 23, 30]) {
          await spend(p, DateTime(2026, m, day, 12), 520);
        }
      }
      await spend(p, DateTime(2026, 10, 3, 12), 700);
      // One known bill ahead: rent on the 28th.
      await p.restoreReminder(
        const Reminder(
          id: 'rent',
          name: 'Test rent',
          dayOfMonth: 28,
          categoryId: 'other_expense',
          expectedAmount: 9000,
          lastPaidMonth: '2026-09',
        ),
      );
      for (final m in [7, 8, 9]) {
        expect(p.expenseInMonth(DateTime(2026, m)), greaterThan(0));
      }

      final ahead = aheadSeries(
        p,
        patterns: const [],
        hidden: const {},
        now: now,
      );
      final days = ahead.series.days;
      expect(days, hasLength(31));
      for (var i = 1; i < days.length; i++) {
        final day = days[i];
        final step = day.balance - days[i - 1].balance;
        if (day.items.isEmpty) {
          expect(step, 0, reason: 'no everyday drop on ${day.date}');
        } else {
          expect(day.date, DateTime(2026, 10, 28));
          expect(step, -9000);
        }
      }
      expect(days.first.balance, ahead.headline - ahead.waiting);
    });

    testWidgets('the Ahead view names what moves the balance', (tester) async {
      final p = await everydayLedger(DateTime.now());
      final s = SettingsProvider();
      await s.load();
      await pumpDashboard(tester, p, s);
      await openDashboardView(tester, 'Ahead');

      expect(
        find.text(
          'Only the bills, subscriptions, savings and income the app knows '
          'about move this balance.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('everyday'), findsNothing);
    });
  });

  group('Trends', () {
    // 17 September: July and August on record from the 1st.
    final now = DateTime(2026, 9, 17, 10);

    Future<MonthComparison> running() async {
      final p = FinanceProvider();
      await p.load();
      for (final m in [6, 7, 8]) {
        await spend(p, DateTime(2026, m, 1), 1000);
        await spend(p, DateTime(2026, m, 25), 500);
      }
      await spend(p, DateTime(2026, 9, 5), 1400);
      return buildMonthComparison(p, DateTime(2026, 9), now: now);
    }

    Future<void> show(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

    testWidgets('This month vs last month shows all of last month', (
      tester,
    ) async {
      final c = await running();
      expect(c.partial, isTrue);
      await show(tester, MonthPaceCard(comparison: c));
      expect(find.textContaining('On track for'), findsNothing);
      expect(find.textContaining('At least'), findsNothing);
      expect(find.textContaining('by month end'), findsNothing);
      expect(
        find.text('All of August: ${fmtMoneyWhole(1500)}'),
        findsOneWidget,
      );
    });

    testWidgets('This month vs usual shows a usual full month', (tester) async {
      final c = await running();
      await show(tester, UsualSpendCard(comparison: c));
      expect(find.textContaining('On track for'), findsNothing);
      expect(find.textContaining('At least'), findsNothing);
      expect(
        find.text('Usually ${fmtMoneyWhole(1500)} in a full month'),
        findsOneWidget,
      );
    });

    test('the chart has no points after today', () async {
      final p = FinanceProvider();
      await p.load();
      await spend(p, DateTime(2026, 8, 3), 800);
      await spend(p, DateTime(2026, 9, 5), 1400);
      final s = buildComparisonSeries(
        p,
        DateTime(2026, 9),
        now: now,
        lastMonthOnRecord: true,
      );
      expect(s.running, isTrue);
      expect(s.today, 17);
      expect(s.actual, hasLength(17));
      expect(s.actual.last, 1400);
    });
  });
}
