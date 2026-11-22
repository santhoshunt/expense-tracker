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

  // Tests run in the machine's own zone and cannot switch it. The
  // clock-change cases below hold in every zone: they walk every local day
  // of two years, so on a machine in a zone with daylight saving they cross
  // its real spring-forward and autumn-back nights, and in a zone without
  // one they still check the UTC day arithmetic the helpers are built on.
  group('calendarDaysBetween', () {
    test('ignores the clock time of both ends', () {
      expect(
        calendarDaysBetween(
          DateTime(2026, 3, 10, 23, 59),
          DateTime(2026, 3, 11, 0, 1),
        ),
        1,
      );
      expect(
        calendarDaysBetween(
          DateTime(2026, 3, 10, 0, 1),
          DateTime(2026, 3, 10, 23, 59),
        ),
        0,
      );
    });

    test('negative when to is earlier', () {
      expect(
        calendarDaysBetween(DateTime(2026, 3, 11), DateTime(2026, 3, 1)),
        -10,
      );
    });

    test('across month, year and leap-day ends', () {
      expect(
        calendarDaysBetween(DateTime(2026, 1, 31), DateTime(2026, 3, 1)),
        29,
      );
      expect(
        calendarDaysBetween(DateTime(2028, 2, 28), DateTime(2028, 3, 1)),
        2,
      );
      expect(
        calendarDaysBetween(DateTime(2026, 12, 31), DateTime(2027, 1, 1)),
        1,
      );
      expect(
        calendarDaysBetween(DateTime(2026, 1, 1), DateTime(2027, 1, 1)),
        365,
      );
    });

    test('every local midnight to the next is one day, 30 apart is 30', () {
      // Covers 8 Mar and 1 Nov 2026 (spring-forward and autumn-back in
      // North America) and 29 Mar and 25 Oct 2026 (in Europe), where two
      // local midnights can be 23 or 25 hours apart.
      for (var i = 0; i < 730; i++) {
        final day = DateTime(2026, 1, 1 + i);
        final next = DateTime(2026, 1, 2 + i);
        final later = DateTime(2026, 1, 31 + i, 9);
        expect(calendarDaysBetween(day, next), 1, reason: '$day');
        expect(calendarDaysBetween(next, day), -1, reason: '$day');
        expect(calendarDaysBetween(day, later), 30, reason: '$day');
      }
    });

    test('UTC inputs use their own date fields', () {
      expect(
        calendarDaysBetween(
          DateTime.utc(2026, 3, 8, 23),
          DateTime.utc(2026, 3, 9, 1),
        ),
        1,
      );
    });
  });

  group('addCalendarDays', () {
    test('keeps the clock time and moves the date', () {
      expect(
        addCalendarDays(DateTime(2026, 3, 7, 14, 30, 5, 6, 7), 1),
        DateTime(2026, 3, 8, 14, 30, 5, 6, 7),
      );
    });

    test('negative days move earlier', () {
      expect(
        addCalendarDays(DateTime(2026, 3, 1, 8), -1),
        DateTime(2026, 2, 28, 8),
      );
    });

    test('rolls across month, year and leap-day ends', () {
      expect(addCalendarDays(DateTime(2026, 1, 31), 1), DateTime(2026, 2, 1));
      expect(addCalendarDays(DateTime(2028, 2, 28), 1), DateTime(2028, 2, 29));
      expect(
        addCalendarDays(DateTime(2026, 12, 31, 23, 59), 1),
        DateTime(2027, 1, 1, 23, 59),
      );
      expect(addCalendarDays(DateTime(2026, 1, 1), 365), DateTime(2027, 1, 1));
    });

    test('every local day keeps its clock time a day and a week on', () {
      // As above, this walk crosses the zone's own clock-change nights,
      // where adding 24 hours would land an hour off.
      for (var i = 0; i < 730; i++) {
        final start = DateTime(2026, 1, 1 + i, 10, 15);
        final next = addCalendarDays(start, 1);
        final weekBack = addCalendarDays(start, -7);
        expect(next, DateTime(2026, 1, 2 + i, 10, 15), reason: '$start');
        expect(weekBack, DateTime(2026, 1, i - 6, 10, 15), reason: '$start');
        expect(next.isUtc, isFalse);
        expect(calendarDaysBetween(weekBack, next), 8, reason: '$start');
      }
    });

    test('keeps isUtc for a UTC date', () {
      final d = addCalendarDays(DateTime.utc(2026, 3, 8, 1, 2), 3);
      expect(d.isUtc, isTrue);
      expect(d, DateTime.utc(2026, 3, 11, 1, 2));
    });

    test('zero days returns the same moment', () {
      final d = DateTime(2026, 3, 8, 6, 7);
      expect(addCalendarDays(d, 0), d);
    });
  });

  group('daysCovered', () {
    test('counts both ends', () {
      expect(daysCovered(DateTime(2026, 3, 8, 22), DateTime(2026, 3, 8, 1)), 1);
      expect(daysCovered(DateTime(2026, 3, 1), DateTime(2026, 3, 14, 23)), 14);
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
