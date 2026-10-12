import 'dart:math' as math;

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/dates.dart';
import '../utils/fiscal_year.dart';
import 'spend_comparison.dart';

/// "Is this year costing more than last year?" The year against the same
/// months of the year before, in total and per category.
///
/// The decision that shapes it is the same one as the month comparison's
/// (services/spend_comparison.dart): while a year is running, it holds only
/// the months so far, so a whole previous year would make it look cheap
/// every time. Both sides therefore stop at the same month and day. A year
/// that has ended compares all twelve months against all twelve.
///
/// Only one baseline: the same span of the previous year. A median of
/// several earlier years would need several years on record, and most
/// ledgers hold one or two.
///
/// Pure date and set math over [FinanceProvider]'s memoised month totals;
/// `now` is a parameter so tests never depend on the day they run.

/// One year against the same span of the year before.
class YearComparison {
  /// The year's first month: (2026, 4) is FY 2026-27, (2026, 1) is 2026.
  final int startYear;
  final int startMonth;

  /// The year is still running: both sides stop at the same month and day.
  final bool partial;

  /// The last day both sides count through, inclusive, at midnight.
  final DateTime through;

  /// `actual` is this year, `reference` the same span of last year, and
  /// `referenceFull` all twelve months of last year.
  final SpendCompare total;

  /// Per category, largest change first. `usual` holds last year's figure
  /// for the same span. Empty when last year is not fully on record.
  final List<CategoryCompare> categories;

  const YearComparison({
    required this.startYear,
    required this.startMonth,
    required this.partial,
    required this.through,
    required this.total,
    required this.categories,
  });

  /// "2026" or "FY 2026-27".
  String get label => yearLabel(startYear, startMonth);

  /// The year compared against: "2025" or "FY 2025-26".
  String get previousLabel => yearLabel(startYear - 1, startMonth);
}

/// The year starting [startMonth] of [startYear] against the year before.
///
/// Null when that year has not started by [now]'s month: a year ahead holds
/// only rows counted in early, and its "last year" would be the running one
/// taken as if whole.
YearComparison? buildYearComparison(
  FinanceProvider finance, {
  required int startYear,
  required int startMonth,
  required DateTime now,
}) {
  final start = DateTime(startYear, startMonth);
  if (start.isAfter(DateTime(now.year, now.month))) return null;

  final bounds = yearBounds(startYear, startMonth);
  final months = yearMonths(startYear, startMonth);
  final today = DateTime(now.year, now.month, now.day);
  // On the year's last day every month is taken whole, so the year counts as
  // ended (actualFull set), the way buildMonthComparison treats a month on
  // its last day.
  final partial = today.isBefore(bounds.last);

  // Months taken whole on both sides, then the cut month (if any) with the
  // day each side counts through. Last year's side clamps the day to its
  // month's length, so 29 February takes all of the 28-day February before.
  // A month that ends today is taken whole on both sides, as in the month
  // comparison: 28 February 2029 against all of February 2028, 29th included.
  final index = (now.year * 12 + now.month) - (startYear * 12 + startMonth);
  final DateTime? cut = partial ? months[index] : null;
  final whole = cut == null ? 12 : index;
  final cutDay = now.day;
  final lastCutDay = cut == null ? 0 : _lastYearDay(cut, now.day);
  final wholeThis = months.take(whole).toList();
  final wholeLast = [for (final m in wholeThis) _yearBefore(m)];
  final DateTime? lastCut = cut == null ? null : _yearBefore(cut);

  double spent(List<DateTime> whole, DateTime? cut, int day) =>
      whole.fold(0.0, (s, m) => s + finance.expenseInMonth(m)) +
      (cut == null ? 0.0 : finance.expenseInMonthThrough(cut, day));

  // Last year only counts as a reference when the records cover all of its
  // span. The real date, truncated to the day: a first row at 10:00 on the
  // span's first day still covers that day.
  final first = finance.firstTransactionDate;
  final covered =
      first != null &&
      !DateTime(
        first.year,
        first.month,
        first.day,
      ).isAfter(DateTime(startYear - 1, startMonth));

  final actual = spent(wholeThis, cut, cutDay);
  // A reference the records only half cover is zeroed, as the month
  // comparison does, so `empty` means "nothing this year" and the dashboard
  // can hide the section on a ledger that has not started.
  final reference = covered ? spent(wholeLast, lastCut, lastCutDay) : 0.0;
  final referenceFull = covered
      ? finance.expenseInYear(startYear - 1, startMonth: startMonth)
      : 0.0;

  return YearComparison(
    startYear: startYear,
    startMonth: startMonth,
    partial: partial,
    through: partial ? today : bounds.last,
    total: SpendCompare(
      actual: actual,
      reference: reference,
      // No projection for a running year: twelve months of a curve is too
      // long a stretch to extrapolate from a few.
      actualFull: partial ? null : actual,
      referenceFull: referenceFull,
      state: covered
          ? compareStateFor(actual, reference)
          : CompareState.notEnoughHistory,
    ),
    categories: covered
        ? _categories(
            finance,
            wholeThis: wholeThis,
            wholeLast: wholeLast,
            cut: cut,
            cutDay: cutDay,
            lastCut: lastCut,
            lastCutDay: lastCutDay,
          )
        : const [],
  );
}

DateTime _yearBefore(DateTime m) => DateTime(m.year - 1, m.month);

/// The day last year's copy of [cut] counts through when this year's [cut]
/// counts through [day]: the same day, clamped to that month's length, or
/// the whole month when [day] is [cut]'s last.
int _lastYearDay(DateTime cut, int day) {
  final lastDays = daysInMonth(cut.year - 1, cut.month);
  if (day >= daysInMonth(cut.year, cut.month)) return lastDays;
  return math.min(day, lastDays);
}

/// Each category this year against the same span of last year.
List<CategoryCompare> _categories(
  FinanceProvider finance, {
  required List<DateTime> wholeThis,
  required List<DateTime> wholeLast,
  required DateTime? cut,
  required int cutDay,
  required DateTime? lastCut,
  required int lastCutDay,
}) {
  // Keyed by the RAW bucket id, as the month comparison is: the provider
  // synthesises a fresh TxCategory per month (so dangling ids keep
  // deep-linking), and comparing those by identity would never match across
  // months.
  final labels = <String, TxCategory>{};
  void add(Map<String, double> into, List<MapEntry<TxCategory, double>> rows) {
    for (final e in rows) {
      into[e.key.id] = (into[e.key.id] ?? 0) + e.value;
      labels.putIfAbsent(e.key.id, () => e.key);
    }
  }

  Map<String, double> sum(List<DateTime> whole, DateTime? cut, int day) {
    final out = <String, double>{};
    for (final m in whole) {
      add(out, finance.expenseByCategory(m));
    }
    if (cut != null) add(out, finance.expenseByCategoryThrough(cut, day));
    return out;
  }

  final thisYear = sum(wholeThis, cut, cutDay);
  final lastYear = sum(wholeLast, lastCut, lastCutDay);
  final out = [
    for (final id in {...thisYear.keys, ...lastYear.keys})
      () {
        final a = thisYear[id] ?? 0;
        final b = lastYear[id] ?? 0;
        return CategoryCompare(
          category: labels[id]!,
          actual: a,
          usual: b,
          state: compareStateFor(a, b),
        );
      }(),
  ]..removeWhere((c) => c.actual <= 0 && c.usual <= 0);

  out.sort((a, b) => b.delta.abs().compareTo(a.delta.abs()));
  return out;
}
