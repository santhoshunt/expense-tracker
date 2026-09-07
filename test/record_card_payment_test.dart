import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Tx row(
    String id,
    TxType type,
    double amount, {
    required String acct,
    required DateTime date,
    bool pending = false,
    double? balanceAfter,
  }) => Tx(
    id: id,
    type: type,
    categoryId: type == TxType.expense ? 'other_expense' : 'other_income',
    amount: amount,
    note: '',
    smsBody: 'Rs.$amount ${type == TxType.expense ? 'debited' : 'credited'}',
    date: date,
    source: TxSource.sms,
    sender: 'VM-HDFCBK',
    acctKey: acct,
    pending: pending,
    balanceAfter: balanceAfter,
  );

  /// Card (limit ₹1,00,000) with an Avl-Lmt anchor of ₹60,000 on 1 Jul
  /// (outstanding 40,000) and a ₹5,000 spend on 5 Jul → outstanding 45,000.
  /// A pending ₹40,000 bank debit on 3 Jul is the payment's bank leg.
  Future<FinanceProvider> seeded({List<Tx> extra = const []}) async {
    SharedPreferences.setMockInitialValues({
      'transactions_v1': jsonEncode([
        for (final t in [
          row(
            'anchor',
            TxType.expense,
            1000,
            acct: 'HDFC:3010',
            date: DateTime(2026, 7, 1, 10),
            balanceAfter: 60000,
          ),
          row(
            'spend',
            TxType.expense,
            5000,
            acct: 'HDFC:3010',
            date: DateTime(2026, 7, 5, 10),
          ),
          row(
            'bankDebit',
            TxType.expense,
            40000,
            acct: 'HDFC:1111',
            date: DateTime(2026, 7, 3, 9),
            pending: true,
          ),
          ...extra,
        ])
          t.toJson(),
      ]),
    });
    final p = FinanceProvider();
    await p.load();
    Future<String> account(String name, AccountType type, String key) async {
      final existing = p.accountForKey(key);
      if (existing != null) return existing.id;
      final id = await p.addAccount(name: name, type: type);
      expect(await p.addAccountKey(id, key), isTrue);
      return id;
    }

    await account('HDFC Bank', AccountType.bank, 'HDFC:1111');
    final cardId = await account('Card', AccountType.creditCard, 'HDFC:3010');
    await account('Card 2', AccountType.creditCard, 'HDFC:4020');
    await p.setCreditLimit(cardId, 100000);
    await p.setCardCycle(cardId, dueDay: 10);
    return p;
  }

  test(
    'drops outstanding by the payment and pairs the lone bank debit',
    () async {
      final p = await seeded();
      final card = p.accountForKey('HDFC:3010')!;
      expect(
        p.accountOutstanding(card),
        45000,
        reason: 'anchor 40k + 5k spend',
      );

      final due = DateTime(2026, 7, 10);
      final result = await p.recordCardPayment(
        accountId: card.id,
        amount: 40000,
        paidOn: DateTime(2026, 7, 3, 12),
        due: due,
      );
      expect(result, isNotNull);
      expect(result!.pairId, isNotNull, reason: 'exactly one matching debit');
      expect(result.bankLegBefore?.id, 'bankDebit');
      expect(result.prevPaidMonth, isNull);

      // Outstanding: 40,000 anchor + 5,000 spend − 40,000 payment.
      expect(p.accountOutstanding(card), 5000);
      expect(p.accountById(card.id)!.billPaidMonth, '2026-07');

      final payment = p.transactions.singleWhere((t) => t.id == result.txId);
      expect(payment.categoryId, 'card_payment');
      expect(payment.pairId, result.pairId);
      expect(p.accountForKey(payment.acctKey)!.id, card.id);

      final bankLeg = p.transactions.singleWhere((t) => t.id == 'bankDebit');
      expect(bankLeg.categoryId, 'card_bill');
      expect(bankLeg.pairId, result.pairId);
      expect(bankLeg.pending, isFalse, reason: 'pairing confirms the leg');

      // Neither leg is spend or income.
      final month = DateTime(2026, 7);
      expect(p.expenseInMonth(month), 6000, reason: 'card spends only');
      expect(p.incomeInMonth(month), 0);
    },
  );

  test('undo restores the ledger, the bank leg and the paid flag', () async {
    final p = await seeded();
    final card = p.accountForKey('HDFC:3010')!;
    final result = (await p.recordCardPayment(
      accountId: card.id,
      amount: 40000,
      paidOn: DateTime(2026, 7, 3, 12),
      due: DateTime(2026, 7, 10),
    ))!;

    // The snackbar Undo sequence.
    await p.deleteTransaction(result.txId);
    await p.restoreEditedTransactions([result.bankLegBefore!]);
    await p.setCardBillPaidMonth(card.id, result.prevPaidMonth);

    expect(p.accountOutstanding(card), 45000);
    expect(p.accountById(card.id)!.billPaidMonth, isNull);
    // Back to pending, so it lives in the review queue again.
    final bankLeg = p.pendingTransactions.singleWhere(
      (t) => t.id == 'bankDebit',
    );
    expect(bankLeg.categoryId, 'other_expense');
    expect(bankLeg.pairId, isNull);
    expect(p.transactions.any((t) => t.id == result.txId), isFalse);
  });

  test('two equal candidates → payment recorded but nothing paired', () async {
    final p = await seeded(
      extra: [
        row(
          'bankDebit2',
          TxType.expense,
          40000,
          acct: 'HDFC:1111',
          date: DateTime(2026, 7, 4, 9),
          pending: true,
        ),
      ],
    );
    final card = p.accountForKey('HDFC:3010')!;
    final result = (await p.recordCardPayment(
      accountId: card.id,
      amount: 40000,
      paidOn: DateTime(2026, 7, 3, 12),
      due: DateTime(2026, 7, 10),
    ))!;
    expect(result.pairId, isNull);
    expect(result.bankLegBefore, isNull);
    // The payment row still lowers outstanding.
    expect(p.accountOutstanding(card), 5000);
    expect(p.accountById(card.id)!.billPaidMonth, '2026-07');
  });

  test('a same-amount debit on another card is never the bank leg', () async {
    final p = await seeded(
      extra: [
        // Replaces nothing: the true bank debit is out of the date window.
        row(
          'cardSpend',
          TxType.expense,
          2500,
          acct: 'HDFC:4020',
          date: DateTime(2026, 7, 3, 8),
        ),
      ],
    );
    final card = p.accountForKey('HDFC:3010')!;
    final result = (await p.recordCardPayment(
      accountId: card.id,
      amount: 2500,
      paidOn: DateTime(2026, 7, 3, 12),
      due: DateTime(2026, 7, 10),
    ))!;
    expect(result.pairId, isNull, reason: 'only candidate sits on a card');
  });

  test(
    'payment dated before the anchor leaves outstanding unchanged',
    () async {
      final p = await seeded();
      final card = p.accountForKey('HDFC:3010')!;
      final result = (await p.recordCardPayment(
        accountId: card.id,
        amount: 40000,
        paidOn: DateTime(2026, 6, 25, 12),
        due: DateTime(2026, 7, 10),
      ))!;
      // The 1 Jul Avl-Lmt anchor already reflected any earlier payment; a row
      // behind it must not double-subtract. (No bank debit within 2 days
      // either, so nothing pairs.)
      expect(result.pairId, isNull);
      expect(p.accountOutstanding(card), 45000);
      expect(p.accountById(card.id)!.billPaidMonth, '2026-07');
    },
  );

  test('rejects non-cards and bad amounts', () async {
    final p = await seeded();
    final bank = p.accountForKey('HDFC:1111')!;
    final card = p.accountForKey('HDFC:3010')!;
    expect(
      await p.recordCardPayment(
        accountId: bank.id,
        amount: 100,
        paidOn: DateTime(2026, 7, 3),
        due: DateTime(2026, 7, 10),
      ),
      isNull,
    );
    expect(
      await p.recordCardPayment(
        accountId: card.id,
        amount: 0,
        paidOn: DateTime(2026, 7, 3),
        due: DateTime(2026, 7, 10),
      ),
      isNull,
    );
    expect(
      await p.recordCardPayment(
        accountId: 'nope',
        amount: 100,
        paidOn: DateTime(2026, 7, 3),
        due: DateTime(2026, 7, 10),
      ),
      isNull,
    );
    expect(
      p.transactions.length + p.pendingTransactions.length,
      3,
      reason: 'nothing was added',
    );
  });
}
