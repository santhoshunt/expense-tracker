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
