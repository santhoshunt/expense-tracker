import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/services/reminder_schedule.dart';
import 'package:expense_tracker/utils/dates.dart';

void main() {
  Reminder r({int day = 5, String? paid, double? amount}) => Reminder(
    id: 'r1',
    name: 'Money to home',
    dayOfMonth: day,
    categoryId: 'other_expense',
    expectedAmount: amount,
    lastPaidMonth: paid,
  );

  group('reminderNextDue', () {
    test('before the due day → this month', () {
      expect(reminderNextDue(r(), DateTime(2026, 9, 2)), DateTime(2026, 9, 5));
      expect(reminderDaysUntil(r(), DateTime(2026, 9, 2)), 3);
    });

    test('on the due day → today', () {
      expect(reminderDaysUntil(r(), DateTime(2026, 9, 5, 18)), 0);
    });

    test('1..7 days past → still this month, overdue', () {
      expect(reminderNextDue(r(), DateTime(2026, 9, 12)), DateTime(2026, 9, 5));
      expect(reminderDaysUntil(r(), DateTime(2026, 9, 12)), -7);
    });

    test('8+ days past → next month', () {
      expect(
        reminderNextDue(r(), DateTime(2026, 9, 13)),
        DateTime(2026, 10, 5),
      );
    });

    test('marked paid this month → next month even before the day', () {
      final paid = r(paid: monthKey(DateTime(2026, 9)));
      expect(
        reminderNextDue(paid, DateTime(2026, 9, 2)),
        DateTime(2026, 10, 5),
      );
      // Paid last month has no effect on this month.
      final old = r(paid: monthKey(DateTime(2026, 8)));
      expect(reminderNextDue(old, DateTime(2026, 9, 2)), DateTime(2026, 9, 5));
    });

    test('day 31 clamps to short months', () {
      expect(
        reminderNextDue(r(day: 31), DateTime(2026, 2, 10)),
        DateTime(2026, 2, 28),
      );
      // Past the grace window in February → March 31.
      expect(
        reminderNextDue(r(day: 31), DateTime(2026, 3, 8)),
        DateTime(2026, 3, 31),
      );
    });

    test('last month\'s unpaid occurrence stays due into a new month', () {
      // Day 30: on 2 Nov, 30 Oct is 3 days overdue, not 30 Nov.
      expect(
        reminderNextDue(r(day: 30), DateTime(2026, 11, 2)),
        DateTime(2026, 10, 30),
      );
      expect(reminderDaysUntil(r(day: 30), DateTime(2026, 11, 2)), -3);
      // The 7th day past still counts; the 8th moves on.
      expect(
        reminderNextDue(r(day: 30), DateTime(2026, 10, 7)),
        DateTime(2026, 9, 30),
      );
      expect(
        reminderNextDue(r(day: 30), DateTime(2026, 10, 8)),
        DateTime(2026, 10, 30),
      );
    });

    test('day 31 after February and across the year end', () {
      expect(
        reminderNextDue(r(day: 31), DateTime(2026, 3, 1)),
        DateTime(2026, 2, 28),
      );
      expect(
        reminderNextDue(r(day: 31), DateTime(2028, 3, 1)),
        DateTime(2028, 2, 29),
      );
      expect(
        reminderNextDue(r(day: 31), DateTime(2027, 1, 3)),
        DateTime(2026, 12, 31),
      );
      expect(
        reminderNextDue(r(day: 31), DateTime(2027, 1, 8)),
        DateTime(2027, 1, 31),
      );
    });

    test('a paid or pre-creation previous occurrence is skipped', () {
      expect(
        reminderNextDue(r(day: 30, paid: '2026-10'), DateTime(2026, 11, 2)),
        DateTime(2026, 11, 30),
      );
      const madeThisMonth = Reminder(
        id: 'r2',
        name: 'Money to home',
        dayOfMonth: 30,
        categoryId: 'other_expense',
        createdOn: '2026-11-01',
      );
      expect(
        reminderNextDue(madeThisMonth, DateTime(2026, 11, 2)),
        DateTime(2026, 11, 30),
      );
    });
  });

  group('reminderPaidThisPeriod in the first week of a month', () {
    final nov2 = DateTime(2026, 11, 2);

    test('last month\'s overdue occurrence is the one in view', () {
      // Unpaid: Upcoming shows 30 Oct overdue, and it is not paid.
      expect(reminderPaidThisPeriod(r(day: 30), nov2), isFalse);
      // Marked paid on 2 Nov: Upcoming moves to 30 Nov, and the Cockpit
      // reads paid, with Mark unpaid in reach.
      final marked = r(day: 30, paid: '2026-10');
      expect(reminderNextDue(marked, nov2), DateTime(2026, 11, 30));
      expect(reminderPaidThisPeriod(marked, nov2), isTrue);
      // Mark unpaid steps the mark back a month: 30 Oct is due again.
      final unmarked = r(day: 30, paid: '2026-09');
      expect(reminderPaidThisPeriod(unmarked, nov2), isFalse);
      expect(reminderNextDue(unmarked, nov2), DateTime(2026, 10, 30));
      // Past the grace week, November is the period in view.
      expect(reminderPaidThisPeriod(marked, DateTime(2026, 11, 8)), isFalse);
    });

    test('day 31 after February and across the year end', () {
      final feb = r(day: 31, paid: '2027-02');
      expect(reminderPaidThisPeriod(feb, DateTime(2027, 3, 1)), isTrue);
      expect(reminderPaidThisPeriod(feb, DateTime(2027, 3, 8)), isFalse);
      final dec = r(day: 31, paid: '2026-12');
      expect(reminderPaidThisPeriod(dec, DateTime(2027, 1, 3)), isTrue);
      expect(reminderPaidThisPeriod(dec, DateTime(2027, 1, 8)), isFalse);
    });

    test('an occurrence that was never due stays out of view', () {
      // Made on 1 Nov: 30 Oct was never due, so November is in view.
      const made = Reminder(
        id: 'r3',
        name: 'Money to home',
        dayOfMonth: 30,
        categoryId: 'other_expense',
        createdOn: '2026-11-01',
      );
      expect(reminderPaidThisPeriod(made, nov2), isFalse);
      // Add it for me switched on 2 Nov: 30 Oct does not read as paid.
      const auto = Reminder(
        id: 'r4',
        name: 'Money to home',
        dayOfMonth: 30,
        categoryId: 'other_expense',
        expectedAmount: 500,
        autoAdd: true,
        autoSince: '2026-11-02',
      );
      expect(reminderPaidThisPeriod(auto, nov2), isFalse);
    });
  });

  group('Reminder json', () {
    test('round-trips and omits nulls', () {
      final full = r(amount: 5000, paid: '2026-09').toJson();
      expect(full['expectedAmount'], 5000);
      expect(full['lastPaidMonth'], '2026-09');
      final bare = r().toJson();
      expect(bare.containsKey('expectedAmount'), isFalse);
      expect(bare.containsKey('lastPaidMonth'), isFalse);
      final back = Reminder.fromJson(full);
      expect(back.name, 'Money to home');
      expect(back.dayOfMonth, 5);
      expect(back.expectedAmount, 5000);
      expect(back.lastPaidMonth, '2026-09');
    });

    test('tolerates bad values: day clamps, bad amount dropped', () {
      final back = Reminder.fromJson({
        'id': 'x',
        'name': 'EB',
        'dayOfMonth': 45,
        'categoryId': 'utilities',
        'expectedAmount': -3,
      });
      expect(back.dayOfMonth, 31);
      expect(back.expectedAmount, isNull);
      expect(Reminder.fromJson({'id': 'y', 'dayOfMonth': 0}).dayOfMonth, 1);
    });

    test('copyWith clear flags', () {
      final x = r(amount: 100, paid: '2026-09');
      final cleared = x.copyWith(
        clearExpectedAmount: true,
        clearLastPaidMonth: true,
      );
      expect(cleared.expectedAmount, isNull);
      expect(cleared.lastPaidMonth, isNull);
      expect(cleared.id, 'r1');
    });
  });
}
