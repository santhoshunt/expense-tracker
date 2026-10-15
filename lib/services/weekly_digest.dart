import 'package:intl/intl.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import 'spend_comparison.dart' show median;

/// Monday 00:00 of [d]'s week. Weeks run Monday to Sunday.
DateTime weekStartOf(DateTime d) =>
    DateTime(d.year, d.month, d.day - (d.weekday - 1));

/// How many whole earlier weeks make the usual week, at most.
const int kUsualWeeks = 8;

/// The clock the Overview row and the sheet read. Tests swap it.
DateTime Function() weekClock = DateTime.now;

/// One week at a glance, for the Overview's This week row and the weekly
/// digest sheet. Money out follows FinanceProvider.spendOnDay row for row
/// (expense-typed, not a transfer, counted, by Tx.effectiveDate, the
/// user's own share), so the day bars add up to [spent].
class WeekDigest {
  /// Monday 00:00.
  final DateTime start;

  /// 7 for a past week; for the current one, Monday to today (1 to 7).
  final int daysShown;
  final double spent;

  /// Income-typed rows that are not transfers.
  final double income;

  /// Confirmed counted rows in the days shown, transfers included.
  final int count;

  /// Imports waiting for review, dated in the week.
  final int toReview;

  /// 7 entries, Monday first; days after today are 0.
  final List<double> byDay;

  /// The median of up to [kUsualWeeks] whole weeks before [start], each
  /// cut to [daysShown] days; null under 2 weeks of history.
  final double? usual;

  /// Up to 3, largest first. Keyed by the raw category id, as
  /// FinanceProvider.expenseByCategory is, so a tap filters the rows.
  final List<MapEntry<TxCategory, double>> topCategories;

  /// Up to 3 money-out rows by Tx.spendAmount, largest first.
  final List<Tx> biggest;

  const WeekDigest({
    required this.start,
    required this.daysShown,
    required this.spent,
    required this.income,
    required this.count,
    required this.toReview,
    required this.byDay,
    required this.usual,
    required this.topCategories,
    required this.biggest,
  });

  /// Sunday of the week.
  DateTime get end => DateTime(start.year, start.month, start.day + 6);
}

/// The last digest built, keyed on (revision, week, day of now): the row
/// and the sheet ask for the same week on every rebuild.
Object? _memoRevision;
DateTime? _memoWeek;
DateTime? _memoDay;
WeekDigest? _memo;

