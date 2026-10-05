import '../providers/finance_provider.dart';
import '../utils/dates.dart';
import 'month_forecast.dart';
import 'safe_to_spend.dart';
import 'spend_comparison.dart';

/// The lines of the Trends comparison chart: this month's spend so far,
/// the forecast from today to the month's end, and the month it is set
/// against (last month, or a usual month). Each is cumulative: entry `i`
/// is the spend from the 1st through day `i + 1`.
class ComparisonSeries {
  final DateTime month;
  final DateTime previousMonth;

  /// Days in [month].
  final int days;

  /// The last day [actual] covers: today while the month runs, else the
  /// month's last day.
  final int today;

  /// Days 1..[today]. On the running month the last entry includes the
  /// rows waiting for review, so it is the forecast's spent so far.
  final List<double> actual;

  /// Days [today]..[days] (its first entry is [actual]'s last), ending at
  /// the Month-end forecast's total. Null for a month that has ended.
  final List<double>? predicted;

  /// Last month, its own length. Null when it is not fully on record.
  final List<double>? lastMonth;

  /// A usual month by day, cut to [days]. Null with fewer than two usual
  /// months.
  final List<double>? usual;

  const ComparisonSeries({
    required this.month,
    required this.previousMonth,
    required this.days,
    required this.today,
    required this.actual,
    required this.predicted,
    required this.lastMonth,
    required this.usual,
  });

  /// The forecast's total, or null for a month that has ended.
  double? get forecastTotal => predicted?.last;
}

/// The usual curve over [days]: a shorter month's last day carries the
/// usual WHOLE month (entry 30), as the cards compare, not the usual spend
/// by its day number.
List<double> _cutUsual(List<double> usual, int days) {
  final cut = usual.sublist(0, days);
  cut[days - 1] = usual.last;
  return cut;
}

List<double> _cumulative(Map<int, double> byDay, int days) {
  var total = 0.0;
  return [for (var d = 1; d <= days; d++) total += byDay[d] ?? 0];
}

/// [forecast] is the Month-end forecast for [month] when it is the running
/// month (null otherwise). [lastMonthOnRecord] is false when last month is
/// not fully on record, as `MonthComparison.vsPrevious` reports.
ComparisonSeries buildComparisonSeries(
  FinanceProvider finance,
  DateTime month, {
  required DateTime now,
  required MonthForecast? forecast,
  required bool lastMonthOnRecord,
}) {
  final anchor = DateTime(month.year, month.month);
  final days = daysInMonth(anchor.year, anchor.month);
  final running = anchor.year == now.year && anchor.month == now.month;
  final today = running ? now.day.clamp(1, days) : days;
  final previous = DateTime(anchor.year, anchor.month - 1);

  final actual = _cumulative(finance.expenseByDayInMonth(anchor), today);
  if (running && actual.isNotEmpty) {
    actual[actual.length - 1] += pendingSpendIn(finance, anchor);
  }

  List<double>? predicted;
  if (running && forecast != null) {
    // From the forecast's own spent so far, so the line ends exactly at its
    // total: each bill steps it up on its due day (an overdue one today),
    // and everyday spend adds the same amount each day after today.
    final start = forecast.spentSoFar;
    predicted = [
      for (var d = today; d <= days; d++)
        start +
            forecast.bills
                .where(
                  (b) =>
                      b.due.year != anchor.year ||
                      b.due.month != anchor.month ||
                      b.due.day <= d,
                )
                .fold(0.0, (s, b) => s + b.amount) +
            forecast.perDay * (d - today),
    ];
    actual[actual.length - 1] = start;
  }

  final usual = usualCumulativeByDay(finance, anchor);
  return ComparisonSeries(
    month: anchor,
    previousMonth: previous,
    days: days,
    today: today,
    actual: actual,
    predicted: predicted,
    lastMonth: lastMonthOnRecord
        ? _cumulative(
            finance.expenseByDayInMonth(previous),
            daysInMonth(previous.year, previous.month),
          )
        : null,
    usual: usual == null ? null : _cutUsual(usual, days),
  );
}
