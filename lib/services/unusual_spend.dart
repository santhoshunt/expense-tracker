import 'package:intl/intl.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/format.dart';
import 'spend_history.dart';

/// "Is any category running well past its usual month?" The rule behind the
/// unusual spending alert (services/unusual_spend_monitor.dart).
///
/// A category's spend so far this month is measured against its usual
/// WHOLE month, not against the usual month's first N days: a bill paid a
/// few days early would otherwise read as a spike every month. So the alert
/// can only fire once the month has already cost more than a usual one.
///
/// The usual month comes from [buildSpendHistory], so the figure in the
/// alert is the Usual month tile of the history sheet its tap opens.

/// The multiple of its usual month a category's spend so far must reach.
const double kUnusualFactor = 1.5;

/// How far above its usual month a category's spend so far must also be,
/// so small categories stay quiet.
const double kUnusualMinOver = 1000;

/// [spent] against [usual] by the two rules above. A null [usual] never
/// qualifies: fewer than two whole months on record since the category's
/// first spend, so a category used for the first time this month never
/// alerts. A usual of zero does once [spent] is [kUnusualMinOver] or more,
/// since spend in a category that is normally empty is what the alert is
/// for.
bool isUnusualSpend(double spent, double? usual) =>
    usual != null &&
    spent >= usual * kUnusualFactor &&
    spent - usual >= kUnusualMinOver;

/// One category over the line this month.
class UnusualCategory {
  /// The RAW bucket id, as [FinanceProvider.expenseByCategory] keys it.
  final String id;
  final String label;
  final double spent;
  final double usual;

  const UnusualCategory({
    required this.id,
    required this.label,
    required this.spent,
    required this.usual,
  });
}

/// The categories whose spend in `now`'s month passes [isUnusualSpend],
/// biggest overspend first. Ids in [skip] (already alerted) are left out
/// before any history is built: this runs on every ledger change.
///
/// This month's spend on a guessed category waits until the user confirms
/// it, so a wrong guess cannot fire the alert, and To sort, which no one
/// chose, never alerts.
List<UnusualCategory> unusualCategories(
  FinanceProvider finance, {
  required DateTime now,
  Set<String> skip = const {},
}) {
  final month = DateTime(now.year, now.month);
  final out = <UnusualCategory>[];
  for (final e in finance.expenseByCategory(month)) {
    final id = e.key.id;
    if (isToSortCategory(id)) continue;
    final guessed = finance.guessedSpendIn(month, id);
    // Under the floor nothing can be far enough over, whatever the usual.
    if (e.value - guessed < kUnusualMinOver || skip.contains(id)) continue;
    final h = buildSpendHistory(
      finance,
      subject: HistorySubject.category(id, e.key.label),
      months: [month],
      now: now,
    );
    final spent = h.anchorAmount - guessed;
    if (!isUnusualSpend(spent, h.usual)) continue;
    out.add(
      UnusualCategory(
        id: id,
        label: e.key.label,
        spent: spent,
        usual: h.usual!,
      ),
    );
  }
  out.sort((a, b) => (b.spent - b.usual).compareTo(a.spent - a.usual));
  return out;
}

/// The alert's words: "Food & Dining is above usual", "₹6,200 so far in
/// October. A usual month is ₹3,800."
({String title, String body}) unusualAlertText(
  UnusualCategory c,
  DateTime month,
) {
  final name = DateFormat('MMMM').format(month);
  final soFar = '${fmtMoney(c.spent)} so far in $name.';
  return (
    title: '${c.label} is above usual',
    body: c.usual <= 0
        ? '$soFar Most months have none.'
        : '$soFar A usual month is ${fmtMoney(c.usual)}.',
  );
}
