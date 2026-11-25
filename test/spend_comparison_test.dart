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

    test('a month that has ended compares in full', () async {
      final p = await sixMonths();
      final c = buildMonthComparison(
        p,
        DateTime(2026, 8),
        now: DateTime(2026, 9, 17),
      );

      expect(c.throughDay, 31);
      expect(c.partial, isFalse);
      expect(c.vsPrevious.actual, 1500);
    });

    test('no last month on record leaves nothing to compare', () async {
      // First-ever data month: August is empty.
      final p = await loaded();
      await spend(p, DateTime(2026, 9, 1), 1700);

      final c = buildMonthComparison(
        p,
        DateTime(2026, 9),
        now: DateTime(2026, 9, 17),
      );
      expect(c.vsPrevious.state, CompareState.notEnoughHistory);
      expect(c.vsPrevious.referenceFull, 0);
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
      referenceFull: reference,
      state: CompareState.ok,
    );

    test('names the direction and the share', () {
      expect(deltaPhrase(c(1200, 1000)), contains('more'));
      expect(deltaPhrase(c(1200, 1000)), contains('20%'));
      expect(deltaPhrase(c(800, 1000)), contains('less'));
      expect(deltaPhrase(c(1000.4, 1000)), 'About the same');
    });

    test('whole rupees, with what it is measured against', () {
      expect(deltaPhrase(c(1200.4, 1000)), '₹200 (20%) more');
      expect(
        deltaPhrase(c(800, 1000), than: ' than Aug'),
        '₹200 (20%) less than Aug',
      );
    });

    test('past a doubling it reads as times, not a percentage', () {
      expect(
        deltaPhrase(c(2700, 1000), than: ' than Sep by this day'),
        '₹1,700 more than Sep by this day, 2.7 times as much',
      );
      // Exactly double is still a percentage; falls never pass 100%.
      expect(deltaPhrase(c(2000, 1000)), '₹1,000 (100%) more');
      expect(deltaPhrase(c(100, 1000)), '₹900 (90%) less');
    });

    test('timesPhrase: one decimal under 10, whole from 10', () {
      expect(timesPhrase(1.7), '2.7 times');
      expect(timesPhrase(2.0), '3 times');
      expect(timesPhrase(11.4), '12 times');
      expect(timesPhrase(1.0), isNull);
      expect(timesPhrase(0.5), isNull);
      expect(timesPhrase(null), isNull);
    });
  });

  group('thin months in the usual window', () {
    test('a month under a quarter of the middle stops the run', () async {
      final p = await loaded();
      // June and July full, August thin (a few rows only), September full.
      for (final (m, amount) in [
        (6, 20000.0),
        (7, 22000.0),
        (8, 1700.0),
        (9, 23000.0),
      ]) {
        await spend(p, DateTime(2026, m, 1), amount);
      }
      // August sits under a quarter of the run's middle, so the run stops
      // there, the way an empty month stops it: September alone.
      expect(usualWindow(p, DateTime(2026, 10)), [DateTime(2026, 9)]);
    });

    test('one big month keeps the normal month beside it', () async {
      final p = await loaded();
      await spend(p, DateTime(2026, 8, 1), 400);
      await spend(p, DateTime(2026, 8, 25), 1100);
      await spend(p, DateTime(2026, 9, 1), 400);
      await spend(p, DateTime(2026, 9, 25), 31000);
      // By whole totals the middle of two is ₹16,450 and August's ₹1,500
      // sits under its quarter. The typical row is ₹750, so the test caps
      // each row at ₹3,000: August ₹1,500 against September ₹3,400, a bar
      // of ₹612, and August stays.
      expect(usualWindow(p, DateTime(2026, 10)), [
        DateTime(2026, 8),
        DateTime(2026, 9),
      ]);
      final c = buildMonthComparison(
        p,
        DateTime(2026, 10),
        now: DateTime(2026, 10, 31),
      );
      expect(c.usualMonths, 2);
      expect(c.vsUsual.state, isNot(CompareState.notEnoughHistory));
      expect(c.vsUsual.referenceFull, (1500 + 31400) / 2);
    });

    test('a month of a few small rows is still a gap', () async {
      final p = await loaded();
      await spend(p, DateTime(2026, 8, 1), 100);
      await spend(p, DateTime(2026, 8, 20), 100);
      for (final d in [2, 9, 16, 23]) {
        await spend(p, DateTime(2026, 9, d), 5000);
      }
      // Typical row ₹5,000, so nothing is capped: August's ₹200 against a
      // bar of ₹2,525.
      expect(usualWindow(p, DateTime(2026, 10)), [DateTime(2026, 9)]);
    });

    test('a month holding only its rent beside full months is a gap', () async {
      final p = await loaded();
      await spend(p, DateTime(2026, 7, 1), 15000, category: 'bills');
      for (final m in [8, 9]) {
        await spend(p, DateTime(2026, m, 1), 15000, category: 'bills');
        for (var d = 2; d <= 21; d++) {
          await spend(p, DateTime(2026, m, d), 500);
        }
      }
      // The typical row is ₹500, so rent counts as ₹2,000. July holds that
      // alone against ₹12,000 for August and September, under the ₹3,000
      // bar: everyday rows were not recorded, and the run stops there.
      expect(usualWindow(p, DateTime(2026, 10)), [
        DateTime(2026, 8),
        DateTime(2026, 9),
      ]);
    });

    test('a run that spent nothing drops no month', () async {
      final p = await loaded();
      for (final m in [7, 8, 9]) {
        await p.addTransaction(
          type: TxType.income,
          categoryId: 'salary',
          amount: 5000,
          note: 'seed',
          date: DateTime(2026, m, 1),
        );
      }
      expect(usualWindow(p, DateTime(2026, 10)), [
        DateTime(2026, 7),
        DateTime(2026, 8),
        DateTime(2026, 9),
      ]);
    });
  });

  group('records that start recently', () {
    test('records starting this month: no last-month comparison', () async {
      final p = await loaded();
      await spend(p, DateTime(2026, 9, 10), 1600);
      final c = buildMonthComparison(
        p,
        DateTime(2026, 9),
        now: DateTime(2026, 9, 25),
      );
      expect(c.vsPrevious.state, CompareState.notEnoughHistory);
      expect(c.vsPrevious.actual, 1600);
    });

    test('records starting part-way through last month leave no '
        'reference', () async {
      final p = await loaded();
      await spend(p, DateTime(2026, 8, 20), 5000);
      await spend(p, DateTime(2026, 9, 3), 900);
      final c = buildMonthComparison(
        p,
        DateTime(2026, 9),
        now: DateTime(2026, 9, 25),
      );
      expect(c.vsPrevious.state, CompareState.notEnoughHistory);
      expect(c.vsPrevious.reference, 0);
    });

    test('a long-running ledger keeps the reference month', () async {
      final p = await sixMonths();
      final c = buildMonthComparison(
        p,
        DateTime(2026, 9),
        now: DateTime(2026, 9, 10),
      );
      expect(c.vsPrevious.state, isNot(CompareState.notEnoughHistory));
      // August reached 1000 by the 10th, of 1500 in all.
      expect(c.vsPrevious.reference, 1000);
      expect(c.vsPrevious.referenceFull, 1500);
    });

    test("a category's usual starts at its own first spend", () async {
      final p = await sixMonths();
      // Taxi first appears in August: its usual is August alone, not a
      // median dragged to zero by the five months before it existed.
      await spend(p, DateTime(2026, 8, 12), 800, category: 'transport');
      await spend(p, DateTime(2026, 9, 12), 300, category: 'transport');
      final c = buildMonthComparison(
        p,
        DateTime(2026, 9),
        now: DateTime(2026, 9, 30),
      );
      final taxi = c.categories.firstWhere((r) => r.category.id == 'transport');
      expect(taxi.usual, 800);
      expect(taxi.state, CompareState.ok);
    });
  });
}
