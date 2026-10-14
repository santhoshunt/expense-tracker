import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/subscription_cycle.dart';
import 'package:expense_tracker/services/reminder_schedule.dart';

/// One-time reminders: stored as yearly on their date with [Reminder.onDate]
/// set, and due on that date only.
void main() {
  Reminder once(String date, {String? paid}) {
    final d = DateTime.parse(date);
    return Reminder(
      id: 'o1',
      name: 'Passport fee',
      dayOfMonth: d.day,
      categoryId: 'other_expense',
      cycle: SubscriptionCycle.yearly,
      anchorMonth: d.month,
      lastPaidMonth: paid,
      onDate: date,
    );
  }

  group('reminderNextDue', () {
    test('is the date itself, before and after it', () {
      final r = once('2026-10-23');
      expect(reminderNextDue(r, DateTime(2026, 9, 1)), DateTime(2026, 10, 23));
      // A yearly reminder would move on to 2027 here; a once one does not.
      expect(reminderNextDue(r, DateTime(2027, 1, 1)), DateTime(2026, 10, 23));
    });

    test('a paid one keeps its date too', () {
      final r = once('2026-10-23', paid: '2026-10');
      expect(reminderNextDue(r, DateTime(2026, 10, 1)), DateTime(2026, 10, 23));
    });
  });

  group('reminderFinished', () {
    test('marked paid in its month', () {
      expect(
        reminderFinished(
          once('2026-10-23', paid: '2026-10'),
          DateTime(2026, 10, 1),
        ),
        isTrue,
      );
      // Paid for an earlier month only: still open.
      expect(
        reminderFinished(
          once('2026-10-23', paid: '2026-09'),
          DateTime(2026, 10, 1),
        ),
        isFalse,
      );
    });

    test('past the grace window, not before', () {
      final r = once('2026-10-23');
      expect(reminderFinished(r, DateTime(2026, 10, 23)), isFalse);
      expect(reminderFinished(r, DateTime(2026, 10, 30, 23)), isFalse);
      expect(reminderFinished(r, DateTime(2026, 10, 31)), isTrue);
    });

    test('never for a repeating reminder', () {
      const r = Reminder(
        id: 'r1',
        name: 'Rent',
        dayOfMonth: 5,
        categoryId: 'other_expense',
        lastPaidMonth: '2026-10',
      );
      expect(reminderFinished(r, DateTime(2026, 12, 31)), isFalse);
    });
  });

  group('reminderDueDatesBetween', () {
    final r = once('2026-10-23');

    test('lists the date when it lies in the range, both ends included', () {
      expect(
        reminderDueDatesBetween(
          r,
          DateTime(2026, 10, 1),
          DateTime(2026, 10, 31),
        ),
        [DateTime(2026, 10, 23)],
      );
      expect(
        reminderDueDatesBetween(
          r,
          DateTime(2026, 10, 23),
          DateTime(2026, 10, 23),
        ),
        [DateTime(2026, 10, 23)],
      );
    });

    test('lists nothing outside it, and no later years', () {
      expect(
        reminderDueDatesBetween(
          r,
          DateTime(2026, 10, 24),
          DateTime(2027, 12, 31),
        ),
        isEmpty,
      );
      expect(
        reminderDueDatesBetween(
          r,
          DateTime(2026, 1, 1),
          DateTime(2026, 10, 22),
        ),
        isEmpty,
      );
    });
  });

  test('reminderCycleLabel names the date', () {
    expect(reminderCycleLabel(once('2026-10-23')), 'Once, 23 Oct 2026');
    expect(reminderCycleLabel(once('2027-03-05')), 'Once, 5 Mar 2027');
  });

  group('JSON', () {
    test('round trip keeps the date and the yearly fallback', () {
      final json = once('2026-10-23').toJson();
      expect(json['onDate'], '2026-10-23');
      expect(json['cycle'], 'yearly');
      expect(json['anchorMonth'], 10);
      final back = Reminder.fromJson(json);
      expect(back.onDate, '2026-10-23');
      expect(back.isOnce, isTrue);
      expect(back.cycle, SubscriptionCycle.yearly);
      expect(back.dayOfMonth, 23);
    });

    test('a repeating reminder writes no date', () {
      final json = once('2026-10-23').copyWith(clearOnDate: true).toJson();
      expect(json.containsKey('onDate'), isFalse);
    });

    test('an unreadable date is dropped, leaving a yearly reminder', () {
      final json = once('2026-10-23').toJson()..['onDate'] = 'soon';
      final back = Reminder.fromJson(json);
      expect(back.onDate, isNull);
      expect(back.isOnce, isFalse);
      expect(back.cycle, SubscriptionCycle.yearly);
      expect(reminderCycleLabel(back), 'Yearly, 23 Oct');
    });
  });
}
