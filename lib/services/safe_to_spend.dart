import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/dates.dart';
import 'recurring_detector.dart';
import 'reminder_schedule.dart';
import 'upcoming_items.dart';

/// "Safe to spend today": what the monthly cap still allows per day once
/// the bills still due this month are set aside, less what today already
/// spent.
///
///   (cap - spent before today - bills due) / days left - spent today
///
/// Days left counts today through the month's last day. Spend is money out
/// without transfers, the figure the budget card uses, plus rows still
/// waiting for review: an imported alert is money already gone, and it may
/// be what marked a bill paid.
class SafeToSpend {
  /// Today's allowance less today's spend; negative once today overspends.
  final double leftToday;

  /// What each remaining day may spend, today included.
  final double dailyAllowance;

  /// The cap less this month's spend (today's too) and the bills due.
  final double remainingAfterToday;

  final double billsDue;

  /// Spend this month other than today's (rows dated later in the month
  /// included), and today's.
  final double spentBeforeToday;
  final double spentToday;

  /// The cap it was worked out against.
  final double cap;

  /// Today through the month's last day.
  final int daysLeft;

  /// Day of the month [daysLeft] counts from.
  final int today;

  const SafeToSpend({
    required this.leftToday,
    required this.dailyAllowance,
    required this.remainingAfterToday,
    required this.billsDue,
    required this.spentBeforeToday,
    required this.spentToday,
    required this.cap,
    required this.daysLeft,
    required this.today,
  });

  /// Spend and the bills due together pass the cap: nothing is left.
  bool get over => remainingAfterToday < 0;

  /// Spend alone passes the cap.
  bool get overCap => spentBeforeToday + spentToday > cap;

  /// The allowance on day-of-month [day], later this month, if nothing more
  /// is spent before it; null outside tomorrow..the last day.
  double? allowanceOn(int day) {
    final last = today + daysLeft - 1;
    if (day <= today || day > last) return null;
    return remainingAfterToday / (last - day + 1);
  }
}

/// Null without a cap ([cap] <= 0).
///
/// Bills are what is still due from a week ago (the overdue grace, into last
/// month too) to the month's end: each reminder occurrence not yet paid, and each detected
/// payment in [patterns] ([detectRecurringPatterns], not the Upcoming list,
/// which only looks one or two weeks ahead) that is not hidden and not
/// already a reminder. Card bills are left out (the card's spending is in
/// this month's spend already) and so are transfers (the cap does not
/// cover them).
SafeToSpend? computeSafeToSpend(
  FinanceProvider finance, {
  required double cap,
  required List<RecurringHit> patterns,
  required Set<String> hidden,
  required DateTime now,
}) {
  if (cap <= 0) return null;
  final today = DateTime(now.year, now.month, now.day);
  final month = DateTime(now.year, now.month);
  final last = daysInMonth(now.year, now.month);
  final monthEnd = DateTime(now.year, now.month, last);
  // Bills overdue up to a week count too, last month's included: their
  // payment lands in this month's spend.
  final from = today.subtract(const Duration(days: 7));

  var bills = 0.0;
  for (final r in finance.reminders) {
    final amount = r.expectedAmount;
    if (amount == null || isTransferCategory(r.categoryId)) continue;
    for (final due in reminderDueDatesBetween(r, from, monthEnd)) {
      if (!reminderOccurrenceDone(r, due)) bills += amount;
    }
  }
  // Alerts waiting for review already count as spend below; a detected
  // payment one of them made is not due any more.
  final pendingKeys = <String, DateTime>{};
  for (final t in finance.pendingTransactions) {
    if (t.suspectedSpam) continue;
    final key = recurringKeyOf(t);
    if (key == null) continue;
    final seen = pendingKeys[key];
    if (seen == null || t.date.isAfter(seen)) pendingKeys[key] = t.date;
  }
  for (final h in patterns) {
    if (h.type != TxType.expense || hidden.contains(h.key)) continue;
    if (isTransferCategory(h.categoryId)) continue;
    final due = DateTime(h.nextDue.year, h.nextDue.month, h.nextDue.day);
    if (due.isBefore(from) || due.isAfter(monthEnd)) continue;
    final paidPending = pendingKeys[h.key];
    if (paidPending != null && paidPending.isAfter(h.lastDate)) continue;
    // Counted once, as its reminder, when that reminder is counted above.
    if (finance.reminders.any(
      (r) =>
          r.expectedAmount != null &&
          !isTransferCategory(r.categoryId) &&
          reminderCoversHit(r, h, now),
    )) {
      continue;
    }
    bills += h.expectedAmount;
  }
  bool spend(Tx t) =>
      t.type == TxType.expense &&
      !t.suspectedSpam &&
      !isTransferCategory(t.categoryId);
  var pendingMonth = 0.0;
  var pendingToday = 0.0;
  for (final t in finance.pendingTransactions) {
    if (!spend(t) || t.date.year != now.year || t.date.month != now.month) {
      continue;
    }
    pendingMonth += t.spendAmount;
    if (t.date.day == now.day) pendingToday += t.spendAmount;
  }
  final todaySpent = finance.spendOnDay(now).spent + pendingToday;
  final monthSpent = finance.expenseInMonth(month) + pendingMonth;
  final before = monthSpent - todaySpent;
  final daysLeft = last - now.day + 1;
  final daily = (cap - before - bills) / daysLeft;
  return SafeToSpend(
    leftToday: daily - todaySpent,
    dailyAllowance: daily,
    remainingAfterToday: cap - monthSpent - bills,
    billsDue: bills,
    spentBeforeToday: before,
    spentToday: todaySpent,
    cap: cap,
    daysLeft: daysLeft,
    today: now.day,
  );
}
