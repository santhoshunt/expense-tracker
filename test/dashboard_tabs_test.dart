import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/services/spend_comparison.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/category_donut_chart.dart';
import 'package:expense_tracker/widgets/spend_comparison_cards.dart';

import 'dashboard_test_utils.dart';

/// The dashboard's three sub-tabs, and the comparison cards' states.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  group('sub-tabs', () {
    Future<void> pump(WidgetTester tester) async {
      final p = FinanceProvider();
      await p.load();
      final now = DateTime.now();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 900,
        note: 'this month',
        date: DateTime(now.year, now.month, 1),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'transport',
        amount: 400,
        note: 'last month',
        date: DateTime(now.year, now.month - 1, 2),
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: p),
            ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
          ],
          child: const MaterialApp(home: Scaffold(body: DashboardScreen())),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('each view shows its own sections and no others', (
      tester,
    ) async {
      await pump(tester);
      final list = verticalScrollable();

      // Overview is the landing view. It carries copies of the
      // highest-signal sections (categories vs usual, the heatmap) so a
      // glance there needs no tab switch — but not the rest.
      expect(find.text('Spent'), findsOneWidget);
      expect(find.text('This month vs last month'), findsNothing);
      expect(find.byType(CategoryDonutChart), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Categories vs usual'),
        300,
        scrollable: list,
      );
      expect(find.text('Categories vs usual'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Spending heatmap'),
        300,
        scrollable: list,
      );
      expect(find.text('Spending heatmap'), findsOneWidget);

      await openDashboardView(tester, 'Trends');
      expect(find.text('This month vs last month'), findsOneWidget);
      expect(find.text('This month vs usual'), findsOneWidget);
      expect(find.text('Spent'), findsNothing);
      expect(find.byType(CategoryDonutChart), findsNothing);

      await openDashboardView(tester, 'Breakdown');
      expect(find.byType(CategoryDonutChart), findsOneWidget);
      expect(find.text('This month vs last month'), findsNothing);
      expect(find.text('Spent'), findsNothing);
    });

    testWidgets('a horizontal swipe steps through the views', (tester) async {
      await pump(tester);
      expect(find.text('Spent'), findsOneWidget);

      // Fling on page content — the month selector row, present on every
      // view. The tab labels sit on the pinned bar outside the pager now,
      // and its buttons claim only taps, so the drag reaches the PageView.
      Future<void> swipe(double dx) async {
        await tester.fling(
          find.byTooltip('Previous month'),
          Offset(dx, 0),
          1000,
        );
        await tester.pumpAndSettle();
      }

      await swipe(-300);
      expect(find.text('This month vs last month'), findsOneWidget);

      await swipe(-300);
      expect(find.byType(CategoryDonutChart), findsOneWidget);

      // The ends stop: another swipe left stays on Breakdown.
      await swipe(-300);
      expect(find.byType(CategoryDonutChart), findsOneWidget);

      // And right goes back.
      await swipe(300);
      expect(find.text('This month vs last month'), findsOneWidget);
    });

    testWidgets('the month selector follows every view', (tester) async {
      await pump(tester);
      for (final view in ['Trends', 'Breakdown', 'Overview']) {
        await tester.tap(find.text(view));
        await tester.pumpAndSettle();
        expect(
          find.byTooltip('Previous month'),
          findsOneWidget,
          reason: '$view is month-scoped too',
        );
      }
    });

    testWidgets('the year view stands the comparisons down', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Trends'));
      await tester.pumpAndSettle();
      expect(find.text('This month vs last month'), findsOneWidget);

      await tester.tap(find.text('Year'));
      await tester.pumpAndSettle();
      expect(
        find.text('This month vs last month'),
        findsNothing,
        reason: 'a month comparison has no meaning over a year',
      );
    });
  });

  group('comparison cards', () {
    SpendCompare compare(
      double actual,
      double reference, {
      CompareState state = CompareState.ok,
    }) => SpendCompare(
      actual: actual,
      reference: reference,
      actualFull: null,
      referenceFull: reference,
      state: state,
    );

    MonthComparison made({
      List<CategoryCompare> categories = const [],
      int usualMonths = 6,
      CompareState usualState = CompareState.ok,
    }) => MonthComparison(
      month: DateTime(2026, 9),
      previousMonth: DateTime(2026, 8),
      throughDay: 17,
      partial: true,
      usualMonths: usualMonths,
      paceDays: 17,
      vsPrevious: compare(1400, 1000),
      vsUsual: compare(1400, 1000, state: usualState),
      categories: categories,
    );

    Future<void> show(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

    testWidgets('too little history explains itself instead of guessing', (
      tester,
    ) async {
      await show(
        tester,
        UsualSpendCard(
          comparison: made(
            usualMonths: 1,
            usualState: CompareState.notEnoughHistory,
          ),
        ),
      );
      expect(find.textContaining('complete months'), findsOneWidget);
      expect(find.textContaining('is 1 month'), findsOneWidget);
    });

    testWidgets('a running month names the day it is measured through', (
      tester,
    ) async {
      await show(tester, PreviousMonthCard(comparison: made()));
      expect(find.textContaining('Through 17 Sep'), findsOneWidget);
      expect(find.textContaining('August'), findsWidgets);
    });

    testWidgets('too few days for a projection still names the full month', (
      tester,
    ) async {
      // made() carries a null actualFull, the shape of a month's first days
      // (before kMinDaysForProjection). "Show both" still holds: the full
      // reference month is named even though nothing can be projected yet.
      await show(tester, PreviousMonthCard(comparison: made()));
      expect(find.text('All of August: ${fmtMoney(1000)}'), findsOneWidget);
      expect(find.textContaining('On track for'), findsNothing);

      await show(tester, UsualSpendCard(comparison: made()));
      expect(
        find.text('Usually ${fmtMoney(1000)} in a full month'),
        findsOneWidget,
      );
    });

    testWidgets('a row with nothing spent this month is not tappable', (
      tester,
    ) async {
      final tapped = <String>[];
      await show(
        tester,
        CategoryComparisonCard(
          onViewCategory: tapped.add,
          comparison: made(
            categories: [
              CategoryCompare(
                category: categoryById('food'),
                actual: 1400,
                usual: 1000,
                state: CompareState.ok,
              ),
              CategoryCompare(
                category: categoryById('transport'),
                actual: 0,
                usual: 300,
                state: CompareState.noneThisMonth,
              ),
            ],
          ),
        ),
      );

      expect(find.textContaining('Nothing yet, usually'), findsOneWidget);

      await tester.tap(find.text(categoryById('transport').label));
      await tester.pump();
      expect(tapped, isEmpty, reason: 'the deep link would open an empty list');

      await tester.tap(find.text(categoryById('food').label));
      await tester.pump();
      expect(tapped, ['food']);
    });

    testWidgets('the sort menu reorders the rows', (tester) async {
      final cats = [
        CategoryCompare(
          category: categoryById('food'),
          actual: 1400,
          usual: 1000,
          state: CompareState.ok,
        ),
        CategoryCompare(
          category: categoryById('transport'),
          actual: 300,
          usual: 100,
          state: CompareState.ok,
        ),
        CategoryCompare(
          category: categoryById('shopping'),
          actual: 50,
          usual: 0,
          state: CompareState.newThisMonth,
        ),
      ];
      await show(
        tester,
        CategoryComparisonCard(comparison: made(categories: cats)),
      );

      double rowY(String id) =>
          tester.getTopLeft(find.text(categoryById(id).label)).dy;

      // Default: the order handed in (biggest absolute change first).
      expect(rowY('food'), lessThan(rowY('transport')));

      await tester.tap(find.byIcon(Icons.sort));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Most unusual'));
      await tester.pumpAndSettle();
      // No usual to divide by pins shopping first; then transport's +200%
      // outranks food's +40% despite the smaller rupee change.
      expect(rowY('shopping'), lessThan(rowY('transport')));
      expect(rowY('transport'), lessThan(rowY('food')));

      await tester.tap(find.byIcon(Icons.sort));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Highest spend'));
      await tester.pumpAndSettle();
      expect(rowY('food'), lessThan(rowY('transport')));
      expect(rowY('transport'), lessThan(rowY('shopping')));
    });

    testWidgets('a long list collapses to the top movers', (tester) async {
      final ids = [
        'food',
        'transport',
        'shopping',
        'bills',
        'health',
        'entertainment',
        'groceries',
      ];
      await show(
        tester,
        CategoryComparisonCard(
          comparison: made(
            categories: [
              for (final (i, id) in ids.indexed)
                CategoryCompare(
                  category: categoryById(id),
                  actual: 1000.0 - i * 10,
                  usual: 500,
                  state: CompareState.ok,
                ),
            ],
          ),
        ),
      );
      expect(find.text('Show all ${ids.length} categories'), findsOneWidget);
    });
  });
}
