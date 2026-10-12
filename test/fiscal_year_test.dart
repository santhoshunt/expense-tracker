import 'package:expense_tracker/utils/fiscal_year.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('yearStartOf: April start puts January to March in the year before', () {
    expect(yearStartOf(DateTime(2027, 3, 31), 4), 2026);
    expect(yearStartOf(DateTime(2026, 4, 1), 4), 2026);
    expect(yearStartOf(DateTime(2026, 12, 31), 4), 2026);
    expect(yearStartOf(DateTime(2026, 1, 1), 1), 2026);
    expect(yearStartOf(DateTime(2026, 12, 31), 1), 2026);
  });

  test('yearMonths runs across the calendar year boundary in order', () {
    final fy = yearMonths(2026, 4);
    expect(fy.length, 12);
    expect(fy.first, DateTime(2026, 4));
    expect(fy[8], DateTime(2026, 12));
    expect(fy[9], DateTime(2027, 1));
    expect(fy.last, DateTime(2027, 3));
    expect(yearMonths(2026, 1).last, DateTime(2026, 12));
  });

  test('yearBounds ends on the last day of the twelfth month', () {
    final fy = yearBounds(2026, 4);
    expect(fy.first, DateTime(2026, 4, 1));
    expect(fy.last, DateTime(2027, 3, 31));
    final cal = yearBounds(2028, 1);
    expect(cal.first, DateTime(2028, 1, 1));
    expect(cal.last, DateTime(2028, 12, 31));
  });

  test('yearLabel', () {
    expect(yearLabel(2026, 1), '2026');
    expect(yearLabel(2026, 4), 'FY 2026-27');
    expect(yearLabel(2009, 4), 'FY 2009-10');
    expect(yearLabel(2099, 4), 'FY 2099-00');
  });
}
