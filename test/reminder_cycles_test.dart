import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/subscription_cycle.dart';
import 'package:expense_tracker/services/reminder_schedule.dart';

/// Quarterly and yearly reminders: which months they fall in, what is due
/// next, and the catch-up list auto-adding walks.
void main() {
  Reminder r({
    SubscriptionCycle cycle = SubscriptionCycle.monthly,
    int anchor = 1,
    int day = 5,
    String? paid,
  }) => Reminder(
    id: 'r1',
    name: 'Insurance',
    dayOfMonth: day,
    categoryId: 'other_expense',
    cycle: cycle,
    anchorMonth: anchor,
    lastPaidMonth: paid,
  );

  group('reminderNextDue with a cycle', () {
    test('quarterly anchored in January: October from late September', () {
      final q = r(cycle: SubscriptionCycle.quarterly);
      expect(reminderNextDue(q, DateTime(2026, 9, 28)), DateTime(2026, 10, 5));
    });

    test('quarterly: overdue within the week, then the next quarter', () {
      final q = r(cycle: SubscriptionCycle.quarterly);
      expect(reminderNextDue(q, DateTime(2026, 7, 9)), DateTime(2026, 7, 5));
      expect(reminderNextDue(q, DateTime(2026, 7, 13)), DateTime(2026, 10, 5));
    });

    test('quarterly in Feb, May, Aug and Nov wraps the year end', () {
      final q = r(cycle: SubscriptionCycle.quarterly, anchor: 2);
      // Feb, May, Aug, Nov.
      expect(reminderNextDue(q, DateTime(2026, 12, 1)), DateTime(2027, 2, 5));
    });

    test('yearly in March: the same day next year once paid', () {
      final y = r(cycle: SubscriptionCycle.yearly, anchor: 3);
      expect(reminderNextDue(y, DateTime(2026, 9, 28)), DateTime(2027, 3, 5));
      final paid = r(
        cycle: SubscriptionCycle.yearly,
        anchor: 3,
        paid: '2027-03',
      );
      expect(reminderNextDue(paid, DateTime(2027, 3, 1)), DateTime(2028, 3, 5));
    });

    test('a short month clamps the day', () {
      final y = r(cycle: SubscriptionCycle.yearly, anchor: 2, day: 31);
      expect(reminderNextDue(y, DateTime(2027, 1, 10)), DateTime(2027, 2, 28));
    });

    test('monthly ignores the anchor', () {
      expect(
        reminderNextDue(r(anchor: 7), DateTime(2026, 9, 2)),
        DateTime(2026, 9, 5),
      );
    });

    test('Add it for me: a due day before it was switched on is done', () {
      final auto = Reminder(
        id: 'r4',
        name: 'Rent',
        dayOfMonth: 5,
        categoryId: 'other_expense',
        expectedAmount: 100,
        autoAdd: true,
        autoSince: '2026-09-08',
      );
      // Not overdue since the 5th: it will never be added.
      expect(
        reminderNextDue(auto, DateTime(2026, 9, 9)),
        DateTime(2026, 10, 5),
      );
      expect(reminderPaidThisPeriod(auto, DateTime(2026, 9, 9)), isTrue);
      expect(reminderOccurrenceDone(auto, DateTime(2026, 9, 5)), isTrue);
      expect(reminderOccurrenceDone(auto, DateTime(2026, 10, 5)), isFalse);
    });

    test('paid this period', () {
      final q = r(cycle: SubscriptionCycle.quarterly, paid: '2026-07');
      expect(reminderPaidThisPeriod(q, DateTime(2026, 9, 1)), isTrue);
      expect(reminderPaidThisPeriod(q, DateTime(2026, 10, 1)), isFalse);
    });
  });

  group('reminderDueDatesBetween', () {
    test('lists aligned dates only, both ends included', () {
      final q = r(cycle: SubscriptionCycle.quarterly);
      expect(
        reminderDueDatesBetween(q, DateTime(2026, 1, 5), DateTime(2026, 10, 5)),
        [
          DateTime(2026, 1, 5),
          DateTime(2026, 4, 5),
          DateTime(2026, 7, 5),
          DateTime(2026, 10, 5),
        ],
      );
    });

    test('nothing before the start day', () {
      expect(
        reminderDueDatesBetween(
          r(),
          DateTime(2026, 9, 6),
          DateTime(2026, 9, 30),
        ),
        isEmpty,
      );
    });

    test('caps the catch-up', () {
      final dates = reminderDueDatesBetween(
        r(),
        DateTime(2020, 1, 1),
        DateTime(2026, 9, 30),
      );
      expect(dates, hasLength(kMaxReminderCatchUp));
      expect(dates.first, DateTime(2020, 1, 5));
    });
  });

  test('labels', () {
    expect(reminderCycleLabel(r()), 'Monthly, day 5');
    expect(
      reminderCycleLabel(r(cycle: SubscriptionCycle.quarterly, anchor: 2)),
      'Quarterly, day 5 of Feb, May, Aug, Nov',
    );
    expect(
      reminderCycleLabel(r(cycle: SubscriptionCycle.yearly, anchor: 3)),
      'Yearly, 5 Mar',
    );
  });

  test('JSON keeps the cycle, the auto-add and the account', () {
    final full = Reminder(
      id: 'r2',
      name: 'Rent',
      dayOfMonth: 1,
      categoryId: 'other_expense',
      expectedAmount: 18000,
      cycle: SubscriptionCycle.quarterly,
      anchorMonth: 2,
      autoAdd: true,
      accountId: 'acct_1',
      autoSince: '2026-09-28',
    );
    final back = Reminder.fromJson(full.toJson());
    expect(back.cycle, SubscriptionCycle.quarterly);
    expect(back.anchorMonth, 2);
    expect(back.autoAdd, isTrue);
    expect(back.accountId, 'acct_1');
    expect(back.autoSince, '2026-09-28');
    // An older file: monthly, not auto-adding.
    final old = Reminder.fromJson({
      'id': 'r3',
      'name': 'EB',
      'dayOfMonth': 9,
      'categoryId': 'other_expense',
      'cycle': 'fortnightly',
      'anchorMonth': 40,
    });
    expect(old.cycle, SubscriptionCycle.monthly);
    expect(old.anchorMonth, 12);
    expect(old.autoAdd, isFalse);
    // Monthly reminders write no cycle keys, as before.
    expect(
      Reminder.fromJson(old.toJson()).toJson().containsKey('cycle'),
      isFalse,
    );
  });
}
