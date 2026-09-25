import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import 'merchant_stats.dart';
import 'spend_comparison.dart';

/// A budget that ended the month over its limit. [budgetId] is null for the
/// overall monthly cap.
typedef RecapBudgetOver = ({String? budgetId, String label, double pct});

/// Last month at a glance, for the Overview's recap card. Every figure comes
/// from the same provider totals the Overview stat cards read, so the recap
/// never disagrees with the month it summarises.
class MonthlyRecap {
  /// First day of the summarised month.
  final DateTime month;
  final double spent;
  final double income;
  final double saved;

  /// Spending against the month before, both taken whole.
  final SpendCompare vsPrevious;

  /// Up to three categories, largest first.
  final List<MapEntry<TxCategory, double>> topCategories;
  final MerchantSpend? topMerchant;
  final List<RecapBudgetOver> budgetsOver;

  const MonthlyRecap({
    required this.month,
    required this.spent,
    required this.income,
    required this.saved,
    required this.vsPrevious,
    required this.topCategories,
    required this.topMerchant,
    required this.budgetsOver,
  });
}

/// The recap of the calendar month before [now], or null when that month
/// holds no confirmed transactions.
MonthlyRecap? buildMonthlyRecap(
  FinanceProvider finance,
  SettingsProvider settings, {
  required DateTime now,
}) {
  final month = DateTime(now.year, now.month - 1);
  if (!finance.monthsWithData.contains(month)) return null;

  final over = <RecapBudgetOver>[];
  final cap = settings.monthlyBudget;
  if (cap > 0) {
    final spent = finance.budgetSpentInMonth(month);
    if (spent > cap) {
      over.add((budgetId: null, label: 'Monthly budget', pct: spent / cap));
    }
  }
  for (final b in finance.budgets) {
    if (b.limit <= 0) continue;
    final spent = finance.budgetSpentFor(b, month);
    if (spent > b.limit) {
      over.add((budgetId: b.id, label: b.name, pct: spent / b.limit));
    }
  }

  final merchants = topMerchants(
    finance.transactions,
    month: month,
    limit: 1,
    alias: finance.merchantAlias,
  );
  return MonthlyRecap(
    month: month,
    spent: finance.expenseInMonth(month),
    income: finance.incomeInMonth(month),
    saved: finance.savingsOutflowInMonth(month),
    vsPrevious: buildMonthComparison(finance, month, now: now).vsPrevious,
    topCategories: finance.expenseByCategory(month).take(3).toList(),
    topMerchant: merchants.isEmpty ? null : merchants.first,
    budgetsOver: over,
  );
}

/// When the next recap notification is due: 09:00 local time on the first
/// day of the month after [now].
DateTime nextRecapTime(DateTime now) => DateTime(now.year, now.month + 1, 1, 9);

/// The recap note to have booked as of [now]: when it fires and the month
/// it covers, or null for none. [monthsWithData] are the months holding
/// confirmed transactions (first days, as FinanceProvider reports them).
///
/// Before 09:00 on the 1st, last month's note is still ahead: opening the
/// app at 08:30 must not move it to next month or drop it.
({DateTime when, DateTime month})? recapBooking(
  DateTime now,
  Iterable<DateTime> monthsWithData,
) {
  final thisMonth = DateTime(now.year, now.month);
  final dueToday = DateTime(now.year, now.month, 1, 9);
  final lastMonth = DateTime(now.year, now.month - 1);
  final months = monthsWithData.toSet();
  if (now.isBefore(dueToday) && months.contains(lastMonth)) {
    return (when: dueToday, month: lastMonth);
  }
  if (months.contains(thisMonth)) {
    return (when: nextRecapTime(now), month: thisMonth);
  }
  return null;
}
