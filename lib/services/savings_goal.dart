import '../models/transaction.dart';

/// Savings-goal projection math. Pure — the account card feeds it
/// `transactionsForAccount` rows and the derived balance.

/// Signed movement of [t] as seen by a SAVINGS account — replicates the
/// `invertTransfers` rule in FinanceProvider's balance math: a transfer
/// debited elsewhere ("To savings") is a deposit here (+), a transfer
/// credited elsewhere is a withdrawal here (−); non-transfer rows (interest
/// income, fees) keep their natural sign.
double signedForSavings(Tx t) {
  final v = t.type == TxType.income ? t.amount : -t.amount;
  return isTransferCategory(t.categoryId) ? -v : v;
}

/// Average net inflow per month over the trailing [windowDays] (default 90
/// ≈ 3 months): the sum of [signedForSavings] over rows dated in
/// `(now − windowDays, now]`, scaled to a 30.44-day month.
double avgMonthlyNet(
  List<Tx> accountTxs, {
  required DateTime now,
  int windowDays = 90,
}) {
  final start = now.subtract(Duration(days: windowDays));
  var sum = 0.0;
  for (final t in accountTxs) {
    if (t.date.isAfter(start) && !t.date.isAfter(now)) {
      sum += signedForSavings(t);
    }
  }
  return sum / (windowDays / 30.44);
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
