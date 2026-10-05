import 'package:expense_tracker/utils/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a negative amount takes the minus sign, not a hyphen', () {
    expect(fmtMoney(-1250), '−${fmtMoney(1250)}');
    expect(fmtMoneyCompact(-60000), '−${fmtMoneyCompact(60000)}');
    expect(fmtMoney(-1250).contains('-'), isFalse);
  });

  test('a negative that rounds to zero prints as plain zero', () {
    expect(fmtMoney(-0.0), fmtMoney(0));
    expect(fmtMoney(-0.001), fmtMoney(0));
    expect(fmtMoneyCompact(-0.0), fmtMoneyCompact(0));
  });
}
