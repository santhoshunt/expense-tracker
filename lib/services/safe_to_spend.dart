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

/// One unpaid bill: a reminder occurrence or a detected payment's next date.
class DueBill {
  final DateTime due;
  final String label;
  final double amount;

  /// The detected payment's identity ([RecurringHit.key]); null for a
  /// reminder.
  final String? patternKey;

  /// The reminder's id; null for a detected payment.
  final String? reminderId;
  const DueBill({
    required this.due,
    required this.label,
    required this.amount,
    this.patternKey,
    this.reminderId,
  });
}

/// Unpaid bills due from [from] through [to] (calendar dates), soonest
/// first: each reminder occurrence not yet paid, and each detected payment
/// in [patterns] ([detectRecurringPatterns]) that is not hidden, not paid
/// by an alert still waiting for review, and not already a reminder. Card
/// bills are left out (the card's spending is counted as it happens) and
/// so are transfers (the budget cap does not cover them).
List<DueBill> billsDue(
  FinanceProvider finance, {
  required List<RecurringHit> patterns,
  required Set<String> hidden,
  required DateTime from,
  required DateTime to,
  required DateTime now,
}) {
  final start = DateTime(from.year, from.month, from.day);
  final end = DateTime(to.year, to.month, to.day);
  final out = <DueBill>[];
  for (final r in finance.reminders) {
    final amount = r.expectedAmount;
    if (amount == null || isTransferCategory(r.categoryId)) continue;
    for (final due in reminderDueDatesBetween(r, start, end)) {
      if (!reminderOccurrenceDone(r, due)) {
        out.add(
          DueBill(due: due, label: r.name, amount: amount, reminderId: r.id),
        );
      }
    }
  }
  // An alert waiting for review already counts as spend; the detected
  // payment it made is not due any more.
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
    if (hitMarkedPaid(finance, h)) continue;
    if (isTransferCategory(h.categoryId)) continue;
    final due = DateTime(h.nextDue.year, h.nextDue.month, h.nextDue.day);
    if (due.isBefore(start) || due.isAfter(end)) continue;
    final paidPending = pendingKeys[h.key];
    if (paidPending != null && paidPending.isAfter(h.lastDate)) continue;
    // Listed once, as its reminder, when that reminder is listed above.
    if (finance.reminders.any(
      (r) =>
          r.expectedAmount != null &&
          !isTransferCategory(r.categoryId) &&
          reminderCoversHit(r, h, now),
    )) {
      continue;
    }
    out.add(
      DueBill(
        due: due,
        label: h.label,
        amount: h.expectedAmount,
        patternKey: h.key,
      ),
    );
  }
  out.sort((a, b) => a.due.compareTo(b.due));
  return out;
}

/// Whether a row waiting for review counts as money already spent: an
/// expense, not suspected spam, not a transfer, and counted in totals.
bool pendingIsSpend(FinanceProvider finance, Tx t) =>
    t.type == TxType.expense &&
    !t.suspectedSpam &&
    !isTransferCategory(t.categoryId) &&
    finance.countsInTotals(t);

/// Spend on rows still waiting for review whose effective date is in
/// [month].
double pendingSpendIn(FinanceProvider finance, DateTime month) {
  var sum = 0.0;
  for (final t in finance.pendingTransactions) {
    final d = t.effectiveDate;
    if (d.year != month.year || d.month != month.month) continue;
    if (pendingIsSpend(finance, t)) sum += t.spendAmount;
  }
  return sum;
}

/// Null without a cap ([cap] <= 0).
///
/// Bills are [billsDue] from a week ago (the overdue grace, into last month
/// too: their payment lands in this month's spend) to the month's end.
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
  final bills = billsDue(
    finance,
    patterns: patterns,
    hidden: hidden,
    from: today.subtract(const Duration(days: 7)),
    to: DateTime(now.year, now.month, last),
    now: now,
  ).fold(0.0, (s, b) => s + b.amount);
  var pendingMonth = 0.0;
  var pendingToday = 0.0;
  for (final t in finance.pendingTransactions) {
    final d = t.effectiveDate;
    if (!pendingIsSpend(finance, t) ||
        d.year != now.year ||
        d.month != now.month) {
      continue;
    }
    pendingMonth += t.spendAmount;
    if (d.day == now.day) pendingToday += t.spendAmount;
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
