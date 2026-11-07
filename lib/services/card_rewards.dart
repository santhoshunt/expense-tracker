import '../models/account.dart';
import '../models/card_rewards.dart';
import '../models/transaction.dart';
import '../utils/dates.dart';
import 'card_bill.dart';

/// A credit card's billing period: [start] is the day after a statement,
/// [end] the next statement day, both at midnight and both inside the
/// cycle. A card with no statement day uses the calendar month.
typedef CardCycle = ({DateTime start, DateTime end});

/// One card period's spending.
/// - `cycle`: the period's dates.
/// - `back`: the number of periods before the one today falls in.
/// - `spent`: `netSpendOf` over expense rows that are not transfers, by
///   `t.date`.
/// - `payments`: the number of rows summed.
/// - `rewards`: `cardRewardsFor(account, back: back)`.
typedef CardPeriod = ({
  CardCycle cycle,
  int back,
  double spent,
  int payments,
  RewardEstimate? rewards,
});

/// A card's spending window for the tile chart.
/// - `current`: the period today falls in.
/// - `day`: today's day number inside the current cycle, from 1.
/// - `days`: the current cycle's length in days.
/// - `bars`: six periods, oldest first.
/// - `hasOlder`: the card has a row before the first bar.
typedef CardSpendWindow = ({
  CardPeriod current,
  int day,
  int days,
  List<CardPeriod> bars,
  bool hasOlder,
});

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

/// Whether a money-out payment in [categoryIds] (its parts, anchor first)
/// earns: anything but a card bill, unless it is one leg of a transfer pair
/// ([pairId]), a move between the user's own accounts.
bool earnsCardRewards(Iterable<String> categoryIds, {String? pairId}) =>
    pairId == null && categoryIds.any((c) => c != kCardBillCategoryId);

/// Why a payment earns in its reward group ([resolveRewardGroup]).
enum RewardReason { picked, remembered, merchant, category, everythingElse }

/// The group a payment earns in: [group] null means Everything else;
/// [categoryId] is set only for [RewardReason.category].
typedef RewardMatch = ({
  RewardGroup? group,
  RewardReason reason,
  String? categoryId,
});

/// The group a payment earns in under [r], first match wins:
/// 1. [pick], the group picked on the payment;
/// 2. [remembered], the pick made before for its merchant on this card;
/// 3. the first group with a merchant word in [merchant] (whole words);
/// 4. the first group holding one of [categoryIds], in order;
/// 5. Everything else.
///
/// A pick or remembered value that names no group of [r] falls through.
RewardMatch resolveRewardGroup(
  CardRewards r, {
  String? pick,
  String? remembered,
  String? merchant,
  required Iterable<String> categoryIds,
}) {
  for (final (value, reason) in [
    (pick, RewardReason.picked),
    (remembered, RewardReason.remembered),
  ]) {
    if (value == null) continue;
    if (value == kEverythingElseRewardGroupId) {
      return (group: null, reason: reason, categoryId: null);
    }
    if (r.groupById(value) case final g?) {
      return (group: g, reason: reason, categoryId: null);
    }
  }
  if (merchant != null) {
    for (final g in r.groups) {
      if (g.merchantWords.any((w) => ' $merchant '.contains(' $w '))) {
        return (group: g, reason: RewardReason.merchant, categoryId: null);
      }
    }
  }
  for (final c in categoryIds) {
    if (r.groupFor(c) case final g?) {
      return (group: g, reason: RewardReason.category, categoryId: c);
    }
  }
  return (group: null, reason: RewardReason.everythingElse, categoryId: null);
}

/// One charge and the group it earns in (null: Everything else), with the
/// amount the bank saw, less refunds.
typedef RewardCharge = ({RewardGroup? group, double amount});

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
/// A charge under its group's minimum earns nothing.
RewardEstimate estimateRewards(CardRewards r, Iterable<RewardCharge> charges) {
  final byGroup = <RewardGroup, double>{};
  var base = 0.0;
  for (final c in charges) {
    if (c.amount <= 0) continue;
    final g = c.group;
    final earn = r.earnOn(g, c.amount);
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
