import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import 'merchant_stats.dart';
import 'spend_comparison.dart';

/// Days at the start of a month that show last month's recap (on the
/// dashboard's Month view). From the day after, Trends shows the running
/// month's pace instead: by the 26th, last month's totals are old news.
const int kRecapDays = 7;

/// Whether the dashboard shows last month's recap (true) or this month's
/// pace (false) on [now].
bool showsRecap(DateTime now) => now.day <= kRecapDays;

/// The clock the dashboard's recap and pace cards read. Widget tests swap
/// it to pick a day of the month; nothing else should.
DateTime Function() recapClock = DateTime.now;

/// A budget's standing for a month. [budgetId] is null for the overall
/// monthly cap.
typedef BudgetStanding = ({
  String? budgetId,
  String label,
  double spent,
  double limit,
});

/// Last month at a glance, for the Month view's recap card. Every figure
/// comes from the same provider totals the Month view's stat cards read, so the recap
/// never disagrees with the month it summarises. No income: the card is
/// about spending and saving.
class MonthlyRecap {
  /// First day of the summarised month.
  final DateTime month;
  final double spent;
  final double saved;

  /// Spending against the month before, both taken whole.
  final SpendCompare vsPrevious;

  /// Up to three categories, largest first.
  final List<MapEntry<TxCategory, double>> topCategories;
  final MerchantSpend? topMerchant;

  /// Budgets that ended the month over their limit.
  final List<BudgetStanding> budgetsOver;

  const MonthlyRecap({
    required this.month,
    required this.spent,
    required this.saved,
    required this.vsPrevious,
    required this.topCategories,
    required this.topMerchant,
    required this.budgetsOver,
  });
}

/// Every budget with a limit, cap first, with its spending in [month].
List<BudgetStanding> _standings(
  FinanceProvider finance,
  SettingsProvider settings,
  DateTime month,
) => [
  if (settings.monthlyBudget > 0)
    (
      budgetId: null,
      label: 'Monthly budget',
      spent: finance.budgetSpentInMonth(month),
      limit: settings.monthlyBudget,
    ),
  for (final b in finance.budgets)
    if (b.limit > 0)
      (
        budgetId: b.id,
        label: b.name,
        spent: finance.budgetSpentFor(b, month),
        limit: b.limit,
      ),
];

/// The recap of the calendar month before [now], or null when that month
/// holds no confirmed transactions.
MonthlyRecap? buildMonthlyRecap(
  FinanceProvider finance,
  SettingsProvider settings, {
  required DateTime now,
}) {
  final month = DateTime(now.year, now.month - 1);
  if (!finance.monthsWithData.contains(month)) return null;

  final merchants = topMerchants(
    finance.transactions,
    month: month,
    limit: 1,
    alias: finance.merchantAlias,
  );
  return MonthlyRecap(
    month: month,
    spent: finance.expenseInMonth(month),
    saved: finance.savingsOutflowInMonth(month),
    vsPrevious: buildMonthComparison(finance, month, now: now).vsPrevious,
    topCategories: finance.expenseByCategory(month).take(3).toList(),
    topMerchant: merchants.isEmpty ? null : merchants.first,
    budgetsOver: [
      for (final s in _standings(finance, settings, month))
        if (s.spent > s.limit) s,
    ],
  );
}

/// Budgets worth a line on the pace card: at or past this share of their
/// limit.
const double kPaceBudgetShare = 0.8;
const int kPaceBudgetLines = 3;

/// The running month so far, for Trends after [kRecapDays].
class MonthPace {
  /// Day-aligned: this month through today against last month through the
  /// same day (see buildMonthComparison).
  final MonthComparison comparison;

  /// Up to [kPaceBudgetLines] budgets at or past [kPaceBudgetShare] of
  /// their limit, fullest first.
  final List<BudgetStanding> budgets;

  const MonthPace({required this.comparison, required this.budgets});
}

/// This month's pace as of [now], or null when the month has no confirmed
/// transactions yet.
MonthPace? buildMonthPace(
  FinanceProvider finance,
  SettingsProvider settings, {
  required DateTime now,
}) {
  final month = DateTime(now.year, now.month);
  if (!finance.monthsWithData.contains(month)) return null;
  final budgets = [
    for (final s in _standings(finance, settings, month))
      if (s.spent >= s.limit * kPaceBudgetShare) s,
  ]..sort((a, b) => (b.spent / b.limit).compareTo(a.spent / a.limit));
  return MonthPace(
    comparison: buildMonthComparison(finance, month, now: now),
    budgets: budgets.take(kPaceBudgetLines).toList(),
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
