import 'dart:math' as math;

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
import 'package:expense_tracker/widgets/monthly_bar_chart.dart';

/// Tapping a chart part highlights it and opens its figures in a popup.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  const food = TxCategory(
    id: 'food',
    label: 'Food',
    icon: Icons.restaurant,
    color: Colors.orange,
    type: TxType.expense,
  );
  const rent = TxCategory(
    id: 'rent',
    label: 'Rent',
    icon: Icons.home,
    color: Colors.teal,
    type: TxType.expense,
  );

  group('donut', () {
    String? tapped;

    Future<Rect> pumpDonut(WidgetTester tester) async {
      tapped = null;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: CategoryDonutChart(
                  data: const [MapEntry(food, 600), MapEntry(rent, 400)],
                  onCategoryTap: (id) => tapped = id,
                ),
              ),
            ),
          ),
        ),
      );
      return tester.getRect(
        find
            .descendant(
              of: find.byType(CategoryDonutChart),
              matching: find.byType(CustomPaint),
            )
            .first,
      );
    }

    /// A point on the ring, [turn] of the way round clockwise from the top.
    Offset onRing(Rect box, double turn) {
      final mid = math.min(box.width, box.height) / 2 - 8 - 13;
      final a = turn * 2 * math.pi - math.pi / 2;
      return box.center + Offset(math.cos(a), math.sin(a)) * mid;
    }

    testWidgets('a slice opens its amount and share, with the link', (
      tester,
    ) async {
      final box = await pumpDonut(tester);
      // Food is the first 60% of the ring, starting at the top.
      await tester.tapAt(onRing(box, 0.2));
      await tester.pumpAndSettle();

      expect(find.text('Food'), findsOneWidget, reason: 'popup title');
      expect(find.text(fmtMoney(600)), findsOneWidget);
      expect(find.text('60% of spending'), findsOneWidget);

      await tester.tap(find.text('See transactions →'));
      await tester.pumpAndSettle();
      expect(tapped, 'food');
      expect(find.text('60% of spending'), findsNothing);
    });

    testWidgets('the second slice answers too', (tester) async {
      final box = await pumpDonut(tester);
      await tester.tapAt(onRing(box, 0.8));
      await tester.pumpAndSettle();
      expect(find.text('Rent'), findsOneWidget);
      expect(find.text('40% of spending'), findsOneWidget);
    });

    testWidgets('the hole in the middle does nothing', (tester) async {
      final box = await pumpDonut(tester);
      await tester.tapAt(box.center);
      await tester.pumpAndSettle();
      expect(find.textContaining('% of spending'), findsNothing);
    });

    testWidgets('a new order morphs, then taps follow the new layout', (
      tester,
    ) async {
      final box = await pumpDonut(tester);
      // Rent overtakes Food: it now leads the ring.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: CategoryDonutChart(
                  data: const [MapEntry(rent, 700), MapEntry(food, 300)],
                  onCategoryTap: (id) => tapped = id,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      await tester.tapAt(onRing(box, 0.2));
      await tester.pumpAndSettle();
      expect(find.text('Rent'), findsOneWidget);
      expect(find.text('70% of spending'), findsOneWidget);
    });

    testWidgets('a year with no spending says so', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CategoryDonutChart(
              data: [],
              emptyText: 'No spending this year',
            ),
          ),
        ),
      );
      expect(find.text('No spending this year'), findsOneWidget);
    });
  });

  testWidgets('month bars mask income in the popup when it is hidden', (
    tester,
  ) async {
    final finance = FinanceProvider();
    await finance.load();
    final now = DateTime.now();
    await finance.addTransaction(
      type: TxType.income,
      categoryId: 'salary',
      amount: 50000,
      note: 'Salary',
      date: DateTime(now.year, now.month, 1),
    );
    await finance.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 900,
      note: 'lunch',
      date: DateTime(now.year, now.month, 1),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: finance,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                child: MonthlyBarChart(showIncome: false),
              ),
            ),
          ),
        ),
      ),
    );
    final box = tester.getRect(find.byType(MonthlyBarChart));
    // The sixth and last group is the current month.
    await tester.tapAt(Offset(box.left + box.width * 5.5 / 6, box.center.dy));
    await tester.pumpAndSettle();

    expect(
      find.text(DateFormat('MMMM yyyy').format(DateTime(now.year, now.month))),
      findsOneWidget,
    );
    expect(find.text(fmtMoney(900)), findsOneWidget);
    expect(find.text(kMaskedAmount), findsNWidgets(2), reason: 'income, net');
    expect(find.text(fmtMoney(50000)), findsNothing);
  });

  testWidgets('a budget bar shows its spend against the limit', (tester) async {
    final finance = FinanceProvider();
    await finance.load();
    final now = DateTime.now();
    final thisMonth = DateTime(now.year, now.month);
    await finance.addTransaction(
      type: TxType.expense,
      categoryId: 'entertainment',
      amount: 800,
      note: 'this month',
      date: DateTime(thisMonth.year, thisMonth.month, 1),
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
        value: finance,
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

    // The bars, not the (keyed) limit line drawn over them; the last is
    // this month.
    final bar = find
        .byWidgetPredicate(
          (w) => w is AnimatedFractionallySizedBox && w.key == null,
        )
        .last;
    await tester.ensureVisible(bar);
    await tester.pumpAndSettle();
    await tester.tap(bar);
    await tester.pumpAndSettle();

    expect(find.text('80% of limit'), findsOneWidget);
    expect(find.text(fmtMoney(800)), findsOneWidget);
    expect(find.text(fmtMoney(1000)), findsOneWidget);
  });
}