/// The digest of the week starting [weekStart] as of [now]. One pass over
/// FinanceProvider.countedTransactions covers the week and the earlier
/// weeks its usual week needs.
WeekDigest buildWeekDigest(
  FinanceProvider finance,
  DateTime weekStart, {
  required DateTime now,
}) {
  final start = weekStartOf(weekStart);
  final today = DateTime(now.year, now.month, now.day);
  final cached = _memo;
  if (cached != null &&
      identical(_memoRevision, finance.revision) &&
      _memoWeek == start &&
      _memoDay == today) {
    return cached;
  }
  final daysShown = start == weekStartOf(now) ? now.weekday : 7;
  final earliest = DateTime(
    start.year,
    start.month,
    start.day - 7 * kUsualWeeks,
  );

  final byDay = List<double>.filled(7, 0);
  final earlier = <DateTime, double>{};
  final byCategory = <String, double>{};
  final spends = <Tx>[];
  var income = 0.0;
  var count = 0;
  for (final t in finance.countedTransactions) {
    final d = t.effectiveDate;
    final day = d.weekday - 1;
    // Day-aligned: the current week and every earlier one stop at the
    // same weekday.
    if (day >= daysShown) continue;
    final week = weekStartOf(d);
    if (week.isBefore(earliest) || week.isAfter(start)) continue;
    final money = !isTransferCategory(t.categoryId);
    final out = money && t.type == TxType.expense;
    if (week != start) {
      if (out) earlier[week] = (earlier[week] ?? 0) + t.spendAmount;
      continue;
    }
    count++;
    if (out) {
      byDay[day] += t.spendAmount;
      byCategory[t.categoryId] =
          (byCategory[t.categoryId] ?? 0) + t.spendAmount;
      spends.add(t);
    } else if (money && t.type == TxType.income) {
      income += t.amount;
    }
  }

  // Weeks from the one holding the first row on; quiet weeks count as 0.
  double? usual;
  final first = finance.firstTransactionDate;
  if (first != null) {
    final firstWeek = weekStartOf(first);
    final weeks = <double>[];
    for (var k = 1; k <= kUsualWeeks; k++) {
      final w = DateTime(start.year, start.month, start.day - 7 * k);
      if (w.isBefore(firstWeek)) break;
      weeks.add(earlier[w] ?? 0);
    }
    if (weeks.length >= 2) usual = median(weeks);
  }

  final weekEnd = DateTime(start.year, start.month, start.day + 7);
  final toReview = finance.pendingTransactions.where((t) {
    final d = t.effectiveDate;
    return !d.isBefore(start) && d.isBefore(weekEnd);
  }).length;

  final categories = byCategory.entries.map((e) {
    final cat = categoryById(e.key, fallbackType: TxType.expense);
    // The raw id, as FinanceProvider's totals keep it: a dangling id reads
    // as Other but must still filter its own rows.
    final key = cat.id == e.key
        ? cat
        : TxCategory(
            id: e.key,
            label: cat.label,
            icon: cat.icon,
            color: cat.color,
            type: cat.type,
            isTransfer: cat.isTransfer,
          );
    return MapEntry(key, e.value);
  }).toList()..sort((a, b) => b.value.compareTo(a.value));
  spends.sort((a, b) {
    final c = b.spendAmount.compareTo(a.spendAmount);
    return c != 0 ? c : b.date.compareTo(a.date);
  });

  final digest = WeekDigest(
    start: start,
    daysShown: daysShown,
    spent: byDay.fold(0.0, (s, v) => s + v),
    income: income,
    count: count,
    toReview: toReview,
    byDay: List.unmodifiable(byDay),
    usual: usual,
    topCategories: List.unmodifiable(categories.take(3)),
    biggest: List.unmodifiable(spends.take(3)),
  );
  _memoRevision = finance.revision;
  _memoWeek = start;
  _memoDay = today;
  _memo = digest;
  return digest;
}

/// The week's dates as the note names them: "12 to 18 Oct", or
/// "28 Sep to 4 Oct" across a month end. [withWeekday] names the days too,
/// as the digest sheet does: "Mon 12 to Sun 18 Oct".
String weekRangeLabel(DateTime week, {bool withWeekday = false}) {
  final start = weekStartOf(week);
  final end = DateTime(start.year, start.month, start.day + 6);
  final day = withWeekday ? 'EEE d' : 'd';
  final dMmm = DateFormat('$day MMM');
  final from = start.month == end.month
      ? DateFormat(day).format(start)
      : dMmm.format(start);
  return '$from to ${dMmm.format(end)}';
}

/// The digest note to have booked as of [now]: when it fires and the
/// Monday of the week it covers, or null for none (an empty ledger).
/// Before 09:00 on a Monday, today's note for last week is still ahead;
/// otherwise next Monday's, for the current week.
({DateTime when, DateTime week})? weeklyDigestBooking(
  DateTime now, {
  required bool hasData,
}) {
  if (!hasData) return null;
  final thisWeek = weekStartOf(now);
  final dueToday = DateTime(thisWeek.year, thisWeek.month, thisWeek.day, 9);
  if (now.isBefore(dueToday)) {
    return (
      when: dueToday,
      week: DateTime(thisWeek.year, thisWeek.month, thisWeek.day - 7),
    );
  }
  return (
    when: DateTime(thisWeek.year, thisWeek.month, thisWeek.day + 7, 9),
    week: thisWeek,
  );
}
