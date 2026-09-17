import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/dates.dart';
import '../utils/format.dart';

/// "Is this month unusual?" — the month against the one before it, against
/// what a month normally costs, and the same question per category.
///
/// The whole feature turns on one decision. On the 17th, this month holds 17
/// days of data; compared against a full previous month it would report a
/// saving every time. So every figure here is day-aligned: this month through
/// day N against other months through day N. A month that has already ended
/// compares in full, which is the same code path with N at the month's length.
///
/// Pure date and set math over [FinanceProvider]'s memoised month totals;
/// `now` is a parameter so tests never depend on the day they run.

/// Complete months behind the compared one that feed "usual".
const int kUsualWindowMonths = 6;

/// Below this many usable months there is no honest baseline to show.
const int kMinUsualMonths = 2;

/// Projecting a full month from fewer elapsed days than this is noise: on
/// day 1 the multiplier is 30.
const int kMinDaysForProjection = 5;

/// Category rows shown before "Show all".
const int kTopMoversShown = 6;

/// A difference under a rupee is rounding, not news. Every icon, chip and
/// phrase that plays a delta down agrees through this one threshold.
bool negligibleDelta(double delta) => delta.abs() < 1;

/// Which of the four shapes a comparison has. Only [ok] carries a meaningful
/// percentage: the other three exist because dividing by a zero baseline
/// produces an infinity, not an insight.
enum CompareState {
  ok,

  /// Spent now, never in the reference window.
  newThisMonth,

  /// Spent in the reference window, nothing so far this time.
  noneThisMonth,

  /// Fewer than [kMinUsualMonths] complete months on record.
  notEnoughHistory,
}

/// One side-by-side figure: what was spent, and what it is measured against.
class SpendCompare {
  /// The compared month, counting days 1..`throughDay`.
  final double actual;

  /// The same window of the previous month, or the median of the usual ones.
  final double reference;

  /// [actual] projected to the whole month while it is still running (by the
  /// reference month's own spending curve, so it never contradicts the
  /// headline delta), the exact total once it has ended, and null when too
  /// few days have elapsed to project anything but noise.
  final double? actualFull;

  /// [reference] over whole months, for the projected line to sit against.
  final double referenceFull;

  final CompareState state;

  const SpendCompare({
    required this.actual,
    required this.reference,
    required this.actualFull,
    required this.referenceFull,
    required this.state,
  });

  double get delta => actual - reference;

  /// Null when there is no baseline to divide by.
  double? get deltaPct => reference <= 0 ? null : delta / reference;

  /// Too small a difference to colour, arrow or phrase as a change.
  bool get negligible => negligibleDelta(delta);

  /// Nothing on either side, so there is no comparison to draw.
  bool get empty => actual <= 0 && reference <= 0;
}

/// One category's spend against its usual.
class CategoryCompare {
  final TxCategory category;
  final double actual;
  final double usual;
  final CompareState state;

  const CategoryCompare({
    required this.category,
    required this.actual,
    required this.usual,
    required this.state,
  });

  double get delta => actual - usual;

  /// Null when there is no usual to divide by (a new-this-month category).
  double? get deltaPct => usual <= 0 ? null : delta / usual;

  /// Too small a difference to colour, arrow or phrase as a change.
  bool get negligible => negligibleDelta(delta);
}

/// Everything the three dashboard cards render for one month.
class MonthComparison {
  final DateTime month;
  final DateTime previousMonth;

  /// Day-of-month both sides are cut at.
  final int throughDay;

  /// [month] is still running, so [throughDay] is short of its length.
  final bool partial;

  /// How many complete months fed the median, for the shortfall copy.
  final int usualMonths;

  final SpendCompare vsPrevious;
  final SpendCompare vsUsual;

  /// Largest deviation from usual first, in either direction. Categories
  /// quiet in both windows are left out.
  final List<CategoryCompare> categories;

  const MonthComparison({
    required this.month,
    required this.previousMonth,
    required this.throughDay,
    required this.partial,
    required this.usualMonths,
    required this.vsPrevious,
    required this.vsUsual,
    required this.categories,
  });
}

