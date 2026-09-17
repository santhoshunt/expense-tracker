import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/spend_comparison.dart';

/// The spending comparisons: day-aligned figures, the median baseline, the
/// window of months it is drawn from, and the states that exist only because
/// a zero baseline has no percentage.
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

  /// Six complete months (Mar–Aug 2026) at 1000 on the 1st and another 500
  /// on the 25th, then 1400 so far in September. Records start on a 1st, so
  /// the whole window is usable.
  Future<FinanceProvider> sixMonths() async {
    final p = await loaded();
    for (var m = 3; m <= 8; m++) {
      await spend(p, DateTime(2026, m, 1), 1000);
      await spend(p, DateTime(2026, m, 25), 500);
    }
    await spend(p, DateTime(2026, 9, 5), 1400);
    return p;
  }

  group('median', () {
    test('odd count takes the middle, even averages the two', () {
      expect(median([5, 1, 3]), 3);
      expect(median([4, 1, 3, 2]), 2.5);
    });

    test('empty is zero, so a category with no history has no baseline', () {
      expect(median(const []), 0);
    });
  });

  group('day-limited month totals', () {
    test('a day covering the month equals the full-month figure', () async {
      final p = await sixMonths();
      final aug = DateTime(2026, 8);
      expect(p.expenseInMonthThrough(aug, 31), p.expenseInMonth(aug));
      expect(p.expenseInMonthThrough(aug, 17), 1000);
    });

    test('a shorter month short-circuits to its full total', () async {
      final p = await loaded();
      await spend(p, DateTime(2026, 1, 1), 100);
      await spend(p, DateTime(2026, 2, 27), 800);
      for (var m = 3; m <= 6; m++) {
        await spend(p, DateTime(2026, m, 1), 200);
      }
      await spend(p, DateTime(2026, 7, 5), 500);
      await spend(p, DateTime(2026, 7, 31), 900);

      // Through the 30th, February has already ended, so its whole total
      // counts. A refactor of that guard would silently move the baseline.
      expect(p.expenseInMonthThrough(DateTime(2026, 2), 30), 800);
      expect(
        p.expenseInMonthThrough(DateTime(2026, 2), 30),
        p.expenseInMonth(DateTime(2026, 2)),
      );

      final c = buildMonthComparison(
        p,
        DateTime(2026, 7),
        now: DateTime(2026, 7, 30),
      );
      expect(c.partial, isTrue, reason: 'July runs to the 31st');
      expect(c.vsPrevious.actual, 500, reason: 'the 31st is not counted yet');
      // Jan 100, Feb 800, Mar–Jun 200 → sorted [100,200,200,200,200,800]. The
      // median ignores both outliers, which is the reason it is the median.
      expect(c.vsUsual.reference, 200);
    });

    test('a finished month measures against whole months', () async {
      final p = await loaded();
      await spend(p, DateTime(2026, 5, 1), 100);
      await spend(p, DateTime(2026, 5, 31), 400);
      await spend(p, DateTime(2026, 6, 10), 700);

      // June is 30 days long. Cutting May at its 30th, just because June
      // ended there, would drop the 31 May row from the comparison.
      final c = buildMonthComparison(
        p,
        DateTime(2026, 6),
        now: DateTime(2026, 9, 17),
      );
      expect(c.partial, isFalse);
      expect(c.vsPrevious.reference, 500);
    });

    test('the partial cache stays bounded as months are browsed', () async {
      final p = await sixMonths();
      for (var m = 5; m <= 9; m++) {
        buildMonthComparison(p, DateTime(2026, m), now: DateTime(2026, 9, 17));
      }
      // Only the running month's window can be partial; every other month
      // short-circuits to the full-month cache.
      expect(
        p.partialMonthCacheSize,
        lessThanOrEqualTo(kUsualWindowMonths + 1),
      );
    });
  });

  group('usual window', () {
    test('caps at six complete months and excludes the shown one', () async {
      final p = await loaded();
      for (var m = 1; m <= 12; m++) {
        await spend(p, DateTime(2025, m, 1), 10);
      }
      for (var m = 1; m <= 9; m++) {
        await spend(p, DateTime(2026, m, 1), 10);
      }
      expect(usualWindow(p, DateTime(2026, 9)), [
        DateTime(2026, 3),
        DateTime(2026, 4),
        DateTime(2026, 5),
        DateTime(2026, 6),
        DateTime(2026, 7),
        DateTime(2026, 8),
      ]);
    });

    test('a first month starting mid-month is dropped', () async {
      final p = await loaded();
      await spend(p, DateTime(2026, 7, 10), 100);
      await spend(p, DateTime(2026, 8, 3), 100);
      // July is only half covered by the ledger, so it would read as a quiet
      // month rather than a real one.
      expect(usualWindow(p, DateTime(2026, 9)), [DateTime(2026, 8)]);
    });

    test('a first month starting on the 1st is kept', () async {
      final p = await loaded();
      await spend(p, DateTime(2026, 7, 1), 100);
      await spend(p, DateTime(2026, 8, 3), 100);
      expect(usualWindow(p, DateTime(2026, 9)), [
        DateTime(2026, 7),
        DateTime(2026, 8),
      ]);
    });

    test('an empty ledger has no window at all', () async {
      final p = await loaded();
      expect(usualWindow(p, DateTime(2026, 9)), isEmpty);
    });

    test('the run stops at a gap instead of averaging in the blanks', () async {
      final p = await loaded();
      // One old row, then a long silence, then real records from August.
      await spend(p, DateTime(2020, 3, 2), 50);
      await spend(p, DateTime(2026, 8, 1), 900);
      await spend(p, DateTime(2026, 9, 5), 700);

      expect(usualWindow(p, DateTime(2026, 9)), [DateTime(2026, 8)]);
      final c = buildMonthComparison(
        p,
        DateTime(2026, 9),
        now: DateTime(2026, 9, 17),
      );
      expect(
        c.vsUsual.state,
        CompareState.notEnoughHistory,
        reason: 'five unrecorded months are not five quiet ones',
      );
    });
  });

  group('headline comparisons', () {
    test('both sides are cut at the same day of the month', () async {
      final p = await sixMonths();
      final c = buildMonthComparison(
        p,
        DateTime(2026, 9),
        now: DateTime(2026, 9, 17),
      );

      expect(c.throughDay, 17);
      expect(c.partial, isTrue);
      expect(c.usualMonths, 6);
      expect(c.vsPrevious.actual, 1400);
      // August's 25th-of-the-month spend is past the 17th, so it is left out.
      expect(c.vsPrevious.reference, 1000);
      expect(c.vsPrevious.referenceFull, 1500);
      expect(c.vsUsual.reference, 1000);
      expect(c.vsUsual.referenceFull, 1500);
      expect(c.vsPrevious.state, CompareState.ok);
      expect(c.vsPrevious.delta, 400);
      expect(c.vsPrevious.deltaPct, closeTo(0.4, 0.001));
    });

    test(
      'a month that has ended compares in full, with no projection',
      () async {
        final p = await sixMonths();
        final c = buildMonthComparison(
          p,
          DateTime(2026, 8),
          now: DateTime(2026, 9, 17),
        );

        expect(c.throughDay, 31);
        expect(c.partial, isFalse);
        expect(c.vsPrevious.actual, 1500);
        expect(c.vsPrevious.actualFull, 1500, reason: 'exact, not projected');
      },
    );

    test('projection scales to the month, and stays quiet early on', () async {
      final p = await sixMonths();
      final mid = buildMonthComparison(
        p,
        DateTime(2026, 9),
        now: DateTime(2026, 9, 17),
      );
      // September runs 30 days: 1400 × 30 / 17.
      expect(mid.vsPrevious.actualFull, closeTo(1400 * 30 / 17, 0.001));

      final early = buildMonthComparison(
        p,
        DateTime(2026, 9),
        now: DateTime(2026, 9, 3),
      );
      expect(
        early.vsPrevious.actualFull,
        isNull,
        reason: 'a ×10 multiplier is noise, not a forecast',
      );
    });

    test(
      'a baseline below two months is refused rather than guessed',
      () async {
        final p = await loaded();
        await spend(p, DateTime(2026, 8, 1), 500);
        await spend(p, DateTime(2026, 9, 5), 700);
        final c = buildMonthComparison(
          p,
          DateTime(2026, 9),
          now: DateTime(2026, 9, 17),
        );
        expect(c.usualMonths, 1);
        expect(c.vsUsual.state, CompareState.notEnoughHistory);
      },
    );

    test('nothing on either side reads as empty, not as a drop', () async {
      final p = await loaded();
      await spend(p, DateTime(2026, 1, 1), 100);
      final c = buildMonthComparison(
        p,
        DateTime(2026, 9),
        now: DateTime(2026, 9, 17),
      );
      expect(c.vsPrevious.empty, isTrue);
      expect(c.vsPrevious.deltaPct, isNull, reason: 'never an infinity');
    });
  });

  group('categories vs usual', () {
    Future<MonthComparison> scenario() async {
      final p = await loaded();
      for (var m = 3; m <= 8; m++) {
        await spend(p, DateTime(2026, m, 1), 1000);
        await spend(p, DateTime(2026, m, 1), 300, category: 'transport');
      }
      await spend(p, DateTime(2026, 9, 5), 1400);
      await spend(p, DateTime(2026, 9, 5), 200, category: 'shopping');
      return buildMonthComparison(
        p,
        DateTime(2026, 9),
        now: DateTime(2026, 9, 17),
      );
    }

    test('states name each shape a zero baseline can take', () async {
      final c = await scenario();
      final byId = {for (final e in c.categories) e.category.id: e};

      expect(byId['food']!.state, CompareState.ok);
      expect(byId['food']!.usual, 1000);
      expect(byId['food']!.delta, 400);

      // Spent every month before, nothing yet this one.
      expect(byId['transport']!.state, CompareState.noneThisMonth);
      expect(byId['transport']!.actual, 0);
      expect(byId['transport']!.usual, 300);

      // Never before, so there is no percentage to quote.
      expect(byId['shopping']!.state, CompareState.newThisMonth);
      expect(byId['shopping']!.usual, 0);
    });

    test('biggest deviation first, in either direction', () async {
      final c = await scenario();
      expect(c.categories.map((e) => e.category.id).toList(), [
        'food',
        'transport',
        'shopping',
      ]);
    });

    test('deltaPct is relative to usual, null when there is none', () async {
      final c = await scenario();
      final byId = {for (final e in c.categories) e.category.id: e};

      expect(byId['food']!.deltaPct, closeTo(0.4, 1e-9));
      expect(byId['transport']!.deltaPct, closeTo(-1.0, 1e-9));
      // New this month: no baseline, so no percentage — not an infinity.
      expect(byId['shopping']!.deltaPct, isNull);
    });

    test('categories quiet in both windows are left out', () async {
      final c = await scenario();
      expect(c.categories, isNotEmpty);
      expect(c.categories.every((e) => e.actual > 0 || e.usual > 0), isTrue);
    });

    test('transfers never reach the comparison', () async {
      final p = await loaded();
      for (var m = 3; m <= 8; m++) {
        await spend(p, DateTime(2026, m, 1), 1000);
      }
      await spend(
        p,
        DateTime(2026, 9, 5),
        5000,
        category: kSavingsTransferCategoryId,
      );
      final c = buildMonthComparison(
        p,
        DateTime(2026, 9),
        now: DateTime(2026, 9, 17),
      );
      expect(
        c.categories.map((e) => e.category.id),
        isNot(contains(kSavingsTransferCategoryId)),
      );
      expect(c.vsPrevious.actual, 0, reason: 'a transfer is not spending');
    });
  });

  group('delta wording', () {
    SpendCompare c(double actual, double reference) => SpendCompare(
      actual: actual,
      reference: reference,
      actualFull: null,
      referenceFull: reference,
      state: CompareState.ok,
    );

    test('names the direction and the share', () {
      expect(deltaPhrase(c(1200, 1000)), contains('more'));
      expect(deltaPhrase(c(1200, 1000)), contains('20%'));
      expect(deltaPhrase(c(800, 1000)), contains('less'));
      expect(deltaPhrase(c(1000.4, 1000)), 'the same');
    });
  });
}
