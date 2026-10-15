import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/subscription_cycle.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/big_bills.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/services/reminder_schedule.dart';

/// Big bills ahead: which reminders and marked merchants count, the
/// monthly figure, the 12-month strip, and the half-yearly cycle it needs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  // A fixed day, so no month rollover changes what falls due.
  final now = DateTime(2026, 10, 15);

  var seq = 0;

  /// A reminder with no createdOn: made "long ago", so no occurrence counts
  /// as before it was made.
  Reminder reminder({
    required String name,
    SubscriptionCycle cycle = SubscriptionCycle.yearly,
    int anchor = 1,
    int day = 5,
    double? amount,
    String categoryId = 'other_expense',
    String? onDate,
  }) => Reminder(
    id: 'r${seq++}',
    name: name,
    dayOfMonth: day,
    categoryId: categoryId,
    expectedAmount: amount,
    cycle: cycle,
    anchorMonth: anchor,
    onDate: onDate,
  );

  RecurringHit hit({
    required String key,
    required DateTime nextDue,
    double amount = 1000,
    SubscriptionCycle? cycle = SubscriptionCycle.yearly,
    TxType type = TxType.expense,
    String categoryId = 'other_expense',
  }) => RecurringHit(
    key: key,
    label: key.substring(key.indexOf('|') + 1),
    categoryId: categoryId,
    type: type,
    expectedAmount: amount,
    lastDate: DateTime(nextDue.year - 1, nextDue.month, nextDue.day),
    intervalDays: (cycle ?? SubscriptionCycle.monthly).approxDays,
    nextDue: nextDue,
    cycle: cycle,
  );

  Future<FinanceProvider> withReminders(List<Reminder> rs) async {
    final p = FinanceProvider();
    await p.load();
    for (final r in rs) {
      await p.restoreReminder(r);
    }
    return p;
  }

  BigBillsPlan plan(
    FinanceProvider p, {
    List<RecurringHit> patterns = const [],
    Set<String> hidden = const {},
  }) => buildBigBillsPlan(p, patterns: patterns, hidden: hidden, now: now);

  double dueIn(BigBillsPlan plan, int year, int month) =>
      plan.months.firstWhere((e) => e.month == DateTime(year, month)).due;

  group('review fixes', () {
    test('a one-time reminder matching a marked yearly merchant does not '
        'hide the bill', () async {
      // Same amount, category and day: reminderCoversHit matches, but the
      // one-time reminder is not a big bill, so the merchant must count.
      final p = await withReminders([
        reminder(
          name: 'Domain',
          anchor: 11,
          day: 20,
          amount: 1000,
          onDate: '2026-11-20',
        ),
      ]);
      final result = plan(
        p,
        patterns: [
          hit(key: 'expense|domain host', nextDue: DateTime(2026, 11, 20)),
        ],
      );
      expect(result.bills, hasLength(1));
      expect(result.bills.single.patternKey, 'expense|domain host');
      expect(dueIn(result, 2026, 11), 1000);
    });

    test('a bill still due from last month counts in this month', () async {
      // Due 28 Sep, today 3 Oct: within the grace days, so it is next.
      final p = await withReminders([
        reminder(name: 'Insurance', anchor: 9, day: 28, amount: 6000),
      ]);
      final result = buildBigBillsPlan(
        p,
        patterns: const [],
        hidden: const {},
        now: DateTime(2026, 10, 3),
      );
      expect(result.bills.single.nextDue, DateTime(2026, 9, 28));
      expect(result.months.first.month, DateTime(2026, 10));
      expect(result.months.first.due, 6000);
    });
  });

  group('which reminders count', () {
    test('only repeating quarterly, half-yearly and yearly ones with an '
        'amount, outside transfers', () async {
      final p = await withReminders([
        reminder(name: 'Insurance', anchor: 3, amount: 12000),
        // One-time: stored as yearly, still left out.
        reminder(
          name: 'Passport',
          anchor: 11,
          day: 20,
          amount: 1500,
          onDate: '2026-11-20',
        ),
        reminder(name: 'Rent', cycle: SubscriptionCycle.monthly, amount: 20000),
        reminder(name: 'Water', cycle: SubscriptionCycle.quarterly),
        reminder(
          name: 'To savings',
          cycle: SubscriptionCycle.quarterly,
          amount: 5000,
          categoryId: kSavingsTransferCategoryId,
        ),
      ]);
      final result = plan(p);
      expect(result.bills.map((b) => b.label), ['Insurance']);
      expect(result.bills.single.reminderId, isNotNull);
      expect(result.bills.single.patternKey, isNull);
      expect(result.bills.single.nextDue, DateTime(2027, 3, 5));
      expect(p.reminders.where(reminderIsBigBill), hasLength(1));
    });

    test('an empty plan has no bills and zero figures', () async {
      final result = plan(await withReminders(const []));
      expect(result.isEmpty, isTrue);
      expect(result.monthly, 0);
      expect(result.yearly, 0);
      expect(result.months, hasLength(12));
      expect(result.months.first.month, DateTime(2026, 10));
      expect(result.months.last.month, DateTime(2027, 9));
      expect(result.months.every((e) => e.due == 0), isTrue);
    });
  });

  group('the monthly figure and the strip', () {
    test('each bill adds amount x 12 / its months / 12; the strip sums '
        'what falls due each month', () async {
      final p = await withReminders([
        // Jan, Apr, Jul, Oct on the 20th: 20 Oct is this month.
        reminder(
          name: 'Maintenance',
          cycle: SubscriptionCycle.quarterly,
          day: 20,
          amount: 3000,
        ),
        // Jan and Jul.
        reminder(
          name: 'School fees',
          cycle: SubscriptionCycle.halfYearly,
          amount: 6000,
        ),
        reminder(name: 'Insurance', anchor: 3, amount: 12000),
      ]);
      final result = plan(p);
      expect(result.monthly, closeTo(3000 / 3 + 6000 / 6 + 12000 / 12, 1e-9));
      expect(result.yearly, closeTo(3000 * 4 + 6000 * 2 + 12000, 1e-9));
      expect(dueIn(result, 2026, 10), 3000);
      expect(dueIn(result, 2026, 11), 0);
      expect(dueIn(result, 2027, 1), 3000 + 6000);
      expect(dueIn(result, 2027, 3), 12000);
      expect(dueIn(result, 2027, 4), 3000);
      expect(dueIn(result, 2027, 7), 3000 + 6000);
      // A full year of every bill: the strip adds up to the yearly cost.
      expect(result.months.fold(0.0, (s, e) => s + e.due), result.yearly);
      // Soonest first.
      expect(result.bills.map((b) => b.label), [
        'Maintenance',
        'School fees',
        'Insurance',
      ]);
    });

    test('a half-yearly reminder falls in its two months', () async {
      final p = await withReminders([
        reminder(
          name: 'Car service',
          cycle: SubscriptionCycle.halfYearly,
          anchor: 4,
          day: 31,
          amount: 4800,
        ),
      ]);
      final result = plan(p);
      final bill = result.bills.single;
      expect(bill.cycle, SubscriptionCycle.halfYearly);
      // April and October: 31 October is still ahead on the 15th.
      expect(bill.nextDue, DateTime(2026, 10, 31));
      expect(bill.monthly, 800);
      expect(dueIn(result, 2026, 10), 4800);
      // 31 April clamps to the 30th.
      expect(dueIn(result, 2027, 4), 4800);
      expect(result.months.where((e) => e.due > 0).map((e) => e.month.month), [
        10,
        4,
      ]);
    });
  });

  group('which marked merchants count', () {
    test('marked quarterly, half-yearly and yearly expenses that are not '
        'hidden, stopped, transfers or covered by a reminder', () async {
      final p = await withReminders([
        reminder(name: 'Club fee', anchor: 12, amount: 5000),
      ]);
      final patterns = [
        hit(key: 'expense|domain', nextDue: DateTime(2027, 2, 10)),
        hit(
          key: 'expense|gym',
          nextDue: DateTime(2026, 11, 10),
          amount: 900,
          cycle: SubscriptionCycle.quarterly,
        ),
        // Spotted, not marked.
        hit(
          key: 'expense|spotted',
          nextDue: DateTime(2026, 11, 1),
          cycle: null,
        ),
        hit(
          key: 'expense|ott',
          nextDue: DateTime(2026, 11, 1),
          cycle: SubscriptionCycle.monthly,
        ),
        hit(key: 'expense|hidden', nextDue: DateTime(2026, 12, 1)),
        hit(
          key: 'income|bonus',
          nextDue: DateTime(2026, 12, 1),
          type: TxType.income,
          categoryId: 'salary',
        ),
        hit(
          key: 'expense|sweep',
          nextDue: DateTime(2026, 12, 1),
          categoryId: kSavingsTransferCategoryId,
        ),
        // Paid 13 months ago on a yearly plan: stopped.
        hit(key: 'expense|lapsed', nextDue: DateTime(2026, 9, 1)),
        // The reminder's own bill: same amount, category and due date.
        hit(key: 'expense|club', nextDue: DateTime(2026, 12, 5), amount: 5000),
      ];
      final result = plan(p, patterns: patterns, hidden: {'expense|hidden'});
      expect(result.bills.map((b) => b.label), ['gym', 'Club fee', 'domain']);
      expect(
        result.bills.firstWhere((b) => b.label == 'domain').patternKey,
        'expense|domain',
      );
      // The club counts once, as the reminder.
      expect(dueIn(result, 2026, 12), 5000);
      // The gym steps a quarter at a time from its next date.
      expect(dueIn(result, 2026, 11), 900);
      expect(dueIn(result, 2027, 2), 900 + 1000);
      expect(dueIn(result, 2027, 5), 900);
      expect(dueIn(result, 2027, 8), 900);
      expect(result.monthly, closeTo(5000 / 12 + 900 / 3 + 1000 / 12, 1e-9));
    });
  });

  group('half-yearly cycle', () {
    test('cycleMonthsLabel lists every month a cycle falls in', () {
      expect(
        cycleMonthsLabel(1, SubscriptionCycle.quarterly),
        'Jan, Apr, Jul, Oct',
      );
      expect(
        cycleMonthsLabel(11, SubscriptionCycle.quarterly),
        'Feb, May, Aug, Nov',
      );
      expect(cycleMonthsLabel(3, SubscriptionCycle.halfYearly), 'Mar and Sep');
      expect(cycleMonthsLabel(7, SubscriptionCycle.halfYearly), 'Jan and Jul');
      expect(cycleMonthsLabel(3, SubscriptionCycle.yearly), 'Mar');
    });

    test('the reminder label names day and both months', () {
      expect(
        reminderCycleLabel(
          reminder(name: 'Fees', cycle: SubscriptionCycle.halfYearly),
        ),
        'Half-yearly, day 5 of Jan and Jul',
      );
      expect(
        reminderCycleLabel(
          reminder(name: 'Fees', cycle: SubscriptionCycle.quarterly, anchor: 2),
        ),
        'Quarterly, day 5 of Feb, May, Aug, Nov',
      );
    });

    test('next due steps six months, overdue within the week', () {
      final r = reminder(
        name: 'Fees',
        cycle: SubscriptionCycle.halfYearly,
        anchor: 4,
        day: 10,
      );
      expect(
        reminderNextDue(r, DateTime(2026, 10, 15)),
        DateTime(2026, 10, 10),
      );
      expect(reminderNextDue(r, DateTime(2026, 10, 20)), DateTime(2027, 4, 10));
      expect(reminderNextDue(r, DateTime(2026, 5, 1)), DateTime(2026, 10, 10));
      expect(
        SubscriptionCycle.halfYearly.nextAfter(DateTime(2026, 8, 31)),
        DateTime(2027, 2, 28),
      );
    });

    test('a half-yearly reminder survives a JSON round trip', () {
      final r = reminder(
        name: 'Fees',
        cycle: SubscriptionCycle.halfYearly,
        anchor: 5,
      );
      final back = Reminder.fromJson(r.toJson());
      expect(back.cycle, SubscriptionCycle.halfYearly);
      expect(back.anchorMonth, 5);
    });
  });
}
