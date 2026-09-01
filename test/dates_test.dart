import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/utils/dates.dart';

void main() {
  group('daysInMonth', () {
    test('normal months', () {
      expect(daysInMonth(2026, 1), 31);
      expect(daysInMonth(2026, 4), 30);
      expect(daysInMonth(2026, 12), 31);
    });

    test('February leap and non-leap', () {
      expect(daysInMonth(2026, 2), 28);
      expect(daysInMonth(2028, 2), 29);
    });
  });

  group('nextMonthlyOccurrence', () {
    test('later this month', () {
      expect(
        nextMonthlyOccurrence(15, DateTime(2026, 9, 1)),
        DateTime(2026, 9, 15),
      );
    });

    test('same day counts as due today, time of day ignored', () {
      expect(
        nextMonthlyOccurrence(15, DateTime(2026, 9, 15, 23, 59)),
        DateTime(2026, 9, 15),
      );
    });

    test('already passed rolls to next month', () {
      expect(
        nextMonthlyOccurrence(10, DateTime(2026, 9, 20)),
        DateTime(2026, 10, 10),
      );
    });

    test('December rolls into January', () {
      expect(
        nextMonthlyOccurrence(5, DateTime(2026, 12, 20)),
        DateTime(2027, 1, 5),
      );
    });

    test('day 31 clamps to shorter months instead of skipping them', () {
      // From 1 Apr, "the 31st" lands on 30 Apr — not 31 May.
      expect(
        nextMonthlyOccurrence(31, DateTime(2026, 4, 1)),
        DateTime(2026, 4, 30),
      );
      // From 1 Feb, it lands on 28 Feb (non-leap) / 29 Feb (leap).
      expect(
        nextMonthlyOccurrence(31, DateTime(2026, 2, 1)),
        DateTime(2026, 2, 28),
      );
      expect(
        nextMonthlyOccurrence(31, DateTime(2028, 2, 1)),
        DateTime(2028, 2, 29),
      );
    });

    test('clamped day already passed rolls to the next month clamped', () {
      // 30 Apr has passed → next is 31 May.
      expect(
        nextMonthlyOccurrence(31, DateTime(2026, 4, 30, 0, 1)),
        DateTime(2026, 4, 30),
        reason: 'due today (midnight date compare)',
      );
      expect(
        nextMonthlyOccurrence(31, DateTime(2026, 5, 1)),
        DateTime(2026, 5, 31),
      );
    });
  });
}
