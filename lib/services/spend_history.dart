import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import 'recurring_detector.dart';
import 'spend_comparison.dart';

/// "What does this one category or merchant usually cost me?" Twelve months
/// of one subject's spend, its usual month and its biggest month, for the
/// history sheet a category or merchant row opens.
///
/// Every figure is counted the way the dashboard counts it, so a bar in the
/// sheet matches the By category, donut or Top merchants row that opened
/// it. The comparison cards count a running month only to today's date, so
/// their rows can read lower than the sheet's month. Counted rows only
/// ([FinanceProvider.countedTransactions]), the user's own share of a split
/// ([Tx.spendAmount]), and each row in the month it counts in
/// ([Tx.effectiveDate]).
///
/// The usual month is a median over the window the comparison cards use
/// (services/spend_comparison.dart), started at the subject's own first
/// spend. It takes whole months and needs at least two, so it can differ
/// from the card's figure, which counts a running month to today's date.
///
/// Pure date and set math over [FinanceProvider]; `now` is a parameter so
/// tests never depend on the day they run.

/// What a history sheet is about: one category (raw id) or one merchant
/// (`recurringKeyOf` identity, such as "expense|netflix").
class HistorySubject {
  /// The RAW bucket id, as [FinanceProvider.expenseByCategory] keys it, so a
  /// dangling id still finds its months.
  final String? categoryId;

  /// [recurringKeyOf]'s identity, the same key `MerchantSpend.key` holds.
  final String? merchantKey;

  /// What the sheet's header reads; never used to match rows.
  final String label;

  const HistorySubject.category(String id, this.label)
    : categoryId = id,
      merchantKey = null;

  const HistorySubject.merchant(String key, this.label)
    : categoryId = null,
      merchantKey = key;
}

/// One subject's spend across a run of months.
class SpendHistory {
  final HistorySubject subject;

  /// The months drawn, oldest first, and each month's spend (own share
  /// for splits, counted rows only, by the month a row counts in).
  final List<DateTime> months;
  final List<double> amounts;

  /// Counted rows per month in [months]: a split the user paid none of adds
  /// a row but no spend, and its transactions still exist to open.
  final List<int> counts;

  /// The median of up to 6 complete months before [anchor] (before the
  /// current month when [anchor] is still ahead), from the subject's first
  /// spend on; null with fewer than 2 such months.
  final double? usual;

  /// The month in [months] with the most spend; null when all are zero.
  /// On a tie the oldest month wins.
  final DateTime? biggestMonth;
  final double biggest;

  /// The last month of [months] (Month view: the shown month).
  final DateTime anchor;

  /// [anchor] is the running month.
  final bool anchorRunning;

  const SpendHistory({
    required this.subject,
    required this.months,
    required this.amounts,
    required this.counts,
    required this.usual,
    required this.biggestMonth,
    required this.biggest,
    required this.anchor,
    required this.anchorRunning,
  });

  /// Spend across every month in [months].
  double get total => amounts.fold(0.0, (s, a) => s + a);

  /// Spend in [anchor].
  double get anchorAmount => amounts.last;

  /// Nothing spent in any of [months].
  bool get empty => amounts.every((a) => a <= 0);

  /// Rows in [anchor], and across [months].
  int get anchorCount => counts.last;
  int get totalCount => counts.fold(0, (s, c) => s + c);
}

/// Month key shared with [usualWindow] and the provider's month buckets, so
/// a stray day or time on a month never moves it into another month.
int _monthKey(DateTime d) => d.year * 12 + d.month;

/// [subject]'s spend over [months] (oldest first, at least one), measured
/// against its usual month as of [months]' last.
SpendHistory buildSpendHistory(
  FinanceProvider finance, {
  required HistorySubject subject,
  required List<DateTime> months,
  required DateTime now,
}) {
  assert(months.isNotEmpty, 'a history needs at least one month');

  final last = months.last;
  final anchor = DateTime(last.year, last.month);
  final current = DateTime(now.year, now.month);
  // A month that hasn't started yet holds only rows counted in ahead, and
  // its usual window would include the running month taken as if whole:
  // measure against what the current month's usual is instead.
  final anchorForUsual = _monthKey(anchor) > _monthKey(current)
      ? current
      : anchor;

  // Each subject reads its months one way and finds its first spend one way;
  // everything after this branch is shared.
  final double Function(DateTime m) spentIn;
  int? firstSpend;
  final rows = <int, int>{};
  final categoryId = subject.categoryId;
  if (categoryId != null) {
    // The provider's memoised month totals, so the bars match the By
    // category row exactly. Matched on the RAW id: the provider synthesises
    // a fresh TxCategory per month, so identity would never match.
    spentIn = (m) {
      for (final e in finance.expenseByCategory(m)) {
        if (e.key.id == categoryId) return e.value;
      }
      return 0.0;
    };
    // The same scan the comparison cards' per-category usual starts from.
    for (final t in finance.countedTransactions) {
      if (t.type != TxType.expense || t.categoryId != categoryId) continue;
      final k = _monthKey(t.effectiveDate);
      rows[k] = (rows[k] ?? 0) + 1;
      if (firstSpend == null || k < firstSpend) firstSpend = k;
    }
  } else {
    // No per-month merchant accessor exists, and asking topMerchants once
    // per month would walk the ledger a dozen times. One pass groups every
    // month at once, window months outside [months] included.
    final merchantKey = subject.merchantKey!;
    final buckets = <int, double>{};
    for (final t in finance.countedTransactions) {
      if (t.type != TxType.expense) continue;
      if (recurringKeyOf(t) != merchantKey) continue;
      final k = _monthKey(t.effectiveDate);
      // Less linked refunds, in the purchase's month, as the totals.
      buckets[k] = (buckets[k] ?? 0) + finance.netSpendOf(t);
      rows[k] = (rows[k] ?? 0) + 1;
      if (firstSpend == null || k < firstSpend) firstSpend = k;
    }
    spentIn = (m) => buckets[_monthKey(m)] ?? 0.0;
  }

  final amounts = [for (final m in months) spentIn(m)];

  // Months before the subject existed say nothing about it. Absent months
  // after its first spend count as zero, not as missing: a merchant paid
  // once in six months is unusual, and that is the point.
  final start = firstSpend;
  final usable = start == null
      ? const <DateTime>[]
      : [
          for (final m in usualWindow(finance, anchorForUsual))
            if (_monthKey(m) >= start) m,
        ];
  final usual = usable.length < kMinUsualMonths
      ? null
      : median([for (final m in usable) spentIn(m)]);

  // Strictly greater, so the oldest of equal months wins and an all-zero
  // run leaves no biggest month at all.
  DateTime? biggestMonth;
  var biggest = 0.0;
  for (var i = 0; i < months.length; i++) {
    if (amounts[i] > biggest) {
      biggest = amounts[i];
      biggestMonth = DateTime(months[i].year, months[i].month);
    }
  }

  return SpendHistory(
    subject: subject,
    months: List.unmodifiable(months),
    amounts: List.unmodifiable(amounts),
    counts: List.unmodifiable([
      for (final m in months) rows[_monthKey(m)] ?? 0,
    ]),
    usual: usual,
    biggestMonth: biggestMonth,
    biggest: biggest,
    anchor: anchor,
    anchorRunning: _monthKey(anchor) == _monthKey(current),
  );
}
