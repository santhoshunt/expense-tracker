import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/utils/format.dart';

void main() {
  test('parseAmount reads human-typed money', () {
    expect(parseAmount('45000'), 45000);
    expect(parseAmount('45,000'), 45000);
    expect(parseAmount('₹ 1,50,000.50'), 150000.50);
    expect(parseAmount(' 12 500 '), 12500);
    expect(parseAmount('4800.25'), 4800.25);
  });

  test('parseAmount returns null for empty or unreadable input', () {
    // Callers rely on this: empty = "clear the value", unreadable = error.
    // double.tryParse alone made "45,000" indistinguishable from empty, so
    // setting a balance with commas silently CLEARED it instead.
    expect(parseAmount(''), isNull);
    expect(parseAmount('   '), isNull);
    expect(parseAmount('abc'), isNull);
    expect(parseAmount('12a'), isNull);
  });
}
