import '../models/reminder.dart';
import '../models/subscription_cycle.dart';
import '../utils/dates.dart';

/// Due-date math for manual reminders. Pure, mirrors the detector's window:
/// a due date up to [kReminderGraceDays] in the past still counts as the
/// current (overdue) one rather than skipping to the next period.

const int kReminderGraceDays = 7;

/// Most occurrences [reminderDueDatesBetween] lists: two years of monthly.
const int kMaxReminderCatchUp = 24;

const _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Short English month name for [month] (1..12).
String reminderMonthName(int month) => _monthNames[(month - 1) % 12];

/// Months counted from year 0, so cycles line up across year ends.
int _index(int year, int month) => year * 12 + month - 1;

bool _aligned(Reminder r, int index) =>
    (index - (r.anchorMonth - 1)) % r.cycle.months == 0;

/// The latest month index at or before [index] this reminder falls in.
int _alignedAtOrBefore(Reminder r, int index) {
  var i = index;
  while (!_aligned(r, i)) {
    i--;
  }
  return i;
}

/// The occurrence in month [index], its day clamped to the month's length.
DateTime _occurrence(Reminder r, int index) {
  final year = index ~/ 12;
  final month = index % 12 + 1;
  return DateTime(year, month, r.dayOfMonth.clamp(1, daysInMonth(year, month)));
}

/// Marked paid, or (for Add it for me) due before it was switched on: that
/// one is never added, so it must not sit in Upcoming as overdue either.
bool _paid(Reminder r, DateTime due) => reminderOccurrenceDone(r, due);

bool _beforeAutoSince(Reminder r, DateTime due) {
  if (!r.autoAdd) return false;
  final since = DateTime.tryParse(r.autoSince ?? '');
  return since != null &&
      due.isBefore(DateTime(since.year, since.month, since.day));
}

/// The reminder's next due date as of [now] (midnight).
///
/// The current period is the latest month the reminder falls in, at or
/// before now's month (always now's month for monthly):
/// - its occurrence, when [now] is on or before it;
/// - its occurrence when it passed 1..7 days ago (overdue);
/// - otherwise the next period's occurrence.
/// A period marked paid ([Reminder.lastPaidMonth]) is skipped entirely.
DateTime reminderNextDue(Reminder r, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final current = _alignedAtOrBefore(r, _index(today.year, today.month));
  final due = _occurrence(r, current);
  final daysPast = today.difference(due).inDays;
  if (!_paid(r, due) && daysPast <= kReminderGraceDays) return due;
  // The next period (also when this one is paid or long gone); one already
  // marked paid in advance moves one more step.
  var next = current + r.cycle.months;
  var nextDue = _occurrence(r, next);
  for (var i = 0; i < kMaxReminderCatchUp && _paid(r, nextDue); i++) {
    next += r.cycle.months;
    nextDue = _occurrence(r, next);
  }
  return nextDue;
}

/// A month before the one the reminder was made in: a reminder made on 4
/// October for a bill due on the 30th never lists 30 September as overdue.
/// An earlier day of its own month still counts: that bill may be unpaid.
bool _beforeCreated(Reminder r, DateTime due) {
  final made = DateTime.tryParse(r.createdOn ?? '');
  return made != null && due.isBefore(DateTime(made.year, made.month));
}

/// Whether the occurrence due on [due] needs nothing more: marked paid (or
/// a later one is), due in a month before the reminder was made, or, for
/// Add it for me, due before it was switched on.
bool reminderOccurrenceDone(Reminder r, DateTime due) {
  final paid = r.lastPaidMonth;
  return (paid != null && paid.compareTo(monthKey(due)) >= 0) ||
      _beforeCreated(r, due) ||
      _beforeAutoSince(r, due);
}

/// Whether the current period's occurrence (this month's for monthly, the
/// latest quarter or year month otherwise) is marked paid.
bool reminderPaidThisPeriod(Reminder r, DateTime now) {
  final current = _alignedAtOrBefore(r, _index(now.year, now.month));
  final due = _occurrence(r, current);
  final paid = r.lastPaidMonth;
  // Not [_beforeCreated]: a quarterly reminder made after its quarter's
  // month was not paid, it just was not due.
  return (paid != null && paid.compareTo(monthKey(due)) >= 0) ||
      _beforeAutoSince(r, due);
}

/// Calendar days from [now] to the next due; negative = overdue.
int reminderDaysUntil(Reminder r, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  return reminderNextDue(r, now).difference(today).inDays;
}

/// Every occurrence of [r] on a date from [from] through [to] (calendar
/// dates, both ends included), oldest first, at most [kMaxReminderCatchUp].
List<DateTime> reminderDueDatesBetween(Reminder r, DateTime from, DateTime to) {
  final start = DateTime(from.year, from.month, from.day);
  final end = DateTime(to.year, to.month, to.day);
  final out = <DateTime>[];
  if (end.isBefore(start)) return out;
  var i = _alignedAtOrBefore(r, _index(start.year, start.month));
  final last = _index(end.year, end.month);
  while (i <= last && out.length < kMaxReminderCatchUp) {
    final d = _occurrence(r, i);
    if (!d.isBefore(start) && !d.isAfter(end)) out.add(d);
    i += r.cycle.months;
  }
  return out;
}

/// "Monthly, day 5", "Quarterly, day 5 of Jan, Apr, Jul, Oct" or
/// "Yearly, 5 Mar".
String reminderCycleLabel(Reminder r) => switch (r.cycle) {
  SubscriptionCycle.monthly => 'Monthly, day ${r.dayOfMonth}',
  SubscriptionCycle.quarterly =>
    'Quarterly, day ${r.dayOfMonth} of ${quarterMonthsLabel(r.anchorMonth)}',
  SubscriptionCycle.yearly =>
    'Yearly, ${r.dayOfMonth} ${reminderMonthName(r.anchorMonth)}',
};

/// The four months a quarterly reminder anchored on [anchorMonth] falls
/// in, in calendar order: "Jan, Apr, Jul, Oct".
String quarterMonthsLabel(int anchorMonth) {
  final months = [for (var k = 0; k < 4; k++) (anchorMonth - 1 + 3 * k) % 12]
    ..sort();
  return months.map((m) => _monthNames[m]).join(', ');
}
