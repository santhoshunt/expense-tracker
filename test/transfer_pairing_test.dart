import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/services/transfer_pairing.dart';

void main() {
  setUp(() {
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  final bank = Account(
    id: 'bank',
    name: 'HDFC',
    type: AccountType.bank,
    keys: {'HDFC:1111'},
  );
  final fd = Account(
    id: 'fd',
    name: 'FD',
    type: AccountType.savings,
    keys: {'HDFC:2222'},
  );
  final card = Account(
    id: 'card',
    name: 'Card',
    type: AccountType.creditCard,
    keys: {'HDFC:3010'},
  );
  Account? accountFor(String? key) => switch (key) {
    'HDFC:1111' => bank,
    'HDFC:2222' => fd,
    'HDFC:3010' => card,
    _ => null,
  };

  var seq = 0;
  Tx row(
    TxType type,
    double amount,
    DateTime date, {
    String? acct,
    bool pending = true,
    bool spam = false,
    String? pairId,
  }) => Tx(
    id: 't${seq++}',
    type: type,
    categoryId: type == TxType.expense ? 'other_expense' : 'other_income',
    amount: amount,
    note: '',
    date: date,
    source: TxSource.sms,
    acctKey: acct,
    pending: pending,
    suspectedSpam: spam,
    pairId: pairId,
  );

  final d = DateTime(2026, 9, 1, 10);

  List<PairSuggestion> run(List<Tx> rows, {Set<String> dismissed = const {}}) =>
      suggestTransferPairs(rows, dismissed: dismissed, accountFor: accountFor);

  test('bank debit + savings credit within two days → savings pair', () {
    final out = row(TxType.expense, 5000, d, acct: 'HDFC:1111');
    final inn = row(
      TxType.income,
      5000,
      d.add(const Duration(days: 1)),
      acct: 'HDFC:2222',
    );
    final s = run([out, inn]).single;
    expect(s.out.id, out.id);
    expect(s.incoming.id, inn.id);
    expect(s.kind, PairKind.savings);
    expect(pairCategoriesFor(s.kind), (
      out: kSavingsTransferCategoryId,
      incoming: 'transfer_in',
    ));
  });

  test('kind follows the receiving account', () {
    final out = row(TxType.expense, 100, d, acct: 'HDFC:1111');
    expect(
      run([out, row(TxType.income, 100, d, acct: 'HDFC:3010')]).single.kind,
      PairKind.cardPayment,
    );
    expect(
      run([out, row(TxType.income, 100, d, acct: null)]).single.kind,
      PairKind.transfer,
    );
  });

  test(
    'rejections: amount, window, accounts, spam, paired, dismissed, card sender',
    () {
      final out = row(TxType.expense, 100, d, acct: 'HDFC:1111');
      // Amount off by a paise.
      expect(
        run([out, row(TxType.income, 100.01, d, acct: 'HDFC:2222')]),
        isEmpty,
      );
      // Three days apart.
      expect(
        run([
          out,
          row(
            TxType.income,
            100,
            d.add(const Duration(days: 3)),
            acct: 'HDFC:2222',
          ),
        ]),
        isEmpty,
      );
      // Same account, or both unknown.
      expect(
        run([out, row(TxType.income, 100, d, acct: 'HDFC:1111')]),
        isEmpty,
      );
      expect(
        run([row(TxType.expense, 100, d), row(TxType.income, 100, d)]),
        isEmpty,
      );
      // Spam leg.
      expect(
        run([out, row(TxType.income, 100, d, acct: 'HDFC:2222', spam: true)]),
        isEmpty,
      );
      // Already paired leg.
      expect(
        run([out, row(TxType.income, 100, d, acct: 'HDFC:2222', pairId: 'p')]),
        isEmpty,
      );
      // Neither pending.
      expect(
        run([
          row(TxType.expense, 100, d, acct: 'HDFC:1111', pending: false),
          row(TxType.income, 100, d, acct: 'HDFC:2222', pending: false),
        ]),
        isEmpty,
      );
      // Card-side debit is a refund, not a transfer.
      expect(
        run([
          row(TxType.expense, 100, d, acct: 'HDFC:3010'),
          row(TxType.income, 100, d, acct: 'HDFC:1111'),
        ]),
        isEmpty,
      );
      // Dismissed, in either id order.
      final inn = row(TxType.income, 100, d, acct: 'HDFC:2222');
      expect(
        run([out, inn], dismissed: {pairSuggestionKey(inn.id, out.id)}),
        isEmpty,
      );
    },
  );

  test('greedy: closest dates win and each row appears once', () {
    final out = row(TxType.expense, 100, d, acct: 'HDFC:1111');
    final near = row(
      TxType.income,
      100,
      d.add(const Duration(hours: 2)),
      acct: 'HDFC:2222',
    );
    final far = row(
      TxType.income,
      100,
      d.add(const Duration(days: 1)),
      acct: 'HDFC:2222',
    );
    final result = run([far, out, near]);
    expect(result, hasLength(1));
    expect(result.single.incoming.id, near.id);
  });

  test('pairSuggestionKey is order independent', () {
    expect(pairSuggestionKey('b', 'a'), pairSuggestionKey('a', 'b'));
  });
}
