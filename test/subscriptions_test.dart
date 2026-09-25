import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/services/subscriptions.dart';

/// The Subscriptions list: active versus stopped, yearly cost, price rises,
/// and the Upcoming card's window left exactly as it was.
void main() {
  final now = DateTime(2026, 9, 15, 10);
  var seq = 0;

  Tx tx(
    String note,
    double amount,
    DateTime date, {
    TxType type = TxType.expense,
    String category = 'bills',
  }) => Tx(
    id: 't${seq++}',
    type: type,
    categoryId: category,
    amount: amount,
    note: note,
    date: date,
  );

  // Charging monthly, last paid 12 Aug, so due 12 Sep: 3 days late.
  final netflix = [
    tx('Netflix', 499, DateTime(2026, 6, 12)),
    tx('Netflix', 499, DateTime(2026, 7, 12)),
    tx('Netflix', 649, DateTime(2026, 8, 12)),
  ];
  // Last paid in May: long past its date.
  final gym = [
    tx('Gym', 1000, DateTime(2026, 3, 5)),
    tx('Gym', 1000, DateTime(2026, 4, 5)),
    tx('Gym', 1000, DateTime(2026, 5, 5)),
  ];
  final salary = [
    for (final m in [7, 8, 9])
      tx(
        'Salary',
        50000,
        DateTime(2026, m, 1),
        type: TxType.income,
        category: 'salary',
      ),
  ];

  test('active, stopped and income kept apart', () {
    final s = buildSubscriptions([...netflix, ...gym, ...salary], now: now);
    expect([for (final i in s.active) i.hit.label], ['Netflix']);
    expect([for (final i in s.stopped) i.hit.label], ['Gym']);
    expect(s.hidden, isEmpty);
  });

  test('yearly and monthly cost from the usual amount and interval', () {
    final s = buildSubscriptions(netflix, now: now);
    final item = s.active.single;
    // Median of the last three (499, 499, 649) over a 31-day interval.
    expect(item.hit.expectedAmount, 499);
    expect(item.hit.intervalDays, 31);
    expect(item.yearly, closeTo(499 * 365 / 31, 1e-9));
    expect(item.monthly, closeTo(item.yearly / 12, 1e-9));
    expect(s.monthlyTotal, closeTo(item.monthly, 1e-9));
    expect(s.yearlyTotal, closeTo(item.yearly, 1e-9));
  });

  test('stopped payments do not count toward the totals', () {
    final s = buildSubscriptions([...netflix, ...gym], now: now);
    expect(s.yearlyTotal, closeTo(s.active.single.yearly, 1e-9));
  });

  test('a price rise needs 5% and ₹10', () {
    final rise = buildSubscriptions(netflix, now: now).active.single.priceRise;
    expect(rise?.amount, 150);
    expect(rise?.since, DateTime(2026, 7, 12));

    List<Tx> pattern(String note, double a, double b) => [
      tx(note, a, DateTime(2026, 6, 12)),
      tx(note, a, DateTime(2026, 7, 12)),
      tx(note, b, DateTime(2026, 8, 12)),
    ];
    SubscriptionItem only(List<Tx> rows) =>
        buildSubscriptions(rows, now: now).active.single;
    // 4%: tax drift, not a rise.
    expect(only(pattern('Fibre', 1000, 1040)).priceRise, isNull);
    // 9% but only ₹9.
    expect(only(pattern('Cloud', 100, 109)).priceRise, isNull);
    // Exactly at both thresholds.
    expect(only(pattern('Music', 200, 210)).priceRise?.amount, 10);
    // A price drop is no rise.
    expect(only(pattern('Phone', 300, 250)).priceRise, isNull);
  });

  test('hidden ones go to their own list, active or stopped', () {
    final s = buildSubscriptions(
      [...netflix, ...gym],
      now: now,
      hidden: {'expense|netflix', 'expense|gym'},
    );
    expect(s.active, isEmpty);
    expect(s.stopped, isEmpty);
    expect(s.hidden, hasLength(2));
    expect(s.hidden.first.identity, anyOf('netflix', 'gym'));
  });

  test('Upcoming still sees only the ±14/7-day window', () {
    final all = [...netflix, ...gym];
    expect(
      [for (final h in detectRecurring(all, now: now)) h.label],
      ['Netflix'],
    );
    expect(detectRecurringPatterns(all, now: now), hasLength(2));
    final hit = detectRecurring(netflix, now: now).single;
    expect([for (final h in hit.history) h.amount], [499, 499, 649]);
  });
}
