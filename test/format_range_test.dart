import 'package:flutter/material.dart' show DateTimeRange;
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/utils/format.dart';

void main() {
  DateTimeRange r(DateTime a, DateTime b) => DateTimeRange(start: a, end: b);

  test('fmtDateRange collapses the shared parts of the two ends', () {
    expect(
      fmtDateRange(r(DateTime(2026, 8, 3), DateTime(2026, 8, 9))),
      '3 – 9 Aug 2026',
    );
    expect(
      fmtDateRange(r(DateTime(2026, 6, 12), DateTime(2026, 8, 3))),
      '12 Jun – 3 Aug 2026',
    );
    expect(
      fmtDateRange(r(DateTime(2025, 12, 20), DateTime(2026, 1, 4))),
      '20 Dec 2025 – 4 Jan 2026',
    );
    expect(
      fmtDateRange(r(DateTime(2026, 8, 3), DateTime(2026, 8, 3))),
      '3 Aug 2026',
    );
  });
}
