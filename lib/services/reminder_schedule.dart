import '../models/reminder.dart';
import '../utils/dates.dart';

/// Due-date math for manual reminders. Pure, mirrors the detector's window:
/// a due date up to [kReminderGraceDays] in the past still counts as the
/// current (overdue) one rather than skipping to next month.

const int kReminderGraceDays = 7;

/// The reminder's next due date as of [now] (midnight).
///
/// - This month's occurrence, when [now] is on or before it.
/// - This month's occurrence when it passed 1..7 days ago (overdue).
/// - Otherwise next month's occurrence.
/// A month marked paid ([Reminder.lastPaidMonth]) is skipped entirely.
DateTime reminderNextDue(Reminder r, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final thisMonth = DateTime(
    today.year,
    today.month,
    r.dayOfMonth.clamp(1, daysInMonth(today.year, today.month)),
  );
  final paidThisMonth = r.lastPaidMonth == monthKey(thisMonth);
  final daysPast = today.difference(thisMonth).inDays;
  if (!paidThisMonth && daysPast <= kReminderGraceDays) return thisMonth;
  // Next month (also when this month's due is paid or long gone).
  final next = DateTime(
    today.year,
    today.month + 1,
    r.dayOfMonth.clamp(1, daysInMonth(today.year, today.month + 1)),
  );
  return next;
}

/// Calendar days from [now] to the next due; negative = overdue.
int reminderDaysUntil(Reminder r, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  return reminderNextDue(r, now).difference(today).inDays;
}
