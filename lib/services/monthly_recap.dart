import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import 'merchant_stats.dart';
import 'spend_comparison.dart';

/// Days at the start of a month that show last month's recap (on the
/// dashboard's Overview). From the day after, Trends' This month so far card
/// covers the month: by the 26th, last month's totals are old news.
const int kRecapDays = 7;

/// Whether the dashboard shows last month's recap (true) or leaves the
/// month to Trends' This month so far card (false) on [now].
bool showsRecap(DateTime now) => now.day <= kRecapDays;

/// The clock the dashboard's recap card, its ⋮ recap entry and the recap
/// sheet read. Widget tests swap it to pick a day of the month;
/// nothing else should.
DateTime Function() recapClock = DateTime.now;

/// A budget's standing for a month. [budgetId] is null for the overall
/// monthly cap.
typedef BudgetStanding = ({
  String? budgetId,
  String label,
  double spent,
  double limit,
});

/// Last month at a glance, for the Overview's recap card. Every figure comes
/// from the same provider totals the Overview stat cards read, so the recap
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
    finance.countedTransactions,
    month: month,
    limit: 1,
    alias: finance.merchantAlias,
    spendOf: finance.netSpendOf,
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

/// The recap of [month] (its first day), whatever today is, or null when
/// that month holds no confirmed transactions. Built as the 1st of the
/// month after would build it, so the figures match the card's.
MonthlyRecap? buildRecapFor(
  FinanceProvider finance,
  SettingsProvider settings,
  DateTime month,
) => buildMonthlyRecap(
  finance,
  settings,
  now: DateTime(month.year, month.month + 1, 1),
);

/// Months with a recap as of [now]: [monthsWithData] before today's
/// month, newest first.
List<DateTime> recapMonths(Iterable<DateTime> monthsWithData, DateTime now) {
  final thisMonth = DateTime(now.year, now.month);
  return {
    for (final m in monthsWithData)
      if (DateTime(m.year, m.month).isBefore(thisMonth))
        DateTime(m.year, m.month),
  }.toList()..sort((a, b) => b.compareTo(a));
}

/// When the next recap notification is due: 09:00 local time on the first
/// day of the month after [now].
DateTime nextRecapTime(DateTime now) => DateTime(now.year, now.month + 1, 1, 9);

/// How long after its 09:00 time a booked note is left alone. The recap and
/// digest notes are inexact, so Android may deliver them late: an app open
/// in that time must not cancel or replace one not shown yet.
const Duration kLateNoteWindow = Duration(hours: 6);

/// The recap note to have booked as of [now]: when it fires and the month
/// it covers, or null for none. [monthsWithData] are the months holding
/// confirmed transactions (first days, as FinanceProvider reports them).
///
/// Before 09:00 on the 1st, last month's note is still ahead: opening the
/// app at 08:30 must not move it to next month or drop it. With [keepLate]
/// that holds until [kLateNoteWindow] after 09:00, and the booking's time
/// may then be past: the caller keeps the note still booked rather than
/// book this one again. Without it, the next note after the 09:00 one.
({DateTime when, DateTime month})? recapBooking(
  DateTime now,
  Iterable<DateTime> monthsWithData, {
  bool keepLate = true,
}) {
  final thisMonth = DateTime(now.year, now.month);
  final dueToday = DateTime(now.year, now.month, 1, 9);
  final lastMonth = DateTime(now.year, now.month - 1);
  final months = monthsWithData.toSet();
  final until = keepLate ? dueToday.add(kLateNoteWindow) : dueToday;
  if (now.isBefore(until) && months.contains(lastMonth)) {
    return (when: dueToday, month: lastMonth);
  }
  if (months.contains(thisMonth)) {
    return (when: nextRecapTime(now), month: thisMonth);
  }
  return null;
}
