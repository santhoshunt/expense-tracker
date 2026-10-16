import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/services/refund_matching.dart';
import 'package:expense_tracker/services/transfer_pairing.dart';

/// Refund matching (1.42): which purchase a refund pays back, and when that
/// is sure enough to link without asking. Every merchant, number and
/// amount here is made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    FinanceProvider.useIsolateCodec = false;
  });

  const key = 'KAPBNK:4321';
  final sep25 = DateTime(2026, 9, 25, 18);
  final oct4 = DateTime(2026, 10, 4, 11);

  Tx buy(
    String id, {
    double amount = 1500,
    DateTime? date,
    String merchant = 'Kappa Store',
    String categoryId = 'shopping',
    String? acctKey = key,
    bool pending = false,
    double? myShare,
  }) => Tx(
    id: id,
    type: TxType.expense,
    categoryId: categoryId,
    amount: amount,
    note: '',
    smsBody: 'Rs.$amount debited from a/c XX4321 on 25-09-26 at $merchant.',
    date: date ?? sep25,
    source: TxSource.sms,
    sender: 'VM-KAPBNK',
    acctKey: acctKey,
    pending: pending,
    myShare: myShare,
  );

  Tx back(
    String id, {
    double amount = 1500,
    DateTime? date,
    String? body,
    TxSource source = TxSource.sms,
  }) => Tx(
    id: id,
    type: TxType.income,
    categoryId: 'other_income',
    amount: amount,
    note: source == TxSource.manual ? 'Kappa Store' : '',
    smsBody: source == TxSource.sms
        ? (body ??
              'Refund of Rs.$amount from Kappa Store on 04-10-26. Credited '
                  'to a/c XX4321.')
        : '',
    date: date ?? oct4,
    source: source,
    sender: 'VM-KAPBNK',
    acctKey: key,
  );

  List<RefundCandidate> candidates(Tx refund, List<Tx> rows) =>
      refundCandidatesFor(
        refund,
        rows,
        remainingOf: (p) => p.amount,
        counts: (_) => true,
      );

  group('isRefundWorded', () {
    test('matches refund and reversal wording, any case', () {
      for (final s in [
        'Refund of Rs.500 from Kappa Store',
        'Rs.500 REFUNDED to your a/c',
        'Reversal of txn Rs.500',
        'Txn Rs.500 has been reversed',
        'Rs.500 credited back to a/c XX4321',
      ]) {
        expect(isRefundWorded(s), isTrue, reason: s);
      }
    });

    test('never cashback, never inside another word', () {
      for (final s in [
        'Cashback of Rs.50 credited to a/c XX4321',
        'Rs.50 cash back credited back to your wallet',
        'Rs.500 credited to a/c XX4321 from Nu Refundables',
        'Rs.500 credited to a/c XX4321',
        '',
      ]) {
        expect(isRefundWorded(s), isFalse, reason: s);
      }
    });
  });

  group('refundCandidatesFor', () {
    test('the fixtures name one merchant', () {
      expect(merchantIdentityOf(buy('p')), 'kappa store');
      expect(merchantIdentityOf(back('r')), 'kappa store');
    });

    test('same merchant, then exact amount, then the closest date', () {
      final far = buy('far', date: DateTime(2026, 9, 1));
      final near = buy('near', date: DateTime(2026, 10, 1));
      final bigger = buy('bigger', amount: 2000, date: DateTime(2026, 10, 3));
      final otherShop = buy(
        'other',
        merchant: 'Lambda Books',
        date: DateTime(2026, 10, 3),
      );
      final c = candidates(back('r'), [far, otherShop, bigger, near]);
      expect(
        [for (final x in c) x.purchase.id],
        ['near', 'far', 'bigger', 'other'],
      );
      expect(c.first.sameMerchant, isTrue);
      expect(c.first.exactAmount, isTrue);
      expect(c[2].exactAmount, isFalse);
      // Same account, refund wording, another merchant.
      expect(c.last.sameMerchant, isFalse);
    });

    test('window: up to 60 days back, the same day allowed, never after', () {
      final r = back('r');
      final rows = [
        buy('in', date: oct4.subtract(const Duration(days: 60))),
        buy('out', date: DateTime(2026, 8, 4, 10)),
        buy('sameDay', date: DateTime(2026, 10, 4, 20)),
        buy('after', date: DateTime(2026, 10, 5, 9)),
      ];
      expect([for (final x in candidates(r, rows)) x.purchase.id]..sort(), [
        'in',
        'sameDay',
      ]);
    });

    test('skips pending, split, transfer, uncounted and used-up rows', () {
      final r = back('r');
      final rows = [
        buy('pending', pending: true),
        buy('split', myShare: 500),
        buy('transfer', categoryId: 'transfer_out'),
        buy('uncounted'),
        buy('usedUp'),
        buy('ok'),
      ];
      final c = refundCandidatesFor(
        r,
        rows,
        remainingOf: (p) => p.id == 'usedUp' ? 1000 : p.amount,
        counts: (p) => p.id != 'uncounted',
      );
      expect([for (final x in c) x.purchase.id], ['ok']);
    });

    test('no merchant: the same account only when worded as a refund', () {
      final plain = back(
        'plain',
        body: 'Rs.1500.00 credited to a/c XX4321 on 04-10-26.',
      );
      final worded = back(
        'worded',
        body: 'Rs.1500.00 refunded to a/c XX4321 on 04-10-26.',
      );
      final p = buy('p');
      expect(candidates(plain, [p]), isEmpty);
      final c = candidates(worded, [p]);
      expect(c.single.sameMerchant, isFalse);
      // Never sure without the merchant.
      expect(sureRefundPurchase(worded, c), isNull);
    });
  });

  group('sureRefundPurchase', () {
    test('one same-merchant exact match from a refund alert', () {
      final r = back('r');
      final p = buy('p');
      expect(sureRefundPurchase(r, candidates(r, [p]))!.id, 'p');
    });

    test(
      'two equal purchases, a partial refund, or a manual row: not sure',
      () {
        final r = back('r');
        expect(
          sureRefundPurchase(
            r,
            candidates(r, [buy('a'), buy('b', date: DateTime(2026, 9, 20))]),
          ),
          isNull,
        );
        final part = back('part', amount: 500);
        final c = candidates(part, [buy('p')]);
        expect(c, hasLength(1));
        expect(sureRefundPurchase(part, c), isNull);
        final manual = back('m', source: TxSource.manual);
        final mc = candidates(manual, [buy('p')]);
        expect(mc.single.sameMerchant, isTrue);
        expect(sureRefundPurchase(manual, mc), isNull);
      },
    );
  });

  group('FinanceProvider.refundSuggestions', () {
    test('the best purchase per refund, past dismissed ones', () async {
      SharedPreferences.setMockInitialValues({
        'transactions_v1': jsonEncode([
          buy('near', date: DateTime(2026, 10, 1)).toJson(),
          buy('far', date: DateTime(2026, 9, 10)).toJson(),
        ]),
      });
      final finance = FinanceProvider();
      await finance.load();
      final r = back('r', amount: 500);
      final s = finance.refundSuggestions([r], const {});
      expect(s.single.purchase.id, 'near');
      expect(s.single.key, 'refund|r|near');
      final next = finance.refundSuggestions([r], {'refund|r|near'});
      expect(next.single.purchase.id, 'far');
      // Already linked rows and expenses are not offered.
      expect(
        finance.refundSuggestions([r.copyWith(refundOf: 'near'), buy('x')], {}),
        isEmpty,
      );
    });

    test('a purchase partly refunded offers only what it has left', () async {
      SharedPreferences.setMockInitialValues({
        'transactions_v1': jsonEncode([
          buy('p').toJson(),
          back(
            'first',
            amount: 1000,
            date: DateTime(2026, 9, 30),
          ).copyWith(refundOf: 'p').toJson(),
        ]),
      });
      final finance = FinanceProvider();
      await finance.load();
      final p = finance.transactions.firstWhere((t) => t.id == 'p');
      expect(finance.refundableLeftOf(p), 500);
      expect(finance.refundSuggestions([back('r', amount: 600)], {}), isEmpty);
      expect(
        finance
            .refundSuggestions([back('r', amount: 500)], {})
            .single
            .purchase
            .id,
        'p',
      );
    });
  });

  group('cashback', () {
    test('is never a refund: no candidates, whatever the wording', () {
      final p = buy('p', amount: 50);
      for (final body in [
        'Cashback of Rs.50 from Kappa Store credited to a/c XX4321.',
        'Rs.50 CASH BACK from Kappa Store refunded to a/c XX4321.',
      ]) {
        final r = back('cb', amount: 50, body: body);
        expect(candidates(r, [p]), isEmpty, reason: body);
      }
      // The same alert without the word still finds the purchase.
      final r = back(
        'r',
        amount: 50,
        body: 'Refund of Rs.50 from Kappa Store credited to a/c XX4321.',
      );
      expect(candidates(r, [p]).single.purchase.id, 'p');
    });
  });

  group('Tx.refundOf', () {
    test('round-trips through JSON, and only when set', () {
      final r = back('r').copyWith(refundOf: 'p');
      final json = jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>;
      expect(json['refundOf'], 'p');
      expect(Tx.fromJson(json).refundOf, 'p');
      expect(back('r').toJson().containsKey('refundOf'), isFalse);
      expect(Tx.fromJson({...json, 'refundOf': 42}).refundOf, isNull);
    });

    test('copyWith keeps or clears it; the legacy migration carries it', () {
      final r = back('r').copyWith(refundOf: 'p');
      expect(r.copyWith(amount: 10).refundOf, 'p');
      expect(r.copyWith(clearRefundOf: true).refundOf, isNull);
      final legacy = Tx(
        id: 'old',
        type: TxType.income,
        categoryId: 'other_income',
        amount: 100,
        note: 'Refund of Rs.100 from Kappa Store',
        date: oct4,
        source: TxSource.sms,
        refundOf: 'p',
      );
      final migrated = legacy.migrateSmsBodyFromNote();
      expect(migrated.smsBody, isNotEmpty);
      expect(migrated.refundOf, 'p');
    });
  });

  group('transfer pairs', () {
    final out = Tx(
      id: 'out',
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: 1500,
      note: '',
      smsBody: 'Rs.1500.00 debited from a/c XX1111 on 04-10-26.',
      date: oct4,
      source: TxSource.sms,
      acctKey: 'NUBANK:1111',
      pending: true,
    );

    List<PairSuggestion> pairs(Tx incoming) => suggestTransferPairs(
      [out, incoming],
      dismissed: const {},
      accountFor: (_) => null,
    );

    test('a plain credit elsewhere is still offered as a transfer', () {
      final inn = back(
        'in',
        body: 'Rs.1500.00 credited to a/c XX4321 on 04-10-26.',
      );
      expect(pairs(inn), hasLength(1));
    });

    test('a refund is never offered as the other leg', () {
      expect(pairs(back('in')), isEmpty);
      final linked = back(
        'in',
        body: 'Rs.1500.00 credited to a/c XX4321 on 04-10-26.',
      ).copyWith(refundOf: 'p');
      expect(pairs(linked), isEmpty);
    });
  });
}
