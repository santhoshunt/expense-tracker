import 'package:flutter/material.dart' show DateTimeRange;
import 'package:intl/intl.dart';

// Indian grouping: "₹1,42,500.00", the way bank alerts write amounts.
final NumberFormat _currency = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: 2,
);
// Compact keeps the default locale: en_IN's compact form swaps K for T, L
// and Cr.
final NumberFormat _currencyCompact = NumberFormat.compactCurrency(
  symbol: '₹',
  decimalDigits: 1,
);
final NumberFormat _wholeRupees = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: 0,
);
final DateFormat _date = DateFormat('d MMM yyyy');
final DateFormat _dateTime = DateFormat('d MMM yyyy, h:mm a');
final DateFormat _dayMonth = DateFormat('d MMM');
final DateFormat _time = DateFormat('h:mm a');
final DateFormat _monthYear = DateFormat('MMMM yyyy');

/// Stand-in for an amount the user chose to hide (Settings → Privacy →
/// Hide income). Totals render this; the underlying value never changes.
const String kMaskedAmount = '₹••••';

/// A negative amount takes the true minus sign "−", as the ledger rows do,
/// not the format's hyphen.
String fmtMoney(double v) => _signed(v, _currency);

/// [format] of [v] with "−" for a negative that does not round to zero; -0.0
/// and -0.001 print as zero, with no sign at all.
String _signed(double v, NumberFormat format) {
  final magnitude = format.format(v.abs());
  if (!v.isNegative || magnitude == format.format(0)) return magnitude;
  return '−$magnitude';
}

final NumberFormat _points = NumberFormat('#,##0.##');

/// A wallet's points: "1,250 points", "12.5 points", "1 point".
String fmtPoints(double v) {
  final n = _points.format(v);
  return '$n point${n == '1' ? '' : 's'}';
}

/// [v] for an editable field: no grouping, at most two decimals ("1250",
/// "12.5").
String fmtFieldNumber(double v) => _fieldNumber.format(v);

final NumberFormat _fieldNumber = NumberFormat('0.##');

/// A wallet's ₹ per point, to four places so ₹0.004 doesn't read ₹0.00.
String fmtPerPoint(double v) => '₹${_perPoint.format(v)}';

/// [fmtPerPoint] without the ₹, for an editable field.
String fmtPerPointField(double v) => _perPoint.format(v);

final NumberFormat _perPoint = NumberFormat('0.00##');

/// "₹39.1K" for larger amounts; whole rupees below ₹1,000, where the one
/// decimal ("₹77.7") read like paise.
String fmtMoneyCompact(double v) =>
    _signed(v, v.abs() < 999.5 ? _wholeRupees : _currencyCompact);

/// [fmtMoney] without a trailing ".00": the forced two decimals read as
/// clutter at home-screen widget size ("₹60,000.00 of ₹60,000.00").
String fmtMoneyTidy(double v) {
  final s = fmtMoney(v);
  return s.endsWith('.00') ? s.substring(0, s.length - 3) : s;
}

/// Whole rupees, rounded: the Dashboard's figures. Paise belong to
/// transaction lists.
String fmtMoneyWhole(double v) => _signed(v, _wholeRupees);

String fmtDate(DateTime d) => _date.format(d);
String fmtDateTime(DateTime d) => _dateTime.format(d);
String fmtTime(DateTime d) => _time.format(d);
String fmtMonth(DateTime d) => _monthYear.format(d);

/// Parses money text the way people type it: "45,000", "₹ 1,50,000.50",
/// "45000" all read as numbers. Returns null when nothing numeric remains.
///
/// Exists because `double.tryParse` rejects grouping commas — and a dialog
/// that treats a failed parse as "no value" turns "45,000" into a silent
/// *clear* of the very balance the user was trying to set.
double? parseAmount(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[₹,\s]'), '');
  if (cleaned.isEmpty) return null;
  // tryParse accepts "NaN" and "Infinity"; neither is an amount, and NaN
  // throws the moment anything rounds it.
  final v = double.tryParse(cleaned);
  return v != null && v.isFinite ? v : null;
}

/// [facts] joined by " · " for a detail line that may wrap: each fact keeps
/// its words together, and a line breaks only after a dot, so no line
/// starts with one or splits "3 transactions".
String joinFacts(Iterable<String> facts) => facts
    .map(
      (f) => f
          .replaceAll(' ', ' ')
          // A line may break after a dash even before a no-break space;
          // word joiners hold "23 Sep – 13 Oct" together.
          .replaceAll('–', '⁠–⁠'),
    )
    .join(' · ');

/// Date alone at midnight, date + time otherwise.
///
/// Midnight is the app's "no time known" value — every transaction recorded
/// before timestamps existed, and any SMS whose body states neither a clock
/// time nor an arrival time. Rendering "12:00 am" for those would invent
/// precision that isn't there, so the time is shown only when it is real.
String fmtDateMaybeTime(DateTime d) =>
    (d.hour == 0 && d.minute == 0) ? fmtDate(d) : fmtDateTime(d);

/// [fmtDateMaybeTime] without the year — for list rows that already sit
/// under a month header, where "2026" only crowds out the text beside it.
String fmtDateCompact(DateTime d) => (d.hour == 0 && d.minute == 0)
    ? _dayMonth.format(d)
    : '${_dayMonth.format(d)}, ${_time.format(d)}';

/// A Count in moment (`Tx.countIn`) as the edit sheet's chip and the bulk
/// confirm show it: "Thu 1 Oct", with the time only when it isn't midnight
/// (see [fmtDateMaybeTime]).
String fmtCountIn(DateTime d) {
  final day = _weekdayDayMonth.format(d);
  return (d.hour == 0 && d.minute == 0) ? day : '$day, ${_time.format(d)}';
}

final DateFormat _weekdayDayMonth = DateFormat('EEE d MMM');
final DateFormat _weekdayDayMonthYear = DateFormat('EEE d MMM yyyy');

/// A review list's day label: Today, Yesterday, "Thu 15 Oct", with the year
/// outside the current one.
String fmtDayHeading(DateTime day, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final d = DateTime(day.year, day.month, day.day);
  if (d == today) return 'Today';
  if (d == DateTime(today.year, today.month, today.day - 1)) {
    return 'Yesterday';
  }
  return d.year == n.year
      ? _weekdayDayMonth.format(d)
      : _weekdayDayMonthYear.format(d);
}

/// A due date [days] ahead as words: "today", "tomorrow", "in 5 days".
/// Callers say "Overdue" themselves for a negative count.
String fmtInDays(int days) => days == 0
    ? 'today'
    : days == 1
    ? 'tomorrow'
    : 'in $days days';

/// Inclusive day range, collapsing whatever the two ends share:
/// "3 – 9 Aug 2026", "12 Jun – 3 Aug 2026", "20 Dec 2025 – 4 Jan 2026".
String fmtDateRange(DateTimeRange r) {
  final a = r.start;
  final b = r.end;
  if (a.year == b.year && a.month == b.month && a.day == b.day) {
    return fmtDate(a);
  }
  if (a.year == b.year && a.month == b.month) {
    return '${a.day} – ${fmtDate(b)}';
  }
  if (a.year == b.year) {
    return '${_dayMonth.format(a)} – ${fmtDate(b)}';
  }
  return '${fmtDate(a)} – ${fmtDate(b)}';
}
