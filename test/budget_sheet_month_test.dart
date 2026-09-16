import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/utils/app_theme.dart';
import 'package:expense_tracker/utils/figma_palette.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/budget_detail_sheet.dart';

/// The month switcher inside the budget detail sheet: chevrons step the
/// shown month, figures follow, the current month is the upper bound.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  testWidgets('chevrons step months and re-scope the figures', (tester) async {
    final p = FinanceProvider();
    await p.load();
    final now = DateTime.now();
    final thisMonth = DateTime(now.year, now.month);
    final lastMonth = DateTime(now.year, now.month - 1);
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'entertainment',
      amount: 800,
      note: 'this month',
      date: DateTime(thisMonth.year, thisMonth.month, 1),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'entertainment',
      amount: 300,
      note: 'last month',
      date: DateTime(lastMonth.year, lastMonth.month, 1),
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

    expect(find.text(fmtMonth(thisMonth)), findsOneWidget);
    expect(find.text('${fmtMoney(800)} / ${fmtMoney(1000)}'), findsOneWidget);
    // At the current month the forward chevron is disabled. byTooltip
    // matches the Tooltip INSIDE the button, so climb to the button itself.
    final next = tester.widget<IconButton>(
      find
          .ancestor(
            of: find.byTooltip('Next month'),
            matching: find.byType(IconButton),
          )
          .first,
    );
    expect(next.onPressed, isNull);

    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();
    expect(find.text(fmtMonth(lastMonth)), findsOneWidget);
    expect(find.text('${fmtMoney(300)} / ${fmtMoney(1000)}'), findsOneWidget);

    // Back forward — enabled again below the current month.
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
    expect(find.text(fmtMonth(thisMonth)), findsOneWidget);
    expect(find.text('${fmtMoney(800)} / ${fmtMoney(1000)}'), findsOneWidget);
  });

  test('snackbars dismiss with a horizontal swipe, both themes', () {
    for (final b in Brightness.values) {
      final theme = buildAppTheme(brightness: b, accent: FigmaPalette.primary);
      expect(theme.snackBarTheme.dismissDirection, DismissDirection.horizontal);
    }
  });
}
