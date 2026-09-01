import 'package:intl/intl.dart';

final NumberFormat _currency = NumberFormat.currency(
  symbol: '₹',
  decimalDigits: 2,
);
final NumberFormat _currencyCompact = NumberFormat.compactCurrency(
  symbol: '₹',
  decimalDigits: 1,
);
final DateFormat _date = DateFormat('d MMM yyyy');
final DateFormat _dateTime = DateFormat('d MMM yyyy, h:mm a');
final DateFormat _dayMonth = DateFormat('d MMM');
final DateFormat _time = DateFormat('h:mm a');
final DateFormat _monthYear = DateFormat('MMMM yyyy');

String fmtMoney(double v) => _currency.format(v);
String fmtMoneyCompact(double v) => _currencyCompact.format(v);
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
  return double.tryParse(cleaned);
}

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
