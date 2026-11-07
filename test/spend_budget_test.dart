import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/utils/app_theme.dart';
import 'package:expense_tracker/utils/figma_palette.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/budget_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The custom-category registry is module-global; reset between tests.
    setCustomCategories(const []);
  });

  final july = DateTime(2026, 7);

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  Future<void> spend(FinanceProvider p, String categoryId, double amount) =>
      p.addTransaction(
        type: categoryById(categoryId).type,
        categoryId: categoryId,
        amount: amount,
        note: '',
        date: DateTime(2026, 7, 10 + p.transactions.length),
      );

  SpendBudget budget(BudgetMode mode, Set<String> ids) => SpendBudget(
    id: 'b',
    name: 'Test',
    limit: 1000,
    mode: mode,
    categoryIds: ids,
  );

  test('include mode counts only picked categories', () async {
    final p = await loaded();
    await spend(p, 'food', 100);
    await spend(p, 'shopping', 50);
    await spend(p, 'transport', 25);

    expect(
      p.budgetSpentFor(budget(BudgetMode.include, {'food', 'transport'}), july),
      125,
    );
  });

  test('include mode counts a picked money-out transfer category', () async {
    final p = await loaded();
    final chit = await p.addCategory(
      label: 'Chit',
      type: TxType.expense,
      icon: Icons.payments,
      color: Colors.teal,
      isTransfer: true,
    );
    await spend(p, 'food', 100);
    await spend(p, chit, 300); // transfer — excluded from expense totals
    await spend(p, 'transfer_out', 40); // unpicked transfer — never counts

    expect(p.expenseInMonth(july), 100); // sanity: transfers stay excluded
    expect(
      p.budgetSpentFor(budget(BudgetMode.include, {'food', chit}), july),
      400,
    );
  });

  test(
    'exclude mode is total spend minus picked; transfers never count',
    () async {
      final p = await loaded();
      await spend(p, 'food', 100);
      await spend(p, 'shopping', 50);
      await spend(p, 'savings_out', 200); // transfer

      expect(
        p.budgetSpentFor(budget(BudgetMode.exclude, {'shopping'}), july),
        100,
      );
      // A (stale) transfer id in the exclude set changes nothing — transfers
      // aren't in the base to begin with.
      expect(
        p.budgetSpentFor(
          budget(BudgetMode.exclude, {'shopping', 'savings_out'}),
          july,
        ),
        100,
      );
      // Empty exclude set = all non-transfer spending.
      expect(p.budgetSpentFor(budget(BudgetMode.exclude, const {}), july), 150);
    },
  );

  test('include mode with an empty set spends nothing', () async {
    final p = await loaded();
    await spend(p, 'food', 100);
    expect(p.budgetSpentFor(budget(BudgetMode.include, const {}), july), 0);
  });

  test('budgets persist across reloads', () async {
    final p = await loaded();
    await p.addBudget(
      name: 'Personal spending',
      limit: 20000,
      mode: BudgetMode.exclude,
      categoryIds: {'shopping', 'entertainment'},
    );

    final p2 = await loaded();
    final b = p2.budgets.single;
    expect(b.name, 'Personal spending');
    expect(b.limit, 20000);
    expect(b.mode, BudgetMode.exclude);
    expect(b.categoryIds, {'shopping', 'entertainment'});
  });

  test('deleteCategory strips the id from budgets', () async {
    final p = await loaded();
    final catId = await p.addCategory(
      label: 'Family',
      type: TxType.expense,
      icon: Icons.payments,
      color: Colors.teal,
    );
    final budId = await p.addBudget(
      name: 'Personal',
      limit: 5000,
      mode: BudgetMode.exclude,
      categoryIds: {catId, 'shopping'},
    );
    await p.deleteCategory(catId);
    final b = p.budgets.firstWhere((b) => b.id == budId);
    expect(b.categoryIds, {'shopping'});

    final p2 = await loaded(); // the strip was persisted
    expect(p2.budgets.single.categoryIds, {'shopping'});
  });

  test('countsTowardBudget mirrors budgetSpentFor row by row', () async {
    final p = await loaded();
    final chit = await p.addCategory(
      label: 'Chit',
      type: TxType.expense,
      icon: Icons.payments,
      color: Colors.teal,
      isTransfer: true,
    );
    await spend(p, 'food', 100);
    await spend(p, chit, 300);
    await spend(p, 'savings_out', 200);
    await spend(p, 'salary', 1000); // income never counts

    final include = budget(BudgetMode.include, {'food', chit});
    final exclude = budget(BudgetMode.exclude, {'food'});

    double viaRows(SpendBudget b) => p.transactions
        .where((t) => p.countsTowardBudget(t, b))
        .fold(0.0, (sum, t) => sum + t.amount);

    expect(viaRows(include), p.budgetSpentFor(include, july)); // 400
    expect(viaRows(exclude), p.budgetSpentFor(exclude, july)); // 0
    expect(viaRows(include), 400);

    final salary = p.transactions.firstWhere((t) => t.categoryId == 'salary');
    expect(p.countsTowardBudget(salary, include), isFalse);
    // Transfers never count in exclude mode, even unpicked ones.
    final savings = p.transactions.firstWhere(
      (t) => t.categoryId == 'savings_out',
    );
    expect(p.countsTowardBudget(savings, exclude), isFalse);
  });

  test('update and delete budget', () async {
    final p = await loaded();
    final id = await p.addBudget(
      name: 'Personal',
      limit: 5000,
      mode: BudgetMode.include,
      categoryIds: {'food'},
    );
    await p.updateBudget(
      p.budgets.single.copyWith(name: 'Own spend', limit: 7000),
    );
    expect(p.budgets.single.name, 'Own spend');
    expect(p.budgets.single.limit, 7000);
    await p.deleteBudget(id);
    expect(p.budgets, isEmpty);
  });

  group('trip form', () {
    /// Opens the budget editor from a button named 'open', at [textScale];
    /// [existing] picks the budget to edit, none for a new one.
    Future<void> openEditor(
      WidgetTester tester,
      FinanceProvider p, {
      SpendBudget? Function()? existing,
      double textScale = 1,
    }) async {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: p,
          child: MaterialApp(
            // The app's own theme: its type sizes decide what fits.
            theme: buildAppTheme(
              brightness: Brightness.dark,
              accent: FigmaPalette.primary,
            ),
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
                    onPressed: () =>
                        showBudgetDialog(context, existing: existing?.call()),
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

    DateTime soon() => DateTime.now().add(const Duration(milliseconds: 200));
    DateTime today() => DateUtils.dateOnly(soon());
    DateTime plus(DateTime d, int days) =>
        DateTime(d.year, d.month, d.day + days);

    testWidgets('a trip saves as a dated tag budget and its tag joins the '
        'saved tags', (tester) async {
      final p = await loaded();
      await openEditor(tester, p);
      await tester.tap(find.text('Trip or event'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('trip-name')),
        'Goa trip',
      );
      await tester.enterText(find.byKey(const ValueKey('trip-limit')), '15000');
      await tester.pump();
      await tester.tap(find.text('Create trip budget'));
      await tester.pumpAndSettle();

      final b = p.budgets.single;
      expect(b.mode, BudgetMode.include);
      expect(b.categoryIds, isEmpty);
      expect(b.tag, 'Goa trip');
      expect(b.limit, 15000);
      expect(b.range!.start, today());
      expect(b.range!.end, plus(today(), 6));
      expect(b.stageOn(soon()), TripStage.running);
      expect(p.savedTags, contains('Goa trip'));
    });

    testWidgets('a trip name that leaves no tag says why Create is off', (
      tester,
    ) async {
      final p = await loaded();
      await openEditor(tester, p);
      await tester.tap(find.text('Trip or event'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('trip-name')), '||');
      await tester.enterText(find.byKey(const ValueKey('trip-limit')), '5000');
      await tester.pump();

      expect(
        find.text('Enter a trip name with letters or numbers'),
        findsOneWidget,
      );
      final create = tester.widget<FilledButton>(
        find.byKey(const ValueKey('editor-save')),
      );
      expect(create.onPressed, isNull);
    });

    testWidgets('Pick dates… clamps a range past 91 days', (tester) async {
      final p = await loaded();
      await openEditor(tester, p);
      await tester.tap(find.text('Trip or event'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pick dates…'));
      await tester.pumpAndSettle();
      // The range picker's typed entry, in its mm/dd/yyyy format.
      await tester.tap(find.byTooltip('Switch to input'));
      await tester.pumpAndSettle();
      String typed(DateTime d) =>
          '${d.month.toString().padLeft(2, '0')}/'
          '${d.day.toString().padLeft(2, '0')}/${d.year}';
      final start = today();
      await tester.enterText(
        find.widgetWithText(TextField, 'Start Date'),
        typed(start),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'End Date'),
        typed(plus(start, 119)),
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          '${fmtDateCompact(start)} to ${fmtDateCompact(plus(start, 91))} · '
          '92 days',
        ),
        findsOneWidget,
      );
      expect(find.text('Up to 3 months'), findsOneWidget);
    });

    testWidgets('the trip sheet fits a small phone with the keyboard up', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final p = await loaded();
      await openEditor(tester, p, textScale: 2);
      await tester.tap(find.text('Trip or event'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 280 * 3);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('editor-save')).hitTestable(),
        findsOneWidget,
      );
    });

    testWidgets('the trip dates wrap, never cut, at 320dp and 2x text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900) * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final p = await loaded();
      await openEditor(tester, p, textScale: 2);
      await tester.tap(find.text('Trip or event'));
      await tester.pumpAndSettle();

      final dates = find.descendant(
        of: find.byKey(const ValueKey('trip-dates')),
        matching: find.textContaining(' · '),
      );
      expect(dates, findsOneWidget);
      expect(
        tester.renderObject<RenderParagraph>(dates).didExceedMaxLines,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('editing a trip skips the kind sheet', (tester) async {
      final p = await loaded();
      await p.addBudget(
        name: 'Goa trip',
        limit: 15000,
        mode: BudgetMode.include,
        categoryIds: const {},
        tag: 'Goa trip',
        range: DateTimeRange(start: today(), end: plus(today(), 6)),
      );
      await openEditor(tester, p, existing: () => p.budgets.single);

      expect(find.text('Edit trip budget'), findsOneWidget);
      expect(find.text('Trip or event'), findsNothing);
      expect(find.byTooltip('Back'), findsNothing);
    });
  });
}
