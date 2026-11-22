/// Date math shared by the card-cycle and upcoming features. Pure Dart.
library;

/// Number of days in [month] of [year] (month may be 0 or 13 — DateTime
/// normalizes, which is exactly what the day-0 trick relies on).
int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// Projections wait until the data behind them covers this many days: with
/// less, one early payment sets a wild pace. A projection divides by the
/// days its data actually covers (up to its usual window), never by a fixed
/// span the data has not reached yet.
const int kMinDaysOfData = 14;

/// Whole calendar days from [from]'s date to [to]'s date, ignoring the clock
/// time of both; negative when [to] is earlier.
///
/// Both dates are rebuilt at UTC midnight before subtracting. Two local
/// midnights can be 23 or 25 hours apart across a daylight-saving change,
/// and `.inDays` on 23 hours gives 0; UTC days are always 24 hours long.
int calendarDaysBetween(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// The same clock time [days] calendar days after [date] (before it when
/// [days] is negative), keeping [date]'s `isUtc`.
///
/// Adding `Duration(days: n)` adds n times 24 hours, which lands an hour off
/// across a daylight-saving change; moving the day field lets the calendar
/// handle month ends and clock changes.
DateTime addCalendarDays(DateTime date, int days) => date.isUtc
    ? DateTime.utc(
        date.year,
        date.month,
        date.day + days,
        date.hour,
        date.minute,
        date.second,
        date.millisecond,
        date.microsecond,
      )
    : DateTime(
        date.year,
        date.month,
        date.day + days,
        date.hour,
        date.minute,
        date.second,
        date.millisecond,
        date.microsecond,
      );

/// Whole days from [start] up to [now], counting both ends (a row dated
/// today covers 1 day).
int daysCovered(DateTime start, DateTime now) =>
    calendarDaysBetween(start, now) + 1;

/// `yyyy-MM` — the month bucket used by reminder dedup markers and by
/// "paid this month" bookkeeping. Sorts correctly as a string.
String monthKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}';

/// The next date whose day-of-month is [day], on or after [from] (compared
/// by calendar date; the returned DateTime is at midnight).
///
/// [day] beyond a month's length clamps to that month's last day, so "due on
/// the 31st" lands on 28/29 Feb and 30 Apr rather than skipping the month.
DateTime nextMonthlyOccurrence(int day, DateTime from) {
  final today = DateTime(from.year, from.month, from.day);
  final thisMonth = DateTime(
    today.year,
    today.month,
    day.clamp(1, daysInMonth(today.year, today.month)),
  );
  if (!thisMonth.isBefore(today)) return thisMonth;
  return DateTime(
    today.year,
    today.month + 1,
    day.clamp(1, daysInMonth(today.year, today.month + 1)),
  );
}
