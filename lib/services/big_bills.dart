import '../models/reminder.dart';
import '../models/subscription_cycle.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import 'recurring_detector.dart';
import 'reminder_schedule.dart';
import 'subscriptions.dart' show kSubscriptionGraceDays;
import 'upcoming_items.dart' show hitMarkedPaid, reminderCoversHit;

/// One quarterly, half-yearly or yearly bill the planner spreads.
class BigBill {
  final String label;
  final String categoryId;

  /// One payment.
  final double amount;

  /// Never monthly.
  final SubscriptionCycle cycle;
  final DateTime nextDue;

  /// Set for a reminder.
  final String? reminderId;

  /// Set for a marked subscription.
  final String? patternKey;

  const BigBill({
    required this.label,
    required this.categoryId,
    required this.amount,
    required this.cycle,
    required this.nextDue,
    this.reminderId,
    this.patternKey,
  });

  /// What it costs over a year: 4, 2 or 1 payments.
  double get yearly => cycle.yearlyCost(amount);

  /// Its even share of a month, the yearly cost over 12.
  double get monthly => yearly / 12;
}

/// The Big bills ahead card and sheet: every big bill, the monthly figure to
/// set aside, and what falls due in each of the next 12 months.
class BigBillsPlan {
  /// Soonest first.
  final List<BigBill> bills;

  /// The sum of the bills' [BigBill.monthly].
  final double monthly;
  final double yearly;

  /// 12 entries from the current month: what falls due in each.
  final List<({DateTime month, double due})> months;

  const BigBillsPlan({
    required this.bills,
    required this.monthly,
    required this.yearly,
    required this.months,
  });

  bool get isEmpty => bills.isEmpty;
}

/// Whether reminder [r] is a big bill: repeating every 3, 6 or 12 months,
/// with an amount, and not a move between your own accounts. A one-time
/// reminder (stored as yearly) and a monthly one never are; an amount-less
/// one is left out as safe to spend leaves it out.
bool reminderIsBigBill(Reminder r) =>
    !r.isOnce &&
    r.cycle != SubscriptionCycle.monthly &&
    r.expectedAmount != null &&
    !isTransferCategory(r.categoryId);

/// Builds the plan as of [now] from [finance]'s reminders and the marked
/// quarterly, half-yearly and yearly merchants in [patterns] whose keys are
/// not in [hidden]. A merchant a reminder already stands for
/// ([reminderCoversHit]) counts once, as the reminder.
BigBillsPlan buildBigBillsPlan(
  FinanceProvider finance, {
  required List<RecurringHit> patterns,
  required Set<String> hidden,
  required DateTime now,
}) {
  final start = DateTime(now.year, now.month);
  // The last day of the 12th month, this one included.
  final end = DateTime(now.year, now.month + 12, 0);
  final bills = <BigBill>[];
  final due = List<double>.filled(12, 0);

  // Into its month's slot. A bill still due from before this month (in its
  // grace days) goes into this month's: the card lists it as next, so the
  // strip must show it too.
  void addDue(DateTime d, double amount) {
    final k = (d.year - start.year) * 12 + d.month - start.month;
    if (k >= 12) return;
    due[k < 0 ? 0 : k] += amount;
  }

  for (final r in finance.reminders) {
    if (!reminderIsBigBill(r)) continue;
    final amount = r.expectedAmount!;
    final next = reminderNextDue(r, now);
    bills.add(
      BigBill(
        label: r.name,
        categoryId: r.categoryId,
        amount: amount,
        cycle: r.cycle,
        nextDue: next,
        reminderId: r.id,
      ),
    );
    if (next.isBefore(start)) addDue(next, amount);
    // Paid ones too: the strip shows what falls due, not what is left.
    for (final d in reminderDueDatesBetween(r, start, end)) {
      addDue(d, amount);
    }
  }

  for (final h in patterns) {
    final cycle = h.cycle;
    if (cycle == null || cycle == SubscriptionCycle.monthly) continue;
    if (h.type != TxType.expense || hidden.contains(h.key)) continue;
    if (isTransferCategory(h.categoryId)) continue;
    // Stopped, as the Subscriptions list reads it: a stepped date would
    // otherwise land in the window and count a plan no longer paid.
    if (h.daysUntil(now) < -kSubscriptionGraceDays) continue;
    // Only a reminder this plan lists stands for it: a one-time or monthly
    // reminder that happens to match would leave the bill counted nowhere.
    if (finance.reminders.any(
      (r) => reminderIsBigBill(r) && reminderCoversHit(r, h, now),
    )) {
      continue;
    }
    final expected = DateTime(h.nextDue.year, h.nextDue.month, h.nextDue.day);
    // Marked paid by hand: next is the one after, as a paid reminder's is.
    final next = hitMarkedPaid(finance, h)
        ? cycle.nextAfter(expected)
        : expected;
    bills.add(
      BigBill(
        label: h.label,
        categoryId: h.categoryId,
        amount: h.expectedAmount,
        cycle: cycle,
        nextDue: next,
        patternKey: h.key,
      ),
    );
    for (var d = expected; !d.isAfter(end); d = cycle.nextAfter(d)) {
      if (!d.isBefore(start) || d == next) addDue(d, h.expectedAmount);
    }
  }

  bills.sort((a, b) {
    final byDate = a.nextDue.compareTo(b.nextDue);
    return byDate != 0 ? byDate : a.label.compareTo(b.label);
  });
  final yearly = bills.fold(0.0, (s, b) => s + b.yearly);
  final months = [
    for (var i = 0; i < 12; i++)
      (month: DateTime(start.year, start.month + i), due: due[i]),
  ];
  return BigBillsPlan(
    bills: bills,
    monthly: bills.fold(0.0, (s, b) => s + b.monthly),
    yearly: yearly,
    months: months,
  );
}
