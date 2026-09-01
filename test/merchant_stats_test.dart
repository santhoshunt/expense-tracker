import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/services/merchant_stats.dart';

void main() {
  setUp(() {
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  var seq = 0;

  Tx sms({
    required double amount,
    required DateTime date,
    String merchant = 'SWIGGY',
    TxType type = TxType.expense,
    String categoryId = 'food',
    bool spam = false,
    double? myShare,
  }) => Tx(
    id: 't${seq++}',
    type: type,
    categoryId: categoryId,
    amount: amount,
    note: '',
    smsBody: 'Rs.$amount debited from a/c XX1234 to $merchant on 01-01-26.',
    date: date,
    source: TxSource.sms,
    sender: 'VM-HDFCBK',
    suspectedSpam: spam,
    myShare: myShare,
  );

  final month = DateTime(2026, 7);

  test('sums spendAmount per merchant with counts, largest first', () {
    final result = topMerchants([
      sms(amount: 300, date: DateTime(2026, 7, 2)),
      sms(amount: 200, date: DateTime(2026, 7, 10)),
      sms(amount: 900, date: DateTime(2026, 7, 5), merchant: 'AMAZON'),
    ], month: month);
    expect(result, hasLength(2));
    expect(result.first.label, 'Amazon');
    expect(result.first.total, 900);
    expect(result.first.count, 1);
    expect(result.last.label, 'Swiggy');
    expect(result.last.total, 500);
    expect(result.last.count, 2);
  });

  test('split transactions count only the own share', () {
    final result = topMerchants([
      sms(amount: 1000, date: DateTime(2026, 7, 2), myShare: 250),
    ], month: month);
    expect(result.single.total, 250);
  });

  test('only the requested month counts', () {
    final result = topMerchants([
      sms(amount: 100, date: DateTime(2026, 6, 30)),
      sms(amount: 200, date: DateTime(2026, 7, 1)),
      sms(amount: 400, date: DateTime(2026, 8, 1)),
    ], month: month);
    expect(result.single.total, 200);
  });

  test('digits-only merchants (phone/VPA numbers) are excluded', () {
    final result = topMerchants([
      sms(amount: 3000, date: DateTime(2026, 7, 2), merchant: '9215676766'),
    ], month: month);
    expect(result, isEmpty);
  });

  test('income, spam, transfers and identity-less rows are excluded', () {
    final result = topMerchants([
      sms(amount: 100, date: DateTime(2026, 7, 2), type: TxType.income),
      sms(amount: 100, date: DateTime(2026, 7, 3), spam: true),
      sms(
        amount: 100,
        date: DateTime(2026, 7, 4),
        categoryId: kSavingsTransferCategoryId,
      ),
      // Manual row with no note → no identity.
      Tx(
        id: 't${seq++}',
        type: TxType.expense,
        categoryId: 'food',
        amount: 100,
        note: '',
        date: DateTime(2026, 7, 5),
      ),
    ], month: month);
    expect(result, isEmpty);
  });

  test('manual rows aggregate by normalized note', () {
    Tx manual(double amount, int day, String note) => Tx(
      id: 't${seq++}',
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: amount,
      note: note,
      date: DateTime(2026, 7, day),
    );
    final result = topMerchants([
      manual(100, 2, 'Gym fees'),
      manual(150, 20, ' gym FEES '),
    ], month: month);
    expect(result.single.total, 250);
    expect(result.single.count, 2);
    // Label comes from the newest row's note, title-cased.
    expect(result.single.label, 'Gym Fees');
  });

  test('limit keeps only the biggest buckets', () {
    final result = topMerchants(
      [
        for (var i = 0; i < 9; i++)
          sms(
            amount: 100.0 + i,
            date: DateTime(2026, 7, 1 + i),
            merchant: 'SHOP$i',
          ),
      ],
      month: month,
      limit: 3,
    );
    expect(result, hasLength(3));
    expect(result.first.total, 108);
  });
}
