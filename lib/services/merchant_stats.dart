import '../models/transaction.dart';
import 'recurring_detector.dart';

/// Per-merchant spend aggregation for the dashboard's "Top merchants"
/// section. Pure — reuses the identity rules from recurring detection
/// (merchant from the SMS body, note fallback for manual rows; transfers,
/// spam and identity-less rows excluded).

class MerchantSpend {
  /// `recurringKeyOf` identity, e.g. `"expense|netflix"`.
  final String key;

  /// Display name from the newest row in the bucket.
  final String label;

  /// Sum of [Tx.spendAmount] (own share for splits).
  final double total;

  /// Number of payments.
  final int count;

  const MerchantSpend({
    required this.key,
    required this.label,
    required this.total,
    required this.count,
  });
}

/// The [limit] biggest expense merchants in [month], largest first.
List<MerchantSpend> topMerchants(
  List<Tx> txs, {
  required DateTime month,
  int limit = 6,
}) {
  final start = DateTime(month.year, month.month);
  final end = DateTime(month.year, month.month + 1);

  final totals = <String, double>{};
  final counts = <String, int>{};
  final newest = <String, Tx>{};
  for (final t in txs) {
    if (t.type != TxType.expense) continue;
    if (t.date.isBefore(start) || !t.date.isBefore(end)) continue;
    final key = recurringKeyOf(t);
    if (key == null) continue;
    totals[key] = (totals[key] ?? 0) + t.spendAmount;
    counts[key] = (counts[key] ?? 0) + 1;
    final seen = newest[key];
    if (seen == null || t.date.isAfter(seen.date)) newest[key] = t;
  }

  final result = [
    for (final e in totals.entries)
      MerchantSpend(
        key: e.key,
        label: merchantDisplayLabel(newest[e.key]!),
        total: e.value,
        count: counts[e.key]!,
      ),
  ]..sort((a, b) => b.total.compareTo(a.total));
  return result.length <= limit ? result : result.sublist(0, limit);
}
