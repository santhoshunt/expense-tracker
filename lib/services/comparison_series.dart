import '../providers/finance_provider.dart';
import '../utils/dates.dart';
import 'safe_to_spend.dart';
import 'spend_comparison.dart';

/// The lines of the Trends comparison chart: this month's spend so far and
/// the month it is set against (last month, or a usual month). Each is
/// cumulative: entry `i` is the spend from the 1st through day `i + 1`.
class ComparisonSeries {
  final DateTime month;
  final DateTime previousMonth;

  /// Days in [month].
  final int days;

  /// The last day [actual] covers: today while the month runs, else the
  /// month's last day.
  final int today;

  /// [month] is the running month, its last day included.
  final bool running;

  /// Days 1..[today]. On the running month the last entry includes the
  /// rows waiting for review.
  final List<double> actual;

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
    required this.running,
    required this.actual,
    required this.lastMonth,
    required this.usual,
  });
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

/// [lastMonthOnRecord] is false when last month is not fully on record, as
/// `MonthComparison.vsPrevious` reports.
ComparisonSeries buildComparisonSeries(
  FinanceProvider finance,
  DateTime month, {
  required DateTime now,
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

  final usual = usualCumulativeByDay(finance, anchor);
  return ComparisonSeries(
    month: anchor,
    previousMonth: previous,
    days: days,
    today: today,
    running: running,
    actual: actual,
    lastMonth: lastMonthOnRecord
        ? _cumulative(
            finance.expenseByDayInMonth(previous),
            daysInMonth(previous.year, previous.month),
          )
        : null,
    usual: usual == null ? null : _cutUsual(usual, days),
  );
}
