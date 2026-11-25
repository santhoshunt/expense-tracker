import '../models/reminder.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/dates.dart';
import 'recurring_detector.dart';
import 'reminder_schedule.dart';
import 'upcoming_items.dart';

/// What the monthly cap still leaves this month once the bills still due
/// are set aside: the Monthly budget card's verdict.
///
///   cap - spent this month - bills due
///
/// Spend is money out without transfers, the figure the budget card uses,
/// plus rows still waiting for review: an imported alert is money already
/// gone, and it may be what marked a bill paid.
class SafeToSpend {
  /// The cap less this month's spend (today's too) and the bills due.
  final double remainingAfterToday;

  final double billsDue;

  /// The bills [billsDue] adds up, for the Due this month sheet.
  final List<DueBill> bills;

  /// Spend this month other than today's (rows dated later in the month
  /// included), and today's.
  final double spentBeforeToday;
  final double spentToday;

  /// The part of that spend on rows still waiting for review, today's
  /// included.
  final double pendingSpent;

  /// The cap it was worked out against.
  final double cap;

  const SafeToSpend({
    required this.remainingAfterToday,
    required this.billsDue,
    required this.bills,
    required this.spentBeforeToday,
    required this.spentToday,
    required this.pendingSpent,
    required this.cap,
  });

  /// This month's spend, waiting rows included, plus the bills due: what
  /// the cap is measured against.
  double get committed => spentBeforeToday + spentToday + billsDue;

  /// Spend and the bills due together pass the cap: nothing is left.
  bool get over => remainingAfterToday < 0;

  /// Spend alone passes the cap.
  bool get overCap => spentBeforeToday + spentToday > cap;
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
/// in [patterns] ([detectRecurringPatterns]) that is not hidden and not
/// already a reminder. Neither counts when an alert still waiting for
/// review paid it, since that alert already counts as spend. Card
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
  // A reminder's payment waiting for review already counts as spend, but
  // marks nothing paid until confirmed: each such row (up to today) takes
  // the first occurrence it could pay, on the rules a confirmed row pays by.
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  final pendingPaid = [
    for (final t in finance.pendingTransactions)
      if (pendingIsSpend(finance, t) && t.date.isBefore(tomorrow)) t,
  ];
  bool paidByPending(Reminder r, DateTime due) {
    if (r.autoAdd) return false;
    for (var i = 0; i < pendingPaid.length; i++) {
      final t = pendingPaid[i];
      final day = DateTime(t.date.year, t.date.month, t.date.day);
      if ((t.amount - r.expectedAmount!).abs() >= 1 ||
          (t.source == TxSource.manual && t.categoryId != r.categoryId) ||
          due.isBefore(addCalendarDays(day, -kReminderGraceDays)) ||
          due.isAfter(addCalendarDays(day, kReminderEarlyPayDays))) {
        continue;
      }
      pendingPaid.removeAt(i);
      return true;
    }
    return false;
  }

  for (final r in finance.reminders) {
    final amount = r.expectedAmount;
    if (amount == null ||
        isTransferCategory(r.categoryId) ||
        reminderIsIncome(r)) {
      continue;
    }
    for (final due in reminderDueDatesBetween(r, start, end)) {
      if (!reminderOccurrenceDone(r, due) && !paidByPending(r, due)) {
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

/// The rows waiting for review that count as spend in [month] (by
/// effective date).
Iterable<Tx> _pendingSpendRows(FinanceProvider finance, DateTime month) =>
    finance.pendingTransactions.where((t) {
      final d = t.effectiveDate;
      return d.year == month.year &&
          d.month == month.month &&
          pendingIsSpend(finance, t);
    });

/// Spend on rows still waiting for review whose effective date is in
/// [month].
double pendingSpendIn(FinanceProvider finance, DateTime month) =>
    _pendingSpendRows(finance, month).fold(0.0, (s, t) => s + t.spendAmount);

/// How many rows [pendingSpendIn] adds up: those with an amount to add (a
/// split the user paid none of adds nothing, so it is not counted).
int pendingSpendCountIn(FinanceProvider finance, DateTime month) =>
    _pendingSpendRows(finance, month).where((t) => t.spendAmount > 0).length;

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
  final dueList = billsDue(
    finance,
    patterns: patterns,
    hidden: hidden,
    from: addCalendarDays(today, -7),
    to: DateTime(now.year, now.month, last),
    now: now,
  );
  final bills = dueList.fold(0.0, (s, b) => s + b.amount);
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
  return SafeToSpend(
    remainingAfterToday: cap - monthSpent - bills,
    billsDue: bills,
    bills: dueList,
    spentBeforeToday: monthSpent - todaySpent,
    spentToday: todaySpent,
    pendingSpent: pendingMonth,
    cap: cap,
  );
}