/// Middle value of [values], averaging the two middles for an even count.
///
/// A median rather than a mean: one insurance premium or flight would
/// otherwise raise "usual" for the next six months, and per-category that
/// single spike is the common case rather than the exception.
double median(List<double> values) {
  if (values.isEmpty) return 0;
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// The complete months behind [month] whose figures the ledger can support,
/// oldest first.
///
/// Only the unbroken run of recorded months counts. A month holding no rows
/// at all means missing records far more often than it means a month without
/// a single transaction, and folding those zeros into the median would
/// report a baseline that is an artefact of the import history rather than
/// of spending. The run also stops at a first month the records join
/// part-way through, for the same reason.
List<DateTime> usualWindow(FinanceProvider finance, DateTime month) {
  final first = finance.firstTransactionDate;
  if (first == null) return const [];
  final covered = {
    for (final m in finance.monthsWithData) m.year * 12 + m.month,
  };
  final out = <DateTime>[];
  for (var k = 1; k <= kUsualWindowMonths; k++) {
    final m = DateTime(month.year, month.month - k);
    if (!covered.contains(m.year * 12 + m.month)) break;
    if (m.year == first.year && m.month == first.month && first.day > 1) break;
    out.add(m);
  }
  return out.reversed.toList();
}

MonthComparison buildMonthComparison(
  FinanceProvider finance,
  DateTime month, {
  required DateTime now,
}) {
  final anchor = DateTime(month.year, month.month);
  final days = daysInMonth(anchor.year, anchor.month);
  final running = anchor.year == now.year && anchor.month == now.month;
  final throughDay = running ? now.day.clamp(1, days) : days;
  final partial = throughDay < days;
  final previous = DateTime(anchor.year, anchor.month - 1);
  final window = usualWindow(finance, anchor);

  // Day-alignment only applies while the compared month is still running.
  // Once it has ended, every side is taken whole: cutting a 31-day reference
  // month at 30 days, because the compared month happened to be that long,
  // would understate it for no reason.
  double spent(DateTime m) => partial
      ? finance.expenseInMonthThrough(m, throughDay)
      : finance.expenseInMonth(m);

  final actual = spent(anchor);

  final prevRef = spent(previous);
  final prevFull = finance.expenseInMonth(previous);
  final usualRef = median([for (final m in window) spent(m)]);
  final usualFull = median([for (final m in window) finance.expenseInMonth(m)]);

  return MonthComparison(
    month: anchor,
    previousMonth: previous,
    throughDay: throughDay,
    partial: partial,
    usualMonths: window.length,
    vsPrevious: SpendCompare(
      actual: actual,
      reference: prevRef,
      actualFull: _project(
        actual: actual,
        reference: prevRef,
        referenceFull: prevFull,
        throughDay: throughDay,
        days: days,
      ),
      referenceFull: prevFull,
      state: _stateFor(actual, prevRef),
    ),
    vsUsual: SpendCompare(
      actual: actual,
      reference: usualRef,
      actualFull: _project(
        actual: actual,
        reference: usualRef,
        referenceFull: usualFull,
        throughDay: throughDay,
        days: days,
      ),
      referenceFull: usualFull,
      state: window.length < kMinUsualMonths
          ? CompareState.notEnoughHistory
          : _stateFor(actual, usualRef),
    ),
    categories: _categories(
      finance,
      anchor,
      window,
      partial ? throughDay : null,
    ),
  );
}

/// "₹3,100 (21%) more", "₹900 less", "the same" — the magnitude without
/// naming what it is measured against, so both cards share one phrasing.
String deltaPhrase(SpendCompare c) {
  final d = c.delta;
  if (c.negligible) return 'the same';
  final pct = c.deltaPct;
  final suffix = pct == null ? '' : ' (${(pct.abs() * 100).round()}%)';
  return '${fmtMoney(d.abs())}$suffix ${d > 0 ? 'more' : 'less'}';
}

/// Scales [actual] by how much of [referenceFull] the reference month had
/// reached by the same day, so the projection assumes the rest of this month
/// follows the reference month's curve. That makes it agree with the
/// headline delta by construction (projected / referenceFull equals
/// actual / reference): a flat daily pace could beat a front-loaded month
/// while the headline said "less". The flat pace remains only as the
/// fallback when there is no reference window to take a shape from.
double? _project({
  required double actual,
  required double reference,
  required double referenceFull,
  required int throughDay,
  required int days,
}) {
  if (throughDay >= days) return actual;
  if (throughDay < kMinDaysForProjection) return null;
  if (reference <= 0 || referenceFull <= 0) return actual * days / throughDay;
  return actual * referenceFull / reference;
}

CompareState _stateFor(double actual, double reference) {
  if (reference <= 0 && actual > 0) return CompareState.newThisMonth;
  if (actual <= 0 && reference > 0) return CompareState.noneThisMonth;
  return CompareState.ok;
}

/// [throughDay] is null once the compared month has ended, which takes every
/// month whole.
List<CategoryCompare> _categories(
  FinanceProvider finance,
  DateTime month,
  List<DateTime> window,
  int? throughDay,
) {
  // Keyed by the RAW bucket id throughout: the provider synthesises a fresh
  // TxCategory per month (so dangling ids keep deep-linking), and comparing
  // those by identity would never match across months.
  final labels = <String, TxCategory>{};
  Map<String, double> byId(DateTime m) {
    final rows = throughDay == null
        ? finance.expenseByCategory(m)
        : finance.expenseByCategoryThrough(m, throughDay);
    final out = <String, double>{};
    for (final e in rows) {
      out[e.key.id] = e.value;
      labels.putIfAbsent(e.key.id, () => e.key);
    }
    return out;
  }

  final actual = byId(month);
  final history = [for (final m in window) byId(m)];
  final ids = {...actual.keys, for (final h in history) ...h.keys};

  final out = [
    for (final id in ids)
      () {
        final a = actual[id] ?? 0;
        // Absent months count as zero, not as missing: a category bought
        // once in six months is unusual, and that is the point.
        final usual = median([for (final h in history) h[id] ?? 0]);
        return CategoryCompare(
          category: labels[id]!,
          actual: a,
          usual: usual,
          state: _stateFor(a, usual),
        );
      }(),
  ]..removeWhere((c) => c.actual <= 0 && c.usual <= 0);

  out.sort((a, b) => b.delta.abs().compareTo(a.delta.abs()));
  return out;
}
