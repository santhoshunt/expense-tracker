import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/spend_comparison.dart';
import 'package:expense_tracker/services/year_comparison.dart';

/// "This year vs last year": both sides cut at the same month and day while
/// the year runs, whole years once it has ended, the April start, the
/// history gate and the 29 February clamp.
///
/// Every date is explicit and `now` is injected, so nothing here depends on
/// the day the suite runs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  Future<void> spend(
    FinanceProvider p,
    DateTime date,
    double amount, {
    String category = 'food',
  }) => p.addTransaction(
    type: TxType.expense,
    categoryId: category,
    amount: amount,
    note: 'seed',
    date: date,
  );

  test('a running calendar year compares up to the same day', () async {
    final p = await loaded();
    // Records start on last year's first day, so last year is on record.
    await spend(p, DateTime(2025, 1, 1), 100);
    await spend(p, DateTime(2025, 3, 10), 200);
    await spend(p, DateTime(2025, 6, 10), 300); // on or before the 15th
    await spend(p, DateTime(2025, 6, 20), 400); // after the 15th
    await spend(p, DateTime(2025, 9, 5), 800); // later in last year
    await spend(p, DateTime(2026, 2, 3), 500);
    await spend(p, DateTime(2026, 6, 14), 600);
    await spend(p, DateTime(2026, 6, 20), 70); // after today's date

    final c = buildYearComparison(
      p,
      startYear: 2026,
      startMonth: 1,
      now: DateTime(2026, 6, 15, 12),
    )!;

    expect(c.label, '2026');
    expect(c.previousLabel, '2025');
    expect(c.partial, isTrue);
    expect(c.through, DateTime(2026, 6, 15));
    expect(c.total.state, CompareState.ok);
    expect(c.total.actual, 1100);
    expect(c.total.reference, 600);
    expect(c.total.actualFull, isNull);
    expect(c.total.referenceFull, 1800);
  });

  test('an April-start year counts April to March on both sides', () async {
    final p = await loaded();
    await spend(p, DateTime(2025, 4, 1), 1000); // last FY's first day
    await spend(p, DateTime(2025, 10, 12), 200); // same day, last FY
    await spend(p, DateTime(2025, 10, 13), 300); // after it
    await spend(p, DateTime(2026, 3, 31), 400); // last FY's last day
    await spend(p, DateTime(2026, 4, 2), 500);
    await spend(p, DateTime(2026, 10, 1), 50);

    final c = buildYearComparison(
      p,
      startYear: 2026,
      startMonth: 4,
      now: DateTime(2026, 10, 12, 12),
    )!;

    expect(c.label, 'FY 2026-27');
    expect(c.previousLabel, 'FY 2025-26');
    expect(c.partial, isTrue);
    expect(c.through, DateTime(2026, 10, 12));
    expect(c.total.state, CompareState.ok);
    // March 2026 belongs to last FY: not in this year, not in last year's
    // span up to 12 October, only in last year's whole twelve months.
    expect(c.total.actual, 550);
    expect(c.total.reference, 1200);
    expect(c.total.referenceFull, 1900);
  });

  test('a finished year compares whole years', () async {
    final p = await loaded();
    await spend(p, DateTime(2024, 1, 1), 100);
    await spend(p, DateTime(2024, 12, 31), 200);
    await spend(p, DateTime(2025, 1, 1), 300);
    await spend(p, DateTime(2025, 12, 31), 400);
    await spend(p, DateTime(2026, 1, 1), 999); // next year: must not leak

    final c = buildYearComparison(
      p,
      startYear: 2025,
      startMonth: 1,
      now: DateTime(2026, 6, 15, 12),
    )!;

    expect(c.partial, isFalse);
    expect(c.through, DateTime(2025, 12, 31));
    expect(c.total.actual, 700);
    expect(c.total.reference, 300);
    expect(c.total.actualFull, c.total.actual);
    expect(c.total.referenceFull, 300);
    expect(c.total.state, CompareState.ok);
  });

  test('on its last day a year counts as ended', () async {
    final p = await loaded();
    await spend(p, DateTime(2025, 1, 1), 100);
    await spend(p, DateTime(2025, 12, 31), 200);
    await spend(p, DateTime(2026, 12, 31), 300);

    final c = buildYearComparison(
      p,
      startYear: 2026,
      startMonth: 1,
      now: DateTime(2026, 12, 31, 12),
    )!;

    expect(c.partial, isFalse);
    expect(c.through, DateTime(2026, 12, 31));
    expect(c.total.actual, 300);
    expect(c.total.reference, 300);
    expect(c.total.actualFull, 300);
  });

  test('records starting inside this year leave no fair comparison', () async {
    final now = DateTime(2026, 6, 15, 12);

    final empty = await loaded();
    final none = buildYearComparison(
      empty,
      startYear: 2026,
      startMonth: 1,
      now: now,
    )!;
    expect(none.total.state, CompareState.notEnoughHistory);
    expect(none.total.empty, isTrue);
    expect(none.categories, isEmpty);

    final p = await loaded();
    await spend(p, DateTime(2026, 2, 1), 500);
    await spend(p, DateTime(2026, 5, 1), 300, category: 'transport');
    final c = buildYearComparison(p, startYear: 2026, startMonth: 1, now: now)!;
    expect(c.total.state, CompareState.notEnoughHistory);
    expect(c.total.actual, 800);
    expect(c.categories, isEmpty);
  });

  test('records starting a day into last year are not enough', () async {
    final p = await loaded();
    await spend(p, DateTime(2025, 1, 2), 100);
    await spend(p, DateTime(2026, 3, 1), 200);
    final c = buildYearComparison(
      p,
      startYear: 2026,
      startMonth: 1,
      now: DateTime(2026, 6, 15, 12),
    )!;
    expect(c.total.state, CompareState.notEnoughHistory);
    expect(c.categories, isEmpty);
  });

  test('29 February takes all of the February before', () async {
    final p = await loaded();
    await spend(p, DateTime(2027, 1, 1), 100);
    await spend(p, DateTime(2027, 2, 28), 200); // last year's last Feb day
    await spend(p, DateTime(2027, 3, 1), 900); // after the cut
    await spend(p, DateTime(2028, 1, 10), 300);
    await spend(p, DateTime(2028, 2, 29), 400);

    final c = buildYearComparison(
      p,
      startYear: 2028,
      startMonth: 1,
      now: DateTime(2028, 2, 29, 12),
    )!;

    expect(c.partial, isTrue);
    expect(c.through, DateTime(2028, 2, 29));
    expect(c.total.actual, 700);
    expect(c.total.reference, 300);
  });

  test('a year that has not started returns null', () async {
    final p = await loaded();
    await spend(p, DateTime(2025, 1, 1), 100);
    final now = DateTime(2026, 6, 15, 12);
    expect(
      buildYearComparison(p, startYear: 2027, startMonth: 1, now: now),
      isNull,
    );
    expect(
      buildYearComparison(p, startYear: 2026, startMonth: 7, now: now),
      isNull,
    );
    expect(
      buildYearComparison(p, startYear: 2026, startMonth: 4, now: now),
      isNotNull,
    );
  });

  test('categories run largest change first, either direction', () async {
    final p = await loaded();
    // Outside both years: must not add a row.
    await spend(p, DateTime(2023, 6, 1), 50, category: 'bills');
    await spend(p, DateTime(2024, 1, 1), 1000);
    await spend(p, DateTime(2024, 5, 1), 300, category: 'transport');
    await spend(p, DateTime(2024, 6, 1), 2000, category: 'shopping');
    await spend(p, DateTime(2025, 2, 1), 1200);
    await spend(p, DateTime(2025, 3, 1), 1300, category: 'transport');
    await spend(p, DateTime(2025, 4, 1), 500, category: 'health');

    final c = buildYearComparison(
      p,
      startYear: 2025,
      startMonth: 1,
      now: DateTime(2026, 3, 1, 12),
    )!;

    expect(c.categories.map((r) => r.category.id), [
      'shopping', // -2000
      'transport', // +1000
      'health', // +500
      'food', // +200
    ]);
    final byId = {for (final r in c.categories) r.category.id: r};
    expect(byId['shopping']!.state, CompareState.noneThisMonth);
    expect(byId['shopping']!.usual, 2000);
    expect(byId['health']!.state, CompareState.newThisMonth);
    expect(byId['food']!.state, CompareState.ok);
    expect(byId['food']!.actual, 1200);
    expect(byId['food']!.usual, 1000);
  });
}
