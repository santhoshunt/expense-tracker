import '../models/transaction.dart';
import '../utils/dates.dart';

/// Savings-goal projection math. Pure — the account card feeds it
/// `transactionsForAccount` rows and the derived balance.

/// Signed movement of [t] as seen by a SAVINGS account — replicates the
/// `invertTransfers` rule in FinanceProvider's balance math: a transfer
/// debited elsewhere ("To savings") is a deposit here (+), a transfer
/// credited elsewhere is a withdrawal here (−); non-transfer rows (interest
/// income, fees) keep their natural sign.
///
/// A PAIRED leg is exempt: its own bank alert ("credited to RD") already
/// carries the savings-side direction, so inverting it would turn the
/// deposit into a withdrawal. Keep in step with `_computeFigures`.
double signedForSavings(Tx t) {
  final v = t.type == TxType.income ? t.amount : -t.amount;
  return isTransferCategory(t.categoryId) && t.pairId == null ? -v : v;
}

/// Average net inflow per month over the trailing [windowDays] (default 90
/// ≈ 3 months): the sum of [signedForSavings] over rows dated in
/// `(now − span, now]`, scaled to a 30.44-day month.
///
/// The span is the days the account's rows actually cover, capped at
/// [windowDays]: an account opened 20 days ago is divided by 20 days, not
/// by 90. Below [kMinDaysOfData] covered days there is no honest pace and
/// this returns 0, which hides the projection.
double avgMonthlyNet(
  List<Tx> accountTxs, {
  required DateTime now,
  int windowDays = 90,
}) {
  if (accountTxs.isEmpty) return 0;
  final oldest = accountTxs
      .map((t) => t.date)
      .reduce((a, b) => a.isBefore(b) ? a : b);
  final span = daysCovered(oldest, now).clamp(0, windowDays);
  if (span < kMinDaysOfData) return 0;
  final start = now.subtract(Duration(days: span));
  var sum = 0.0;
  for (final t in accountTxs) {
    if (t.date.isAfter(start) && !t.date.isAfter(now)) {
      sum += signedForSavings(t);
    }
  }
  return sum / (span / 30.44);
}

/// When the goal is projected to be reached at the current deposit rate.
/// Null when it already is, or when the rate is zero/negative (no honest
/// estimate exists).
DateTime? projectedGoalDate({
  required double balance,
  required double goal,
  required double avgMonthlyNet,
  required DateTime now,
}) {
  final remaining = goal - balance;
  if (remaining <= 0 || avgMonthlyNet <= 0) return null;
  final days = (remaining / avgMonthlyNet * 30.44).ceil();
  return now.add(Duration(days: days));
}
