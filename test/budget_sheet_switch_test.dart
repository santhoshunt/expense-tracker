import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/budget_detail_sheet.dart';
import 'package:expense_tracker/widgets/category_donut_chart.dart';

/// The budget sheet in v1.39: arrows and a swipe step through the budgets,
/// the chart is a fixed 6-month window that pages, the legend is capped at
/// 5 plus Other, and the sheet holds one height while months change.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  group('chart window', () {
    final latest = DateTime(2026, 10);

    test('opens ending on the latest month when the shown one is in it', () {
      expect(initialBudgetWindowEnd(DateTime(2026, 10), latest), latest);
      expect(initialBudgetWindowEnd(DateTime(2026, 5), latest), latest);
    });

    test('opens ending on the shown month when it is older', () {
      expect(
        initialBudgetWindowEnd(DateTime(2026, 4), latest),
        DateTime(2026, 4),
      );
      expect(
        initialBudgetWindowEnd(DateTime(2025, 1), latest),
        DateTime(2025, 1),
      );
    });

    test('holds still while the shown month stays inside', () {
      for (var m = 5; m <= 10; m++) {
        expect(
          pageBudgetWindow(
            windowEnd: latest,
            shown: DateTime(2026, m),
            latest: latest,
          ),
          latest,
        );
      }
    });

    test('stepping before the first month pages back six', () {
      expect(
        pageBudgetWindow(
          windowEnd: latest,
          shown: DateTime(2026, 4),
          latest: latest,
        ),
        DateTime(2026, 4),
      );
      // Across a year boundary.
      expect(
        pageBudgetWindow(
          windowEnd: DateTime(2026, 4),
          shown: DateTime(2025, 10),
          latest: latest,
        ),
        DateTime(2025, 10),
      );
    });

    test('stepping past the last month pages forward six', () {
      expect(
        pageBudgetWindow(
          windowEnd: DateTime(2025, 10),
          shown: DateTime(2025, 11),
          latest: latest,
        ),
        DateTime(2026, 4),
      );
    });

    test('a forward page stops at the latest month', () {
      expect(
        pageBudgetWindow(
          windowEnd: DateTime(2026, 4),
          shown: DateTime(2026, 5),
          latest: latest,
        ),
        latest,
      );
      expect(
        pageBudgetWindow(
          windowEnd: DateTime(2026, 8),
          shown: DateTime(2026, 9),
          latest: latest,
        ),
        latest,
      );
    });

    test('a month past the latest ends the window on itself', () {
      expect(
        pageBudgetWindow(
          windowEnd: latest,
          shown: DateTime(2026, 12),
          latest: latest,
        ),
        DateTime(2026, 12),
      );
    });
  });

  group('sheet', () {
    final now = DateTime.now();
    final thisMonth = DateTime(now.year, now.month);
    DateTime monthsAgo(int n) => DateTime(now.year, now.month - n);
    final content = find.byKey(const ValueKey('budget-sheet-content'));
    final donut = find.byKey(const ValueKey('budget-donut'));

    Future<void> spend(
      FinanceProvider p,
      String categoryId,
      double amount,
      DateTime month,
    ) => p.addTransaction(
      type: TxType.expense,
      categoryId: categoryId,
      amount: amount,
      note: '$categoryId ${month.month}',
      date: DateTime(month.year, month.month, 1),
    );

    Future<void> pumpSheet(
      WidgetTester tester,
      FinanceProvider p,
      SpendBudget budget,
      DateTime month, {
      void Function(String budgetId, DateTime month)? onViewTransactions,
    }) async {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => showBudgetDetailSheet(
                      context,
                      budget,
                      month,
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

    IconButton button(WidgetTester tester, String tooltip) =>
        tester.widget<IconButton>(
          find
              .ancestor(
                of: find.byTooltip(tooltip),
                matching: find.byType(IconButton),
              )
              .first,
        );

    Future<FinanceProvider> threeBudgets() async {
      final p = FinanceProvider();
      await p.load();
      // Records from months back, outside every budget: the previous-month
      // chevron stops at the ledger's first month.
      await spend(p, 'health', 50, monthsAgo(6));
      await spend(p, 'food', 400, monthsAgo(1));
      await spend(p, 'transport', 300, monthsAgo(1));
      // Fixed ids through a restore: addBudget mints ids from the clock,
      // and three calls inside one clock tick share one id.
      final data =
          jsonDecode(jsonEncode(p.exportData())) as Map<String, dynamic>;
      data['budgets'] = [
        for (final (i, name, id) in [
          (1, 'Eating out', 'food'),
          (2, 'Getting around', 'transport'),
          (3, 'Fun money', 'entertainment'),
        ])
          SpendBudget(
            id: 'b$i',
            name: name,
            limit: 1000,
            mode: BudgetMode.include,
            categoryIds: {id},
          ).toJson(),
      ];
      await p.importData(data, replace: true);
      expect(p.budgets.map((b) => b.id), ['b1', 'b2', 'b3']);
      return p;
    }

    testWidgets('budget arrows step in order and keep the month', (
      tester,
    ) async {
      final p = await threeBudgets();
      await pumpSheet(tester, p, p.budgets.first, monthsAgo(1));

      expect(find.text('Eating out'), findsOneWidget);
      expect(find.text('Budget 1 of 3'), findsOneWidget);
      expect(button(tester, 'Previous budget').onPressed, isNull);
      expect(
        find.text('${fmtMoneyWhole(400)} / ${fmtMoneyWhole(1000)}'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Next budget'));
      await tester.pumpAndSettle();
      expect(find.text('Getting around'), findsOneWidget);
      expect(find.text('Budget 2 of 3'), findsOneWidget);
      expect(find.text(fmtMonth(monthsAgo(1))), findsOneWidget);
      expect(
        find.text('${fmtMoneyWhole(300)} / ${fmtMoneyWhole(1000)}'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Next budget'));
      await tester.pumpAndSettle();
      expect(find.text('Fun money'), findsOneWidget);
      expect(find.text('Budget 3 of 3'), findsOneWidget);
      // No wrap-around.
      expect(button(tester, 'Next budget').onPressed, isNull);

      await tester.tap(find.byTooltip('Previous budget'));
      await tester.pumpAndSettle();
      expect(find.text('Getting around'), findsOneWidget);
      expect(find.text(fmtMonth(monthsAgo(1))), findsOneWidget);
    });

    testWidgets('one budget shows no arrows and no count', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.addBudget(
        name: 'Eating out',
        limit: 1000,
        mode: BudgetMode.include,
        categoryIds: {'food'},
      );
      await pumpSheet(tester, p, p.budgets.single, thisMonth);
      expect(find.byTooltip('Previous budget'), findsNothing);
      expect(find.byTooltip('Next budget'), findsNothing);
      expect(find.textContaining('Budget 1 of'), findsNothing);
    });

    testWidgets('a sideways fling switches budgets', (tester) async {
      final p = await threeBudgets();
      await pumpSheet(tester, p, p.budgets.first, monthsAgo(1));

      // From the header, which is always on screen.
      await tester.fling(
        find.text('Budget 1 of 3'),
        const Offset(-300, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.text('Budget 2 of 3'), findsOneWidget);
      expect(find.text(fmtMonth(monthsAgo(1))), findsOneWidget);

      await tester.fling(
        find.text('Budget 2 of 3'),
        const Offset(300, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.text('Budget 1 of 3'), findsOneWidget);
    });

    testWidgets('a part drag of the sheet keeps the budget and month', (
      tester,
    ) async {
      // The sheet rebuilds its builder on a drag; the shown budget and
      // month used to live inside it and went back to the opening ones.
      final p = await threeBudgets();
      await pumpSheet(tester, p, p.budgets.first, monthsAgo(1));
      await tester.tap(find.byTooltip('Next budget'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Previous month').last);
      await tester.pumpAndSettle();
      expect(find.text('Budget 2 of 3'), findsOneWidget);
      expect(find.text(fmtMonth(monthsAgo(2))), findsOneWidget);

      // Down a little by its handle and let go: the sheet springs back.
      await tester.dragFrom(
        tester.getTopLeft(find.byType(BottomSheet)) + const Offset(150, 12),
        const Offset(0, 40),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Budget 2 of 3'), findsOneWidget);
      expect(find.text(fmtMonth(monthsAgo(2))), findsOneWidget);
    });

    testWidgets('the sheet keeps its height while months step in the window', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      // This month one category, last month four, two months ago none.
      // The ledger starts before them, outside the budget.
      await spend(p, 'health', 50, monthsAgo(3));
      await spend(p, 'food', 100, thisMonth);
      await spend(p, 'food', 400, monthsAgo(1));
      await spend(p, 'transport', 300, monthsAgo(1));
      await spend(p, 'shopping', 200, monthsAgo(1));
      await spend(p, 'bills', 100, monthsAgo(1));
      await p.addBudget(
        name: 'Home and out',
        limit: 5000,
        mode: BudgetMode.include,
        categoryIds: {'food', 'transport', 'shopping', 'bills'},
      );
      await pumpSheet(tester, p, p.budgets.single, thisMonth);

      final heights = [tester.getSize(content).height];
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byTooltip('Previous month'));
        await tester.pumpAndSettle();
        heights.add(tester.getSize(content).height);
      }
      expect(find.text(fmtMonth(monthsAgo(2))), findsOneWidget);
      expect(heights.toSet(), hasLength(1), reason: '$heights');
    });

    testWidgets('the chart window pages and the shown month is bold', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      // A year of records, so the window can page back.
      await spend(p, 'health', 50, monthsAgo(12));
      await spend(p, 'food', 100, thisMonth);
      await p.addBudget(
        name: 'Eating out',
        limit: 1000,
        mode: BudgetMode.include,
        categoryIds: {'food'},
      );
      await pumpSheet(tester, p, p.budgets.single, thisMonth);
      final mmm = DateFormat('MMM');
      FontWeight? weight(DateTime m) =>
          tester.widget<Text>(find.text(mmm.format(m))).style?.fontWeight;

      expect(weight(thisMonth), FontWeight.w700);
      expect(weight(monthsAgo(1)), isNot(FontWeight.w700));

      // Five steps back stay in the window; it does not move.
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byTooltip('Previous month'));
        await tester.pumpAndSettle();
      }
      expect(find.text(mmm.format(thisMonth)), findsOneWidget);
      expect(weight(monthsAgo(5)), FontWeight.w700);
      expect(weight(thisMonth), isNot(FontWeight.w700));

      // The sixth pages back six months.
      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
      expect(find.text(mmm.format(thisMonth)), findsNothing);
      expect(find.text(mmm.format(monthsAgo(11))), findsOneWidget);
      expect(weight(monthsAgo(6)), FontWeight.w700);

      // Forward again pages back to the window ending this month.
      await tester.tap(find.byTooltip('Next month'));
      await tester.pumpAndSettle();
      expect(find.text(mmm.format(thisMonth)), findsOneWidget);
      expect(find.text(mmm.format(monthsAgo(11))), findsNothing);
    });

    testWidgets('the chart heading names all six months, and the months '
        'before the records show their names', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await spend(p, 'food', 100, monthsAgo(3));
      await spend(p, 'food', 100, thisMonth);
      await p.addBudget(
        name: 'Eating out',
        limit: 1000,
        mode: BudgetMode.include,
        categoryIds: {'food'},
      );
      await pumpSheet(tester, p, p.budgets.single, thisMonth);
      final mmm = DateFormat('MMM');
      expect(
        find.text(
          '6 months: ${mmm.format(monthsAgo(5))} to ${mmm.format(thisMonth)}',
        ),
        findsOneWidget,
      );
      // Five months back is before the records start: named, not blank.
      expect(find.text(mmm.format(monthsAgo(5))), findsOneWidget);
    });

    testWidgets('the legend caps at five plus Other, which opens the rows', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      final cats = [
        'food',
        'transport',
        'shopping',
        'bills',
        'health',
        'entertainment',
        'education',
      ];
      for (final (i, id) in cats.indexed) {
        await spend(p, id, 700.0 - i * 100, thisMonth);
      }
      await p.addBudget(
        name: 'Everything',
        limit: 9000,
        mode: BudgetMode.exclude,
        categoryIds: const {},
      );
      String? openedId;
      DateTime? openedMonth;
      await pumpSheet(
        tester,
        p,
        p.budgets.single,
        thisMonth,
        onViewTransactions: (id, m) {
          openedId = id;
          openedMonth = m;
        },
      );

      Finder inDonut(String text) =>
          find.descendant(of: donut, matching: find.text(text));
      expect(inDonut('Food & Dining'), findsOneWidget);
      expect(inDonut('Health'), findsOneWidget);
      expect(inDonut('Entertainment'), findsNothing);
      expect(inDonut('Education'), findsNothing);
      expect(inDonut('More categories'), findsOneWidget);

      await tester.ensureVisible(inDonut('More categories'));
      await tester.pumpAndSettle();
      await tester.tap(inDonut('More categories'));
      await tester.pumpAndSettle();
      expect(openedId, p.budgets.single.id);
      expect(openedMonth, thisMonth);
      expect(find.text('Where it went'), findsNothing, reason: 'sheet closed');
    });

    testWidgets('an empty month keeps a grey ring and says so', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await spend(p, 'food', 100, thisMonth);
      await p.addBudget(
        name: 'Eating out',
        limit: 1000,
        mode: BudgetMode.include,
        categoryIds: {'food'},
      );
      await pumpSheet(tester, p, p.budgets.single, monthsAgo(1));

      expect(find.text('Where it went'), findsOneWidget);
      expect(
        find.descendant(
          of: donut,
          matching: find.text(
            'Nothing counted toward this budget in '
            '${fmtMonth(monthsAgo(1))}.',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: donut, matching: find.byType(CustomPaint)),
        findsWidgets,
      );
      final chart = tester.widget<CategoryDonutChart>(donut);
      expect(chart.emptyRing, isTrue);
      expect(chart.data, isEmpty);
    });
  });
}
