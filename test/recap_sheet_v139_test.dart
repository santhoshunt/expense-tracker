import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/monthly_recap.dart';
import 'package:expense_tracker/widgets/monthly_recap_card.dart';
import 'package:expense_tracker/widgets/recap_sheet.dart';

/// v1.39.0: any past month's recap opens as a sheet from the ⋮ menu. The
/// arrows walk the months with data, skipping gaps. Names and amounts are
/// made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  final jun = DateTime(2026, 6);
  final jul = DateTime(2026, 7);
  final aug = DateTime(2026, 8);
  final sep = DateTime(2026, 9);
  final oct = DateTime(2026, 10);
  final nov = DateTime(2026, 11);

  Future<(FinanceProvider, SettingsProvider)> load() async {
    final f = FinanceProvider();
    await f.load();
    final s = SettingsProvider();
    await s.load();
    return (f, s);
  }

  Future<String> spend(
    FinanceProvider f,
    String category,
    double amount,
    DateTime date,
  ) => f.addTransaction(
    type: TxType.expense,
    categoryId: category,
    amount: amount,
    note: 'test $category',
    date: date,
  );

  group('recapMonths', () {
    final now = DateTime(2026, 10, 14, 10);

    test('months before this one, newest first', () {
      // Unordered, with this month and a future-dated one.
      expect(recapMonths([aug, nov, jun, oct, sep], now), [sep, aug, jun]);
    });

    test('a gap month stays out', () {
      expect(recapMonths([sep, jun, aug], now), [sep, aug, jun]);
      expect(recapMonths([sep, jun, aug], now), isNot(contains(jul)));
    });

    test('empty in the first month of use', () {
      expect(recapMonths([oct], now), isEmpty);
      expect(recapMonths(const [], now), isEmpty);
    });

    test('January reaches back to December', () {
      expect(
        recapMonths([
          DateTime(2027, 1),
          DateTime(2026, 12),
        ], DateTime(2027, 1, 2)),
        [DateTime(2026, 12)],
      );
    });

    test('the first of the month already counts last month', () {
      expect(recapMonths([sep, oct], DateTime(2026, 10, 1)), [sep]);
    });
  });

  group('buildRecapFor', () {
    test('matches the recap the 1st of the month after builds', () async {
      final (f, s) = await load();
      await s.setMonthlyBudget(500);
      await f.addBudget(
        name: 'Eating out',
        limit: 300,
        mode: BudgetMode.include,
        categoryIds: {'food'},
      );
      // On the 1st: a month the records start part-way through is not a
      // reference.
      await spend(f, 'food', 1000, DateTime(2026, 6, 1));
      await spend(f, 'food', 400, DateTime(2026, 7, 3));
      await spend(f, 'bills', 900, DateTime(2026, 7, 9));
      await spend(f, 'transport', 200, DateTime(2026, 7, 12));

      final r = buildRecapFor(f, s, jul)!;
      final card = buildMonthlyRecap(f, s, now: DateTime(2026, 8, 1))!;
      expect(r.month, jul);
      expect(r.spent, 1500);
      expect(r.spent, card.spent);
      expect(r.saved, card.saved);
      expect(r.vsPrevious.actual, card.vsPrevious.actual);
      expect(r.vsPrevious.reference, card.vsPrevious.reference);
      expect(r.vsPrevious.reference, 1000, reason: 'all of June');
      expect(
        [for (final e in r.topCategories) e.key.id],
        ['bills', 'food', 'transport'],
      );
      expect(
        [for (final b in r.budgetsOver) b.label],
        ['Monthly budget', 'Eating out'],
      );
    });

    test('null for a month with no transactions', () async {
      final (f, s) = await load();
      await spend(f, 'food', 100, DateTime(2026, 6, 4));
      await spend(f, 'food', 100, DateTime(2026, 8, 4));
      expect(buildRecapFor(f, s, jul), isNull);
      expect(buildRecapFor(f, s, aug), isNotNull);
    });

    test('December is compared with November', () async {
      final (f, s) = await load();
      await spend(f, 'food', 600, DateTime(2026, 11, 1));
      await spend(f, 'food', 700, DateTime(2026, 12, 24));
      final r = buildRecapFor(f, s, DateTime(2026, 12))!;
      expect(r.month, DateTime(2026, 12));
      expect(r.spent, 700);
      expect(r.vsPrevious.reference, 600);
    });
  });

  group('the recap sheet', () {
    tearDown(() => recapClock = DateTime.now);

    /// June, August and September have rows, July none, and October is
    /// the running month.
    Future<(FinanceProvider, Map<String, String>)> ledger() async {
      final (f, _) = await load();
      final ids = {
        'jun': await spend(f, 'transport', 300, DateTime(2026, 6, 5)),
        'aug': await spend(f, 'shopping', 450, DateTime(2026, 8, 9)),
        'sep': await spend(f, 'food', 250, DateTime(2026, 9, 12)),
        'oct': await spend(f, 'bills', 800, DateTime(2026, 10, 2)),
      };
      return (f, ids);
    }

    Future<void> open(
      WidgetTester tester,
      FinanceProvider f,
      DateTime month, {
      void Function(String, DateTime)? onViewCategory,
    }) async {
      recapClock = () => DateTime(2026, 10, 14, 10);
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = SettingsProvider();
      await s.load();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: f),
            ChangeNotifierProvider.value(value: s),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showRecapSheet(
                    context,
                    month: month,
                    onViewCategory: onViewCategory,
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    Finder prev() => find.widgetWithIcon(IconButton, Icons.chevron_left);
    Finder next() => find.widgetWithIcon(IconButton, Icons.chevron_right);
    bool enabled(WidgetTester tester, Finder button) =>
        tester.widget<IconButton>(button).onPressed != null;

    testWidgets('the arrows step through months with data, skipping July', (
      tester,
    ) async {
      final (f, _) = await ledger();
      await open(tester, f, aug);
      expect(find.text('August 2026 recap'), findsOneWidget);
      // The sheet draws the header; the card leaves its own title out.
      expect(find.byType(MonthlyRecapCard), findsOneWidget);
      expect(find.text('August recap'), findsNothing);

      await tester.tap(prev());
      await tester.pumpAndSettle();
      expect(find.text('June 2026 recap'), findsOneWidget);
      expect(enabled(tester, prev()), isFalse, reason: 'June is the first');
      expect(enabled(tester, next()), isTrue);

      await tester.tap(next());
      await tester.pumpAndSettle();
      expect(find.text('August 2026 recap'), findsOneWidget);
      await tester.tap(next());
      await tester.pumpAndSettle();
      expect(find.text('September 2026 recap'), findsOneWidget);
      // October is still running: no recap yet.
      expect(enabled(tester, next()), isFalse);
      expect(enabled(tester, prev()), isTrue);
    });

    testWidgets('a category tap closes the sheet, then opens the rows', (
      tester,
    ) async {
      final (f, _) = await ledger();
      final opened = <(String, DateTime)>[];
      await open(
        tester,
        f,
        sep,
        onViewCategory: (id, month) => opened.add((id, month)),
      );
      await tester.tap(find.text(categoryById('food').label));
      await tester.pumpAndSettle();
      expect(opened, [('food', sep)]);
      expect(find.text('September 2026 recap'), findsNothing);
      expect(find.byType(MonthlyRecapCard), findsNothing);
    });

    testWidgets('an emptied month says so and its arrows still work', (
      tester,
    ) async {
      final (f, ids) = await ledger();
      await open(tester, f, aug);
      await f.deleteTransaction(ids['aug']!);
      await tester.pumpAndSettle();
      expect(find.text('August 2026 recap'), findsOneWidget);
      expect(find.text('No transactions in August 2026'), findsOneWidget);
      expect(find.byType(MonthlyRecapCard), findsNothing);
      await tester.tap(next());
      await tester.pumpAndSettle();
      expect(find.text('September 2026 recap'), findsOneWidget);
      await tester.tap(prev());
      await tester.pumpAndSettle();
      expect(find.text('June 2026 recap'), findsOneWidget);
    });
  });
}
