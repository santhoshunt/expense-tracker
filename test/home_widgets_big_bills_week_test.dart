import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/subscription_cycle.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/home_widgets_service.dart';
import 'package:expense_tracker/services/weekly_digest.dart';

/// v1.41.0 Big bills and This week widgets: their snapshot blocks and the
/// usual week cut to each weekday. 12 Oct 2026 is a Monday. Names and
/// amounts are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  // Wednesday: the current week holds Monday to Wednesday.
  final now = DateTime(2026, 10, 14, 10);
  final monday = DateTime(2026, 10, 12);

  Future<void> spend(
    FinanceProvider p,
    String category,
    double amount,
    DateTime date,
  ) => p.addTransaction(
    type: TxType.expense,
    categoryId: category,
    amount: amount,
    note: 'test $category',
    date: date,
  );

  /// Three earlier weeks, then this week so far, as weekly_digest_test.dart
  /// builds them.
  Future<FinanceProvider> ledger() async {
    final p = FinanceProvider();
    await p.load();
    // Week of 21 Sep, the first on record: Monday 100, Thursday 1,000.
    await spend(p, 'food', 100, DateTime(2026, 9, 21));
    await spend(p, 'food', 1000, DateTime(2026, 9, 24));
    // Week of 28 Sep: Tuesday 300.
    await spend(p, 'food', 300, DateTime(2026, 9, 29));
    // Week of 5 Oct: Wednesday 200, Friday 5,000.
    await spend(p, 'food', 200, DateTime(2026, 10, 7));
    await spend(p, 'shopping', 5000, DateTime(2026, 10, 9));
    // This week: two spends and a transfer, then one row waiting.
    await spend(p, 'food', 50, DateTime(2026, 10, 12, 9));
    await spend(p, 'transport', 150, DateTime(2026, 10, 13, 18));
    await spend(p, 'food', 20, DateTime(2026, 10, 13, 19));
    await spend(p, kTransferOutCategoryId, 4000, DateTime(2026, 10, 13));
    await p.restoreTransaction(
      Tx(
        id: 'test-pending',
        type: TxType.expense,
        categoryId: 'food',
        amount: 75,
        note: 'test pending',
        date: DateTime(2026, 10, 13),
        pending: true,
      ),
    );
    return p;
  }

  /// The snapshot as Kotlin reads it.
  Future<Map<String, dynamic>> snapshot(FinanceProvider p) async {
    final s = SettingsProvider();
    await s.load();
    final snap = buildHomeWidgetSnapshot(
      p,
      s,
      now,
      const [],
      patterns: const [],
    );
    return jsonDecode(jsonEncode(snap)) as Map<String, dynamic>;
  }

  group('usualWeekByDay', () {
    test('cuts the usual week at each weekday', () async {
      final p = await ledger();
      // Monday to each day of the three weeks on record (5 Oct, 28 Sep,
      // 21 Sep): the median of each cut.
      expect(usualWeekByDay(p, monday), [0, 100, 200, 300, 1100, 1100, 1100]);
    });

    test("agrees with the digest's usual week on every day", () async {
      final p = await ledger();
      final cuts = usualWeekByDay(p, monday);
      for (var k = 1; k <= 7; k++) {
        final day = DateTime(2026, 10, 11 + k, 10);
        expect(
          cuts[k - 1],
          buildWeekDigest(p, monday, now: day).usual,
          reason: 'day $k',
        );
      }
    });

    test('a quiet week in between counts as nothing spent', () async {
      final p = FinanceProvider();
      await p.load();
      await spend(p, 'food', 900, DateTime(2026, 9, 21));
      // Nothing in the week of 28 Sep.
      await spend(p, 'food', 300, DateTime(2026, 10, 5));
      // 300, 0 and 900 on every cut.
      expect(usualWeekByDay(p, monday), List.filled(7, 300));
    });

    test('under two earlier weeks every day is null', () async {
      final p = FinanceProvider();
      await p.load();
      await spend(p, 'food', 400, DateTime(2026, 10, 6));
      await spend(p, 'food', 60, DateTime(2026, 10, 12));
      expect(usualWeekByDay(p, monday), List.filled(7, null));
      final empty = FinanceProvider();
      await empty.load();
      expect(usualWeekByDay(empty, monday), List.filled(7, null));
    });
  });

  group('the week block', () {
    test("carries this week's spend, day bars and the usual by day", () async {
      final week = (await snapshot(await ledger()))['week'] as Map;
      expect(week['weekStart'], epochDay(monday));
      // Transfers are not spend: 50 on Monday, 170 on Tuesday.
      expect(week['spent'], 220);
      expect(week['spentLabel'], '₹220');
      expect(week['byDay'], [50, 170, 0, 0, 0, 0, 0]);
      expect(week['usualByDay'], [0, 100, 200, 300, 1100, 1100, 1100]);
      expect(week['toReview'], 1);
    });

    test('is written with nulls before there is a usual week', () async {
      final p = FinanceProvider();
      await p.load();
      final week = (await snapshot(p))['week'] as Map;
      expect(week['spent'], 0);
      expect(week['usualByDay'], List.filled(7, null));
    });
  });

  group('the bigBills block', () {
    /// A reminder with no createdOn: made "long ago".
    Reminder reminder(
      String id,
      String name,
      SubscriptionCycle cycle,
      int anchor,
      int day,
      double amount,
    ) => Reminder(
      id: id,
      name: name,
      dayOfMonth: day,
      categoryId: 'bills',
      expectedAmount: amount,
      cycle: cycle,
      anchorMonth: anchor,
    );

    test('carries the monthly figure, 12 months and the next two', () async {
      final p = FinanceProvider();
      await p.load();
      for (final r in [
        // Quarterly: Jan, Apr, Jul and Oct, on the 25th.
        reminder('r1', 'Broadband', SubscriptionCycle.quarterly, 10, 25, 3000),
        reminder(
          'r2',
          'Car insurance',
          SubscriptionCycle.yearly,
          11,
          20,
          12000,
        ),
        reminder('r3', 'Domain', SubscriptionCycle.yearly, 3, 5, 1200),
      ]) {
        await p.restoreReminder(r);
      }
      final bills = (await snapshot(p))['bigBills'] as Map;
      expect(bills['monthKey'], 2026 * 12 + 10);
      // 12,000 + 1,200 + 4 x 3,000 a year, over 12.
      expect(bills['monthly'], 2100);
      expect(bills['monthlyLabel'], '₹2,100');
      expect(bills['yearlyLabel'], '₹25,200');
      // October to September.
      expect(bills['months'], [
        3000,
        12000,
        0,
        3000,
        0,
        1200,
        3000,
        0,
        0,
        3000,
        0,
        0,
      ]);
      expect(bills['count'], 3);
      final next = bills['next'] as List;
      expect(next, hasLength(2));
      expect(
        [for (final n in next) n['label']],
        ['Broadband', 'Car insurance'],
      );
      final first = next.first as Map;
      expect(first['amountLabel'], '₹3,000');
      expect(first['dueDay'], epochDay(DateTime(2026, 10, 25)));
      expect(first['dueLabel'], '25 Oct');
      expect(first['icon'], categoryById('bills').iconKey);
    });

    test('is left out with no big bills', () async {
      final p = await ledger();
      // A monthly reminder is not a big bill.
      await p.restoreReminder(
        reminder('r1', 'Rent', SubscriptionCycle.monthly, 1, 5, 18000),
      );
      expect((await snapshot(p)).containsKey('bigBills'), isFalse);
    });
  });
}
