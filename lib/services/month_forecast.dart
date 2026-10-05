import 'dart:math' as math;

import '../models/reminder.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/dates.dart';
import 'recurring_detector.dart';
import 'reminder_schedule.dart';
import 'safe_to_spend.dart';
import 'upcoming_items.dart';
import 'spend_comparison.dart';

/// "Where will this month end?": what is already spent, the bills still
/// due, and everyday spending for the days left.
///
///   spent so far + bills due + everyday per day x days after today
///
/// Everyday spending leaves bill payments out ([isBillRow]), so a bill is
/// counted once: as spend once paid, as due until then. Spent so far is the
/// figure safe to spend uses (rows waiting for review included), and the
/// bills are the same [billsDue] window.

/// Where the everyday figure came from.
enum EverydayBasis {
  /// The middle of the usual months' everyday spend over the same days.
  usual,

  /// This month's own everyday pace, before enough usual months exist.
  pace,

  /// Too little on record to estimate; the forecast is a floor.
  none,
}

class MonthForecast {
  /// Confirmed spend this month plus rows still waiting for review.
  final double spentSoFar;

  /// The unpaid bills [billsDue] lists, and their sum.
  final List<DueBill> bills;
  final double billsDue;

  /// Everyday spend expected after today; 0 when [basis] is none.
  final double everyday;

  /// [everyday] per day after today.
  final double perDay;

  /// The month's last day less today's day-of-month.
  final int daysAfterToday;

  final EverydayBasis basis;

  /// Months behind a usual estimate; 0 otherwise.
  final int usualMonths;

  /// The monthly cap, null when none is set.
  final double? cap;

  /// The month's last day, for the headline.
  final DateTime lastDay;

  const MonthForecast({
    required this.spentSoFar,
    required this.bills,
    required this.billsDue,
    required this.everyday,
    required this.perDay,
    required this.daysAfterToday,
    required this.basis,
    required this.usualMonths,
    required this.cap,
    required this.lastDay,
  });

  double get total => spentSoFar + billsDue + everyday;

  /// The cap less [total]; negative when the month is heading over it.
  double? get underCap => cap == null ? null : cap! - total;
}

/// Whether [t] is a bill payment: a row of a pattern whose bill this
/// month's forecast already holds ([billKeys], [recurringKeyOf]
/// identities), or a row that pays a reminder by the rule that marks
/// reminders paid: the expected amount to the rupee, dated from 3 days
/// before to 7 days after one of its due dates, and the reminder's category
/// too for a row typed in by hand or an Add it for me reminder (an alert's
/// category is often not the bill's: rent by IMPS lands in Other).
bool isBillRow(Tx t, Set<String> billKeys, List<Reminder> reminders) {
  final key = recurringKeyOf(t);
  if (key != null && billKeys.contains(key)) return true;
  final day = DateTime(t.date.year, t.date.month, t.date.day);
  for (final r in reminders) {
    final expected = r.expectedAmount;
    if (expected == null || (t.amount - expected).abs() >= 1) continue;
    if (isTransferCategory(r.categoryId)) continue;
    if ((r.autoAdd || t.source == TxSource.manual) &&
        r.categoryId != t.categoryId) {
      continue;
    }
    if (reminderDueDatesBetween(
      r,
      day.subtract(const Duration(days: 7)),
      day.add(const Duration(days: 3)),
    ).isNotEmpty) {
      return true;
    }
  }
  return false;
}

/// The forecast for [now]'s month; null on a ledger with no confirmed rows.
/// [cap] <= 0 means no monthly cap.
MonthForecast? computeMonthForecast(
  FinanceProvider finance, {
  required List<RecurringHit> patterns,
  required Set<String> hidden,
  required DateTime now,
  double cap = 0,
}) {
  final first = finance.firstTransactionDate;
  if (first == null) return null;
  final month = DateTime(now.year, now.month);
  final today = DateTime(now.year, now.month, now.day);
  final last = daysInMonth(now.year, now.month);
  final bills = billsDue(
    finance,
    patterns: patterns,
    hidden: hidden,
    from: today.subtract(const Duration(days: 7)),
    to: DateTime(now.year, now.month, last),
    now: now,
  );
  final spent = finance.expenseInMonth(month) + pendingSpendIn(finance, month);
  final daysAfter = last - now.day;

  // A pattern's past payments are bills only while this month's figures
  // already hold its payment: due (in [bills]) or paid this month (in
  // spent so far). Otherwise they are everyday spend: a hidden pattern, or
  // a merchant pinned for one yearly payment that is not due now. Shopped
  // at this month as well, that merchant's rows still read as bills.
  final billKeys = <String>{
    for (final b in bills) ?b.patternKey,
    for (final h in patterns)
      if (h.type == TxType.expense &&
          !hidden.contains(h.key) &&
          ((h.lastDate.year == now.year && h.lastDate.month == now.month) ||
              hitMarkedPaid(finance, h)))
        h.key,
  };
  final reminders = finance.reminders;
  bool everyday(Tx t) =>
      t.type == TxType.expense &&
      !isTransferCategory(t.categoryId) &&
      finance.countsInTotals(t) &&
      !isBillRow(t, billKeys, reminders);

  var basis = EverydayBasis.none;
  var perDay = 0.0;
  var usualMonths = 0;
  // The usual months' everyday spend per day after today's day-of-month.
  // A month too short to have such days (February on the 30th) can't say.
  final perDayUsual = <double>[];
  for (final m in usualWindow(finance, month)) {
    final days = daysInMonth(m.year, m.month) - now.day;
    if (days <= 0) continue;
    var sum = 0.0;
    for (final t in finance.confirmedInMonth(m)) {
      if (t.effectiveDate.day > now.day && everyday(t)) sum += t.spendAmount;
    }
    perDayUsual.add(sum / days);
  }
  if (perDayUsual.length >= kMinUsualMonths) {
    basis = EverydayBasis.usual;
    // The middle of three or more; of two, the lower: their mean would let
    // one big purchase in either month set the whole estimate.
    perDay = perDayUsual.length == 2
        ? math.min(perDayUsual[0], perDayUsual[1])
        : median(perDayUsual);
    usualMonths = perDayUsual.length;
  } else {
    // This month's own days on record, as the Trends pace counts them.
    final paceDays = first.year == now.year && first.month == now.month
        ? (now.day - first.day + 1).clamp(0, now.day)
        : now.day;
    if (paceDays >= kMinDaysOfData) {
      var sum = 0.0;
      for (final t in finance.confirmedInMonth(month)) {
        if (t.effectiveDate.day <= now.day && everyday(t)) {
          sum += t.spendAmount;
        }
      }
      basis = EverydayBasis.pace;
      perDay = sum / paceDays;
    }
  }

  return MonthForecast(
    spentSoFar: spent,
    bills: bills,
    billsDue: bills.fold(0.0, (s, b) => s + b.amount),
    everyday: perDay * daysAfter,
    perDay: perDay,
    daysAfterToday: daysAfter,
    basis: basis,
    usualMonths: usualMonths,
    cap: cap > 0 ? cap : null,
    lastDay: DateTime(now.year, now.month, last),
  );
}
