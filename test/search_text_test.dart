import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/utils/search_text.dart';

void main() {
  setUp(() {
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Tx manual({
    double amount = 1250,
    String note = 'lunch',
    String categoryId = 'food',
  }) => Tx(
    id: 'm1',
    type: TxType.expense,
    categoryId: categoryId,
    amount: amount,
    note: note,
    date: DateTime(2026, 7, 1),
  );

  test('normalizeSearchText flattens case and punctuation', () {
    expect(normalizeSearchText('  NETFLIX.COM  '), 'netflix com');
    expect(normalizeSearchText('Fd-No/12'), 'fd no 12');
    expect(normalizeSearchText('₹1,250.00'), '1 250 00');
  });

  test('amount matches as typed digits, with decimals, or grouped', () {
    final hay = searchHaystack(manual());
    expect(hay.contains(normalizeSearchText('1250')), isTrue);
    expect(hay.contains(normalizeSearchText('1250.00')), isTrue);
    expect(hay.contains(normalizeSearchText('1,250')), isTrue);
    expect(hay.contains(normalizeSearchText('9999')), isFalse);
  });

  test('category label and account name are searchable', () {
    final hay = searchHaystack(manual(), accountName: 'Salary Account');
    expect(hay.contains('food dining'), isTrue, reason: 'Food & Dining');
    expect(hay.contains('salary account'), isTrue);
  });

  test('punctuated SMS merchant matches the normalized deep-link query', () {
    final sms = Tx(
      id: 's1',
      type: TxType.expense,
      categoryId: 'entertainment',
      amount: 649,
      note: '',
      smsBody: 'Rs.649.00 debited from a/c XX1234 to NETFLIX.COM on 01-07-26.',
      date: DateTime(2026, 7, 1),
      source: TxSource.sms,
      sender: 'VM-HDFCBK',
    );
    final hay = searchHaystack(sms);
    // Top merchants passes the identity ("netflix com"), which a raw
    // substring match against "NETFLIX.COM" used to miss.
    expect(hay.contains('netflix com'), isTrue);
  });

  test('merchant alias is searchable alongside the raw text', () {
    final hay = searchHaystack(
      manual(note: 'fd no 12345'),
      merchantAlias: 'HDFC FD',
    );
    expect(hay.contains('hdfc fd'), isTrue);
    expect(hay.contains('fd no 12345'), isTrue);
  });
}
