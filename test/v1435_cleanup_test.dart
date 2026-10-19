import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/services/transfer_pairing.dart';

import 'accounts_test_utils.dart';

/// The shared row-label helpers, the account counts beside the net
/// balance totals, and the review queue's cache. Invented names, numbers
/// and amounts only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    FinanceProvider.useIsolateCodec = false;
  });

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  group('row labels', () {
    Tx manual({String payee = '', String note = ''}) => Tx(
      id: 'm',
      type: TxType.expense,
      categoryId: 'food',
      amount: 90,
      note: note,
      date: DateTime(2026, 10, 3, 13),
      payee: payee,
    );

    final sms = Tx(
      id: 'sms1',
      type: TxType.expense,
      categoryId: 'food',
      amount: 90,
      note: '',
      date: DateTime(2026, 10, 3, 13),
      source: TxSource.sms,
      smsBody: 'Rs.90.00 spent at DEMO KIOSK on 03-10-26. -Demo Bank',
    );

    test('noteFirstLine keeps the first line, trimmed', () {
      expect(noteFirstLine('  Sample Mess \nsecond line'), 'Sample Mess');
      expect(noteFirstLine('one line'), 'one line');
      expect(noteFirstLine(''), '');
      expect(noteFirstLine('\nafter a blank'), '');
    });

    test('a short payee gives way to the note in labels, not in titles', () {
      final t = manual(payee: 'AB', note: 'kappa cafe\nlunch');
      expect(merchantLabelOrNull(t), 'Kappa Cafe Lunch');
      expect(rowTitleOf(t), 'AB');
      // With no note the short payee stands in both.
      expect(merchantLabelOrNull(manual(payee: 'AB')), 'AB');
    });

    test('an alert names the merchant in labels, a payee in titles', () {
      final paid = sms.copyWith(payee: 'Kappa Cafe');
      expect(merchantLabelOrNull(paid), 'Demo Kiosk');
      expect(rowTitleOf(paid), 'Kappa Cafe');
      expect(merchantLabelOrNull(sms), 'Demo Kiosk');
      expect(rowTitleOf(sms), 'Demo Kiosk');
    });

    test('an alias wins in both, and an empty one is ignored', () {
      String? alias(String id) => switch (id) {
        'kappa cafe' => 'Kappa',
        _ => '',
      };
      final t = manual(payee: 'Kappa Cafe', note: 'lunch');
      expect(merchantLabelOrNull(t, alias: alias), 'Kappa');
      expect(rowTitleOf(t, alias: alias), 'Kappa');
      final other = manual(payee: 'Sample Mess');
      expect(merchantLabelOrNull(other, alias: alias), 'Sample Mess');
      expect(rowTitleOf(other, alias: alias), 'Sample Mess');
    });

    test('recentPayees offers a payee-less row its note line', () async {
      final p = await loaded();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 60,
        note: 'Sample Mess\nthali',
        date: DateTime(2026, 10, 2, 13),
      );
      expect(p.recentPayees(TxType.expense), ['Sample Mess']);
    });
  });

  group('account counts', () {
    test('each count covers exactly the accounts its total sums', () async {
      final p = await loaded();
      await p.importData({
        'app': 'expense_tracker',
        'version': 21,
        'transactions': <Object>[],
        'accounts': [
          {
            'id': 'acc_gone',
            'name': 'Demo Bank',
            'type': 'bank',
            'keys': ['DEMO:4321'],
          },
        ],
      }, replace: false);
      final bank = await p.addAccount(
        name: 'Sample Bank',
        type: AccountType.bank,
      );
      await p.setManualBalance(bank, 1000);
      final linked = await p.addAccount(
        name: 'Sample Debit',
        type: AccountType.debitCard,
      );
      expect(await p.linkDebitCard(linked, bank), isTrue);
      await p.addAccount(name: 'Loose Debit', type: AccountType.debitCard);
      await p.addAccount(name: 'Card No Limit', type: AccountType.creditCard);
      final owing = await p.addAccount(
        name: 'Card Owing',
        type: AccountType.creditCard,
      );
      await p.setManualBalance(owing, 2000);
      await p.addAccount(name: 'Sample FD', type: AccountType.savings);

      expect(p.isOrphanedAccount(p.accountById('acc_gone')!), isTrue);
      // The bank and the loose debit card: not the emptied bank, not the
      // linked card.
      expect(p.bankBalanceCount, 2);
      expect(p.bankBalanceTotal, 1000);
      // Only the card with a known outstanding adds to the total.
      expect(p.cardOutstandingCount, 1);
      expect(p.cardOutstandingTotal, 2000);
      expect(p.cardsMissingLimit, 1);
      // Every open bank-like account and card, emptied or not.
      expect(p.netAccountCount, 5);
    });

    testWidgets('a lone card with no limit is one net account', (tester) async {
      final p = await loaded();
      await p.addAccount(name: 'Card No Limit', type: AccountType.creditCard);
      expect(p.netAccountCount, 1);
      expect(p.bankBalanceCount, 0);
      expect(p.cardOutstandingCount, 0);
      await tester.pumpWidget(accountsApp(p));
      await tester.pumpAndSettle();
      expect(find.text('Net across 1 bank or card account'), findsOneWidget);
    });
  });

  group('review queue cache', () {
    Tx leg(
      String id,
      TxType type,
      String acct, {
      bool pending = true,
      double amount = 500,
    }) => Tx(
      id: id,
      type: type,
      categoryId: type == TxType.income ? 'other_income' : 'other_expense',
      amount: amount,
      note: '',
      smsBody: 'Rs.$amount moved on a/c $acct. -Demo Bank',
      date: DateTime(2026, 9, 10, 10),
      source: TxSource.sms,
      acctKey: acct,
      pending: pending,
    );

    test('a same-size dismissed set with other keys rebuilds', () async {
      final p = await loaded();
      await p.restoreTransactions([
        leg('out', TxType.expense, 'DEMO:1111'),
        leg('in', TxType.income, 'DEMO:2222'),
      ]);
      final key = pairSuggestionKey('out', 'in');
      expect(p.reviewQueue({'other|key'}).pairs.single.key, key);
      // Same size, different contents, no notification between.
      expect(p.reviewQueue({key}).pairs, isEmpty);
      expect(p.reviewQueue({'other|key'}).pairs.single.key, key);
      // Equal contents in a new set reuse the queue.
      final q = p.reviewQueue({'other|key'});
      expect(identical(p.reviewQueue({'other|key'}), q), isTrue);
    });

    test('a confirmed leg on the same amount still pairs', () async {
      final p = await loaded();
      await p.restoreTransactions([
        leg('out', TxType.expense, 'DEMO:1111'),
        leg('in', TxType.income, 'DEMO:2222', pending: false),
        leg('x1', TxType.income, 'DEMO:2222', pending: false, amount: 77),
        leg('x2', TxType.expense, 'DEMO:1111', pending: false, amount: 88),
      ]);
      expect(
        p.reviewQueue(const {}).pairs.single.key,
        pairSuggestionKey('out', 'in'),
      );
    });

    test('with no refund review ids the badge is the pending count', () async {
      final p = await loaded();
      await p.restoreTransactions([
        leg('out', TxType.expense, 'DEMO:1111'),
        leg('in', TxType.income, 'DEMO:2222'),
        leg('o2', TxType.expense, 'DEMO:1111', amount: 40),
      ]);
      expect(p.refundReviewIds, isEmpty);
      expect(p.reviewCount(const {}), p.pendingCount);
      expect(p.reviewCount(const {}), p.reviewQueue(const {}).badgeCount);
    });
  });
}
