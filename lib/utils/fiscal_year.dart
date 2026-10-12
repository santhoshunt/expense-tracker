/// Year math for the dashboard's Year view and the year report. Pure Dart.
///
/// A year is named by its first month: `(startYear, startMonth)`. January
/// gives the calendar year; April gives the Indian financial year, April of
/// `startYear` to March of the next.
library;

/// The first calendar year of the year that holds [d].
int yearStartOf(DateTime d, int startMonth) =>
    d.month >= startMonth ? d.year : d.year - 1;

/// The 12 months of the year starting [startMonth] of [startYear], in order.
List<DateTime> yearMonths(int startYear, int startMonth) => [
  for (var i = 0; i < 12; i++) DateTime(startYear, startMonth + i),
];

/// The year's first and last day, both inclusive, at midnight.
({DateTime first, DateTime last}) yearBounds(int startYear, int startMonth) => (
  first: DateTime(startYear, startMonth),
  last: DateTime(startYear, startMonth + 12, 0),
);

/// "2026" for a calendar year; "FY 2026-27" for one starting in any other
/// month.
String yearLabel(int startYear, int startMonth) {
  if (startMonth == 1) return '$startYear';
  final next = ((startYear + 1) % 100).toString().padLeft(2, '0');
  return 'FY $startYear-$next';
}
