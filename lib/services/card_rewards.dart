import '../models/account.dart';
import '../models/card_rewards.dart';
import '../models/transaction.dart';
import '../utils/dates.dart';
import 'card_bill.dart';

/// A credit card's billing period: [start] is the day after a statement,
/// [end] the next statement day, both at midnight and both inside the
/// cycle. A card with no statement day uses the calendar month.
typedef CardCycle = ({DateTime start, DateTime end});

/// The cycle [now] falls in, or the one [back] cycles before it.
CardCycle cardCycleOf(Account a, DateTime now, {int back = 0}) {
  final today = DateTime(now.year, now.month, now.day);
  final day = a.statementDay;
  if (day == null) {
    final start = DateTime(today.year, today.month - back);
    return (start: start, end: DateTime(start.year, start.month + 1, 0));
  }
  var end = nextMonthlyOccurrence(day, today);
  for (var i = 0; i < back; i++) {
    end = statementBefore(day, end);
  }
  final prev = statementBefore(day, end);
  return (start: DateTime(prev.year, prev.month, prev.day + 1), end: end);
}

/// Whether [date] falls inside [cycle], end day included.
bool inCardCycle(CardCycle cycle, DateTime date) =>
    !date.isBefore(cycle.start) &&
    date.isBefore(DateTime(cycle.end.year, cycle.end.month, cycle.end.day + 1));

/// Whether money out in [categoryId] earns card rewards: anything but a
/// transfer, and Paid for Others, which the bank saw as a purchase.
bool earnsCardRewards(String categoryId) =>
    !isTransferCategory(categoryId) || categoryId == kPaidForOthersCategoryId;

/// One charge a card's rewards apply to: the category it earns in and the
/// amount the bank saw, less refunds.
typedef RewardCharge = ({String categoryId, double amount});

class RewardEstimate {
  /// ₹ for a cashback card, points for a points card, rounded down.
  final double earned;

  /// A group reached its cap this cycle.
  final bool capped;

  /// What [earned] points are worth, on a points card with a value per
  /// point; null otherwise.
  final double? rupees;

  const RewardEstimate({
    required this.earned,
    required this.capped,
    this.rupees,
  });
}

/// What [charges] earn under [r]: each group's earnings summed and held to
/// its cap, the rest at the base rate, the total rounded down as banks do.
RewardEstimate estimateRewards(CardRewards r, Iterable<RewardCharge> charges) {
  final byGroup = <RewardGroup, double>{};
  var base = 0.0;
  for (final c in charges) {
    if (c.amount <= 0) continue;
    final g = r.groupFor(c.categoryId);
    final earn = r.earnOn(c.categoryId, c.amount);
    if (g == null) {
      base += earn;
    } else {
      byGroup[g] = (byGroup[g] ?? 0) + earn;
    }
  }
  // Float noise is forgiven before the cap compare and the rounding down:
  // ten ₹0.10 earnings add up to 0.9999999999999999 in doubles.
  const slack = 1e-6;
  var total = base;
  var capped = false;
  for (final e in byGroup.entries) {
    final cap = e.key.cap;
    if (cap != null && e.value >= cap - slack) {
      capped = true;
      total += cap;
    } else {
      total += e.value;
    }
  }
  final earned = (total + slack).floorToDouble();
  final value = r.pointValue;
  return RewardEstimate(
    earned: earned,
    capped: capped,
    rupees: r.unit == RewardUnit.points && value != null
        ? earned * value
        : null,
  );
}
