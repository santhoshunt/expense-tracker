import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/sms_parser.dart';

ParsedTxn bankSpend({
  required String sender,
  required double amount,
  required String last4,
  required double avlBal,
  required DateTime date,
  String ref = '',
}) => ParsedTxn(
  type: TxType.expense,
  amount: amount,
  merchant: 'SHOP',
  date: date,
  ref: ref.isEmpty ? null : ref,
  categoryId: 'other_expense',
  sender: sender,
  rawBody: 'Rs.$amount debited from a/c XX$last4. Avl Bal Rs.$avlBal.',
  acctKey: '${SmsTxnParser.bankCodeOf(sender)}:$last4',
  balanceAfter: avlBal,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('imports auto-create one account per distinct bank+last4', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    await p.addImported([
      bankSpend(
        sender: 'VM-HDFCBK',
        amount: 100,
        last4: '1234',
        avlBal: 5000,
        date: DateTime(2026, 7, 1),
        ref: 'R1',
      ),
      bankSpend(
        sender: 'VM-HDFCBK',
        amount: 200,
        last4: '5678',
        avlBal: 9000,
        date: DateTime(2026, 7, 2),
        ref: 'R2',
      ),
    ]);
    expect(p.accounts.length, 2);
    expect(p.accounts.map((a) => a.name), contains('HDFC ••1234'));
  });

  test('bank balance uses latest Avl Bal, not a sum', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    await p.addImported([
      bankSpend(
        sender: 'VM-HDFCBK',
        amount: 100,
        last4: '1234',
        avlBal: 5000,
        date: DateTime(2026, 7, 1),
        ref: 'R1',
      ),
      bankSpend(
        sender: 'VM-HDFCBK',
        amount: 200,
        last4: '1234',
        avlBal: 4800,
        date: DateTime(2026, 7, 3),
        ref: 'R2',
      ),
    ]);
    // Confirm both so they count.
    for (final t in p.pendingTransactions.toList()) {
      await p.confirmTransaction(t.id);
    }
    final acc = p.accounts.single;
    expect(p.accountBalance(acc), 4800); // latest, not 5000 or a sum
  });

  test('card outstanding = limit − available', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    await p.addImported([
      ParsedTxn(
        type: TxType.expense,
        amount: 2550,
        merchant: 'RAMJI',
        date: DateTime(2026, 7, 6),
        ref: 'C1',
        categoryId: 'other_expense',
        sender: 'AX-YESBNK-S',
        rawBody: 'INR 2550 spent on YES BANK Card X1234. Avl Lmt INR 290000.',
        acctKey: 'YESBNK:1234',
        balanceAfter: 290000,
        isCard: true,
      ),
    ]);
    await p.confirmTransaction(p.pendingTransactions.single.id);
    final cardId = p.accounts.single.id;
    expect(p.accounts.single.type, AccountType.creditCard);
    await p.setCreditLimit(cardId, 300000);
    final card = p.accountById(cardId)!;
    expect(p.accountAvailable(card), 290000);
    expect(p.accountOutstanding(card), 10000);
  });

  ParsedTxn cardTxn({
    required TxType type,
    required double amount,
    required String categoryId,
    required DateTime date,
    required String ref,
    double? avlLmt,
  }) => ParsedTxn(
    type: type,
    amount: amount,
    merchant: '',
    date: date,
    ref: ref,
    categoryId: categoryId,
    sender: 'AX-YESBNK-S',
    rawBody: 'YES BANK Credit Card ending 1234 · $categoryId',
    acctKey: 'YESBNK:1234',
    balanceAfter: avlLmt,
    isCard: true,
  );

  /// Sets up a card anchored by a swipe that stated `Avl Lmt 290000`, with a
  /// user-set total limit of 300000 — so 10000 is owed at the anchor.
  Future<(FinanceProvider, String)> anchoredCard(List<ParsedTxn> extra) async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    await p.addImported([
      cardTxn(
        type: TxType.expense,
        amount: 2550,
        categoryId: 'other_expense',
        date: DateTime(2026, 7, 6, 14, 7),
        ref: 'ANCHOR',
        avlLmt: 290000,
      ),
      ...extra,
    ]);
    for (final t in p.pendingTransactions.toList()) {
      await p.confirmTransaction(t.id);
    }
    final cardId = p.accounts.single.id;
    await p.setCreditLimit(cardId, 300000);
    return (p, cardId);
  }

  test('card payment stating no new limit still reduces outstanding', () async {
    // The common shape: "payment received towards your credit card" with no
    // Avl Lmt figure. Before the ledger term existed this could not move the
    // outstanding at all, which is the bug this whole change is about.
    final (p, cardId) = await anchoredCard([
      cardTxn(
        type: TxType.income,
        amount: 6870.44,
        categoryId: kCardPaymentCategoryId,
        date: DateTime(2026, 7, 8, 22, 39),
        ref: 'PAY1',
      ),
    ]);
    final card = p.accountById(cardId)!;
    expect(p.accountOutstanding(card), closeTo(10000 - 6870.44, 0.001));
    // Available is defined as the complement, so the two can never disagree.
    expect(p.accountAvailable(card), closeTo(300000 - 3129.56, 0.001));
  });

  test('spends after the anchor raise outstanding again', () async {
    final (p, cardId) = await anchoredCard([
      cardTxn(
        type: TxType.income,
        amount: 6870.44,
        categoryId: kCardPaymentCategoryId,
        date: DateTime(2026, 7, 8, 22, 39),
        ref: 'PAY1',
      ),
      cardTxn(
        type: TxType.expense,
        amount: 1850,
        categoryId: 'other_expense',
        date: DateTime(2026, 7, 9, 11, 0),
        ref: 'SWIPE',
      ),
    ]);
    final card = p.accountById(cardId)!;
    expect(p.accountOutstanding(card), closeTo(10000 - 6870.44 + 1850, 0.001));
  });

  test('overpaying a card clamps outstanding at zero', () async {
    final (p, cardId) = await anchoredCard([
      cardTxn(
        type: TxType.income,
        amount: 25000,
        categoryId: kCardPaymentCategoryId,
        date: DateTime(2026, 7, 8, 22, 39),
        ref: 'PAY1',
      ),
    ]);
    final card = p.accountById(cardId)!;
    expect(p.accountOutstanding(card), 0);
    expect(p.accountAvailable(card), 300000);
  });

  test('a pending import does not raise the estimated credit limit', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    await p.addImported([
      cardTxn(
        type: TxType.expense,
        amount: 2550,
        categoryId: 'other_expense',
        date: DateTime(2026, 7, 6, 14, 7),
        ref: 'ANCHOR',
        avlLmt: 290000,
      ),
    ]);
    final card = p.accounts.single;
    // Unreviewed: it must not become the limit estimate the outstanding is
    // derived from.
    expect(p.accountCreditLimit(card), isNull);
    expect(p.accountOutstanding(card), isNull);
    await p.confirmTransaction(p.pendingTransactions.single.id);
    expect(p.accountCreditLimit(card), 290000);
  });

  test('figures sharing a timestamp resolve by insertion order', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    final at = DateTime(2026, 7, 4, 18);
    await p.addImported([
      bankSpend(
        sender: 'VM-HDFCBK',
        amount: 100,
        last4: '1234',
        avlBal: 4000,
        date: at,
        ref: 'R1',
      ),
      bankSpend(
        sender: 'VM-HDFCBK',
        amount: 200,
        last4: '1234',
        avlBal: 3000,
        date: at,
        ref: 'R2',
      ),
    ]);
    for (final t in p.pendingTransactions.toList()) {
      await p.confirmTransaction(t.id);
    }
    // Tie on timestamp → the later-inserted alert wins. Comparing dates alone
    // kept whichever happened to be first in the list.
    expect(p.accountBalance(p.accounts.single), 3000);
  });

  test('manual balance keeps up with later transactions', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    final id = await p.addAccount(name: 'Salary', type: AccountType.bank);
    await p.addAccountKey(id, 'HDFC:1111');
    await p.setManualBalance(id, 42000);
    final txId = await p.addTransaction(
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: 900,
      note: 'rent',
      date: DateTime.now().add(const Duration(minutes: 1)),
    );
    await p.assignAccount(txId, id);
    // Used to sit frozen at the manual figure regardless of later activity.
    expect(p.accountBalance(p.accountById(id)!), 41100);
  });

  test('merge folds source keys into target; transactions follow', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    await p.addImported([
      bankSpend(
        sender: 'VM-HDFCBK',
        amount: 100,
        last4: '1234',
        avlBal: 5000,
        date: DateTime(2026, 7, 1),
        ref: 'R1',
      ),
      bankSpend(
        sender: 'VM-HDFCBK',
        amount: 200,
        last4: '5678',
        avlBal: 9000,
        date: DateTime(2026, 7, 2),
        ref: 'R2',
      ),
    ]);
    for (final t in p.pendingTransactions.toList()) {
      await p.confirmTransaction(t.id);
    }
    final a1234 = p.accounts.firstWhere((a) => a.keys.contains('HDFC:1234'));
    final a5678 = p.accounts.firstWhere((a) => a.keys.contains('HDFC:5678'));
    expect(p.transactionsForAccount(a1234.id).length, 1);

    await p.mergeAccounts(a5678.id, a1234.id);
    expect(p.accounts.length, 1);
    // Both transactions now resolve to the surviving account.
    expect(p.transactionsForAccount(a1234.id).length, 2);
  });

  test('manual account + linked number adopts matching transactions', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();

    // Manual account created first, number linked by hand.
    final id = await p.addAccount(
      name: 'Indian Bank Salary',
      type: AccountType.bank,
    );
    expect(await p.addAccountKey(id, 'INDBNK:2080'), isTrue);

    // An import carrying that key resolves to the manual account —
    // no duplicate auto-created account.
    await p.addImported([
      ParsedTxn(
        type: TxType.expense,
        amount: 238.32,
        merchant: 'BOOKMYSHOW',
        date: DateTime(2026, 7, 3),
        ref: '309711253923',
        categoryId: 'other_expense',
        sender: 'BV-INDBNK-S',
        rawBody: 'A/c *2080 debited Rs. 238.32 to BOOKMYSHOW.',
        acctKey: 'INDBNK:2080',
      ),
    ]);
    await p.confirmTransaction(p.pendingTransactions.single.id);
    expect(p.accounts.length, 1);
    expect(p.transactionsForAccount(id).length, 1);

    // A key owned by one account cannot be linked to another.
    final other = await p.addAccount(name: 'Other', type: AccountType.bank);
    expect(await p.addAccountKey(other, 'INDBNK:2080'), isFalse);

    // Unlinking releases the transactions.
    await p.removeAccountKey(id, 'INDBNK:2080');
    expect(p.transactionsForAccount(id), isEmpty);
  });

  test(
    'backfill derives accounts from existing SMS notes on first load',
    () async {
      // Seed a transactions_v1 blob with no acctKey (pre-feature data).
      final legacy = Tx(
        id: 't1',
        type: TxType.expense,
        categoryId: 'other_expense',
        amount: 100,
        note: 'Rs.100 debited from a/c XX4321 on 01-07-26. Avl Bal Rs.7000.',
        date: DateTime(2026, 7, 1),
        source: TxSource.sms,
        sender: 'VM-ICICIB',
      );
      SharedPreferences.setMockInitialValues({
        'transactions_v1': '[${_json(legacy)}]',
      });
      final p = FinanceProvider();
      await p.load();
      expect(p.accounts.length, 1);
      final acc = p.accounts.single;
      expect(acc.keys, contains('ICICI:4321'));
      expect(p.accountBalance(acc), 7000);
    },
  );

  test('outstanding is null while the total limit is only a guess', () async {
    // The card states an available limit but the user never entered the total.
    // The largest figure seen *is* the newest one, so `limit − available` would
    // be exactly 0 — say "unknown" instead of claiming nothing is owed.
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    await p.addImported([
      cardTxn(
        type: TxType.income,
        amount: 1498,
        categoryId: kCardPaymentCategoryId,
        date: DateTime(2026, 4, 14, 22, 45),
        ref: 'PAY',
        avlLmt: 138000,
      ),
    ]);
    await p.confirmTransaction(p.pendingTransactions.single.id);
    final cardId = p.accounts.single.id;

    expect(p.accountOutstanding(p.accountById(cardId)!), isNull);
    expect(p.accountAvailable(p.accountById(cardId)!), isNull);
    expect(p.creditLimitIsEstimated(p.accountById(cardId)!), isTrue);
    expect(p.cardsMissingLimit, 1);

    // Entering the real limit makes it exact.
    await p.setCreditLimit(cardId, 150000);
    expect(p.accountOutstanding(p.accountById(cardId)!), 12000);
    expect(p.accountAvailable(p.accountById(cardId)!), 138000);
    expect(p.cardsMissingLimit, 0);
  });

  test('a manual balance with no timestamp does not throw', () async {
    // Possible in a hand-edited or older backup: the figure without its
    // timestamp. Reading it as "newer" used to dereference a null.
    SharedPreferences.setMockInitialValues({
      'accounts_v1':
          '[{"id":"a1","name":"Odd","type":"bank","keys":["HDFC:1234"],'
          '"manualBalance":500.0}]',
    });
    final p = FinanceProvider();
    await p.load();
    final acc = p.accounts.single;
    expect(acc.manualBalance, 500.0);
    // Normalised to the epoch rather than left null.
    expect(acc.manualBalanceAt, DateTime.fromMillisecondsSinceEpoch(0));
    // With no SMS figure to compare against it still applies…
    expect(() => p.accountBalance(acc), returnsNormally);
    expect(p.accountBalance(acc), 500);

    // …but an epoch timestamp loses to any stated figure, which is the point
    // of normalising instead of guessing that it is current.
    await p.addImported([
      bankSpend(
        sender: 'VM-HDFCBK',
        amount: 100,
        last4: '1234',
        avlBal: 7000,
        date: DateTime(2026, 7, 1, 9),
        ref: 'R1',
      ),
    ]);
    await p.confirmTransaction(p.pendingTransactions.single.id);
    expect(p.accountBalance(p.accountById('a1')!), 7000);
  });

  test('timestamp ties break on insertion order, not on id text', () async {
    // Ids "t_9" and "t_10" sort the *opposite* way as strings, so this fails if
    // the tie-break ever goes back to comparing ids.
    String tx(String id, double bal) =>
        '{"id":"$id","type":"expense","categoryId":"other_expense",'
        '"amount":10.0,"note":"n","date":"2026-07-04T18:00:00.000",'
        '"source":"sms","sender":"VM-HDFCBK","acctKey":"HDFC:1234",'
        '"balanceAfter":$bal}';
    SharedPreferences.setMockInitialValues({
      'transactions_v1': '[${tx('t_9', 4000)},${tx('t_10', 3000)}]',
      'accounts_v1':
          '[{"id":"a1","name":"HDFC","type":"bank","keys":["HDFC:1234"]}]',
      'accounts_migrated_v1': true,
      'accounts_migrated_v2': true,
    });
    final p = FinanceProvider();
    await p.load();
    // Later-inserted wins. A lexicographic id compare would pick t_9 → 4000.
    expect(p.accountBalance(p.accounts.single), 3000);
  });

  test('derived figures refresh after a mutation', () async {
    // Guards the invariant that notifyListeners() clears the cache: read every
    // memoised view first, then mutate, then read again.
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    final month = DateTime(2026, 7);

    expect(p.transactionCount, 0);
    expect(p.expenseInMonth(month), 0);
    expect(p.pendingCount, 0);
    expect(p.transactions, isEmpty);

    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 250,
      note: 'lunch',
      date: DateTime(2026, 7, 10, 13),
    );

    expect(p.transactionCount, 1);
    expect(p.expenseInMonth(month), 250);
    expect(p.totalExpense, 250);
    expect(p.expenseByCategory(month).single.value, 250);
    expect(p.transactions.single.note, 'lunch');

    await p.deleteTransaction(p.transactions.single.id);
    expect(p.expenseInMonth(month), 0);
    expect(p.transactions, isEmpty);
  });

  test('second migration re-derives what the old regex missed', () async {
    // An existing install where the first backfill already ran and found
    // nothing, because the account-key and time patterns were narrower then.
    final card = Tx(
      id: 't1',
      type: TxType.income,
      categoryId: kCardPaymentCategoryId,
      amount: 3591.69,
      note:
          'Dear Customer, Payment of INR 3,591.69 has been received on your '
          'ICICI Bank Credit Card Account 4xxx3010 on 31-MAY-26.Thank you.',
      date: DateTime(2026, 5, 31),
      source: TxSource.sms,
      sender: 'AX-ICICIT-S',
    );
    final timed = Tx(
      id: 't2',
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: 2550,
      note:
          'INR 2,550.00 spent on YES BANK Card xxxx 06-07-2026 02:07:35 pm. '
          'Avl Lmt INR 290541.59.',
      date: DateTime(2026, 7, 6),
      source: TxSource.sms,
      sender: 'AX-YESBNK-S',
    );
    SharedPreferences.setMockInitialValues({
      'transactions_v1': '[${_json(card)},${_json(timed)}]',
      'accounts_migrated_v1': true,
    });
    final p = FinanceProvider();
    await p.load();

    final restamped = p.transactions.firstWhere((t) => t.id == 't1');
    expect(restamped.acctKey, 'ICICI:3010');
    final acc = p.accountForKey('ICICI:3010')!;
    expect(acc.type, AccountType.creditCard);

    // Body clock time recovered; the stated limit picked up too.
    final withTime = p.transactions.firstWhere((t) => t.id == 't2');
    expect(withTime.date, DateTime(2026, 7, 6, 14, 7, 35));
    expect(withTime.balanceAfter, 290541.59);
  });

  test(
    'setting a bank balance by hand replaces the figure, not adds',
    () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();
      await p.addImported([
        bankSpend(
          sender: 'VM-HDFCBK',
          amount: 100,
          last4: '1234',
          avlBal: 5000,
          date: DateTime(2026, 7, 1, 9),
          ref: 'R1',
        ),
        // No stated balance: pure ledger movement after the anchor.
        ParsedTxn(
          type: TxType.expense,
          amount: 200,
          merchant: 'SHOP',
          date: DateTime(2026, 7, 2, 9),
          ref: 'R2',
          categoryId: 'other_expense',
          sender: 'VM-HDFCBK',
          rawBody: 'Rs.200 debited from a/c XX1234.',
          acctKey: 'HDFC:1234',
        ),
      ]);
      for (final t in p.pendingTransactions.toList()) {
        await p.confirmTransaction(t.id);
      }
      final acc = p.accounts.single;
      expect(p.accountBalance(acc), 4800); // anchor 5000 − 200

      await p.setManualBalance(acc.id, 45000);
      expect(p.accountBalance(p.accountById(acc.id)!), 45000);
      expect(p.bankBalanceTotal, 45000);
      expect(p.netWorth, 45000);
      expect(
        p.accountBalanceProvenance(p.accountById(acc.id)!).$1,
        BalanceSource.manual,
      );

      // An OLDER alert confirmed later must not override the newer manual
      // figure — the alert describes a moment before the user typed theirs.
      await p.addImported([
        bankSpend(
          sender: 'VM-HDFCBK',
          amount: 50,
          last4: '1234',
          avlBal: 9999,
          date: DateTime(2026, 7, 3, 9),
          ref: 'R3',
        ),
      ]);
      await p.confirmTransaction(p.pendingTransactions.single.id);
      expect(p.accountBalance(p.accountById(acc.id)!), 45000);

      // A NEWER alert takes over again — the documented handoff.
      await p.addImported([
        bankSpend(
          sender: 'VM-HDFCBK',
          amount: 50,
          last4: '1234',
          avlBal: 47000,
          date: DateTime.now().add(const Duration(minutes: 5)),
          ref: 'R4',
        ),
      ]);
      await p.confirmTransaction(p.pendingTransactions.single.id);
      expect(p.accountBalance(p.accountById(acc.id)!), 47000);
      expect(
        p.accountBalanceProvenance(p.accountById(acc.id)!).$1,
        BalanceSource.alert,
      );
    },
  );

  test('a mis-dated future row cannot out-rank a manual balance', () async {
    // Legacy data risk: an older build stamped a due date as the txn date.
    // Such a row must neither anchor the balance nor shift a manual figure.
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    await p.addImported([
      bankSpend(
        sender: 'VM-HDFCBK',
        amount: 100,
        last4: '1234',
        avlBal: 5000,
        date: DateTime(2026, 7, 1, 9),
        ref: 'R1',
      ),
      bankSpend(
        sender: 'VM-HDFCBK',
        amount: 5000,
        last4: '1234',
        avlBal: 15000,
        date: DateTime.now().add(const Duration(days: 40)),
        ref: 'R2',
      ),
    ]);
    for (final t in p.pendingTransactions.toList()) {
      await p.confirmTransaction(t.id);
    }
    final acc = p.accounts.single;
    // The future row is invisible to figures: the July anchor holds.
    expect(p.accountBalance(acc), 5000);
    // …and a manual set truly overrides.
    await p.setManualBalance(acc.id, 42000);
    expect(p.accountBalance(p.accountById(acc.id)!), 42000);
    expect(
      p.accountBalanceProvenance(p.accountById(acc.id)!).$1,
      BalanceSource.manual,
    );
  });

  test(
    'reassigning one SMS transaction does not hijack the bank key',
    () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();
      await p.addImported([
        bankSpend(
          sender: 'VM-HDFCBK',
          amount: 100,
          last4: '1111',
          avlBal: 5000,
          date: DateTime(2026, 7, 1, 9),
          ref: 'H1',
        ),
        bankSpend(
          sender: 'VM-ICICIB',
          amount: 200,
          last4: '2222',
          avlBal: 9000,
          date: DateTime(2026, 7, 2, 9),
          ref: 'I1',
        ),
        bankSpend(
          sender: 'VM-ICICIB',
          amount: 300,
          last4: '2222',
          avlBal: 8700,
          date: DateTime(2026, 7, 3, 9),
          ref: 'I2',
        ),
      ]);
      for (final t in p.pendingTransactions.toList()) {
        await p.confirmTransaction(t.id);
      }
      final hdfc = p.accountForKey('HDFC:1111')!;
      final icici = p.accountForKey('ICICI:2222')!;

      // Re-affirming the account a transaction already resolves to is a no-op:
      // no synthetic key appears (the edit sheet saves without touching the
      // account dropdown all the time).
      final h1 = p.transactions.firstWhere((t) => t.externalRef == 'H1');
      await p.assignAccount(h1.id, hdfc.id);
      expect(p.accountById(hdfc.id)!.keys, {'HDFC:1111'});

      final moved = p.transactions.firstWhere((t) => t.externalRef == 'I2');
      await p.assignAccount(moved.id, hdfc.id);

      // Only that one row moved…
      expect(p.transactionCountForAccount(hdfc.id), 2);
      expect(p.transactionCountForAccount(icici.id), 1);
      final after = p.transactions.firstWhere((t) => t.externalRef == 'I2');
      expect(after.acctKey, 'manual:${moved.id}');
      // …and its stated balance stayed behind: ICICI's Avl Bal must not
      // anchor the HDFC account.
      expect(after.balanceAfter, isNull);

      // The shared key still belongs to the ICICI account, so a new ICICI
      // alert lands there — the old code rerouted it to HDFC forever.
      expect(p.accountForKey('ICICI:2222')!.id, icici.id);
      await p.addImported([
        bankSpend(
          sender: 'VM-ICICIB',
          amount: 400,
          last4: '2222',
          avlBal: 8300,
          date: DateTime(2026, 7, 4, 9),
          ref: 'I3',
        ),
      ]);
      await p.confirmTransaction(p.pendingTransactions.single.id);
      expect(p.transactionCountForAccount(icici.id), 2);
      expect(p.transactionCountForAccount(hdfc.id), 2);

      // HDFC anchors on its own alert: 5000 − the moved 300.
      expect(p.accountBalance(p.accountById(hdfc.id)!), 4700);
      // ICICI anchors on its newest own alert.
      expect(p.accountBalance(p.accountById(icici.id)!), 8300);
    },
  );

  test('a debit alert stating Avl Bal anchors the balance; later spends '
      'subtract from it', () async {
    // End-to-end with the exact Indian Bank message reported as not moving
    // the balance, then the user's own example: 500 spent off a stated
    // figure must read as figure − 500.
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    const body =
        'Sent Rs.95.00 from A/c *2080 on 31-07-26 to Ms SINDHUJA  J..'
        'Avl Bal Rs.20146.51.Not you?SMS BLOCK to 999382328 -Indian Bank';
    final parsed = SmsTxnParser.parse(
      'BV-INDBNK-S',
      body,
      DateTime(2026, 7, 31, 18, 5),
    )!;
    await p.addImported([parsed]);

    // Pending imports must NOT move the balance — only reviewed ones count.
    final acc = p.accounts.single;
    expect(p.accountBalance(acc), 0);

    await p.confirmTransaction(p.pendingTransactions.single.id);
    expect(p.accountBalance(p.accountById(acc.id)!), 20146.51);

    // A later spend with no stated balance decrements the anchored figure.
    await p.addImported([
      ParsedTxn(
        type: TxType.expense,
        amount: 500,
        merchant: 'SHOP',
        date: DateTime(2026, 7, 31, 20),
        ref: 'R2',
        categoryId: 'other_expense',
        sender: 'BV-INDBNK-S',
        rawBody: 'Sent Rs.500.00 from A/c *2080 to SHOP.',
        acctKey: 'INDBNK:2080',
      ),
    ]);
    await p.confirmTransaction(p.pendingTransactions.single.id);
    expect(p.accountBalance(p.accountById(acc.id)!), 19646.51);
  });

  test(
    're-key migration folds squash-coded brand keys into the DLT code',
    () async {
      // A notification-captured alert keyed "INDIANBANK:2080" (brand-name
      // squash) belongs to the same real account as SMS-scanned "INDBNK:2080".
      final squashed = Tx(
        id: 's1',
        type: TxType.expense,
        categoryId: 'other_expense',
        amount: 95,
        note:
            'Sent Rs.95.00 from A/c *2080 on 31-07-26 to Ms SINDHUJA  J..'
            'Avl Bal Rs.20146.51.Not you?SMS BLOCK to 999382328 -Indian Bank',
        date: DateTime(2026, 7, 31),
        source: TxSource.sms,
        sender: 'Indian Bank',
        acctKey: 'INDIANBANK:2080',
        balanceAfter: 20146.51,
      );
      SharedPreferences.setMockInitialValues({
        'transactions_v1': jsonEncode([squashed.toJson()]),
        'accounts_v1': jsonEncode([
          Account(
            id: 'a1',
            name: 'Indian Bank',
            type: AccountType.bank,
            keys: {'INDBNK:2080'},
          ).toJson(),
        ]),
        'accounts_migrated_v1': true,
        'accounts_migrated_v2': true,
      });
      final p = FinanceProvider();
      await p.load();

      // Re-keyed to the DLT form and adopted by the existing account — its
      // stated balance now anchors the right tile.
      expect(
        p.transactions.firstWhere((t) => t.id == 's1').acctKey,
        'INDBNK:2080',
      );
      expect(p.transactionCountForAccount('a1'), 1);
      expect(p.accountBalance(p.accountById('a1')!), 20146.51);
    },
  );

  test('re-key migration clears machine-derived chimera keys only', () async {
    // Pre-fix data: an Indian Bank NEFT confirmation naming the ICICI
    // beneficiary account was keyed "INDBNK:879" — Indian Bank's name,
    // ICICI's digits — and a misnamed account was created around it.
    final chimera = Tx(
      id: 'c1',
      type: TxType.income,
      categoryId: 'other_income',
      amount: 25000,
      note:
          'NEFT of Rs.25,000.00 credited to ICICI Bank Account XXX879 '
          'on 01-08-26.',
      date: DateTime(2026, 8, 1),
      source: TxSource.sms,
      sender: 'BV-INDBNK-S',
      acctKey: 'INDBNK:879',
      balanceAfter: 42000,
    );
    // A key that is NOT what the machine would have derived was assigned by
    // hand — the migration must never touch it.
    final handSet = Tx(
      id: 'h1',
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: 100,
      note: 'Rs.100 debited from a/c XX1234 on 01-07-26.',
      date: DateTime(2026, 7, 1),
      source: TxSource.sms,
      sender: 'VM-HDFCBK',
      acctKey: 'ICICI:9999',
    );
    SharedPreferences.setMockInitialValues({
      'transactions_v1': jsonEncode([chimera.toJson(), handSet.toJson()]),
      'accounts_v1': jsonEncode([
        Account(
          id: 'a1',
          name: 'INDBNK ••879',
          type: AccountType.bank,
          keys: {'INDBNK:879'},
        ).toJson(),
      ]),
      'accounts_migrated_v1': true,
      'accounts_migrated_v2': true,
    });
    final p = FinanceProvider();
    await p.load();

    expect(p.transactions.firstWhere((t) => t.id == 'c1').acctKey, isNull);
    expect(p.transactionCountForAccount('a1'), 0);
    expect(
      p.transactions.firstWhere((t) => t.id == 'h1').acctKey,
      'ICICI:9999',
    );
  });

  test('assigning a debit alert to a savings account does not adopt the '
      'source account\'s Avl Bal (RD regression)', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    // The user's exact message: the Avl Bal describes ICICI ••879, but "Acc"
    // derives no key, so the row imports unassigned with the figure attached.
    await p.addImported([
      ParsedTxn(
        type: TxType.expense,
        amount: 5000,
        merchant: 'RD',
        date: DateTime(2026, 8, 1, 10),
        ref: 'RD1',
        categoryId: kSavingsTransferCategoryId,
        sender: 'AD-ICICIB',
        rawBody:
            'ICICI Bank Acc XX879 debited Rs. 5,000.00 on 01-Aug-26 InfoTo '
            'RD Ac no 1.Avl Bal Rs. 8,668.22.To dispute call 18002662 or '
            'SMS BLOCK 879 to 9215676766',
        acctKey: null,
        balanceAfter: 8668.22,
      ),
    ]);
    await p.confirmTransaction(p.pendingTransactions.single.id);

    final rdId = await p.addAccount(name: 'RD', type: AccountType.savings);
    await p.assignAccount(p.transactions.single.id, rdId);

    final rd = p.accountById(rdId)!;
    // The foreign figure must not anchor the RD account; the deposit itself
    // counts INTO the savings account (+5000, not −5000).
    expect(p.accountBalance(rd), 5000);
    final (source, _) = p.accountBalanceProvenance(rd);
    expect(source, isNot(BalanceSource.alert));
    expect(p.transactions.single.balanceAfter, isNull);
  });

  test('assignment keeps the stated balance when the SMS names a number '
      'linked to the target account', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    // Unkeyed at import (the number was not linked anywhere yet)…
    await p.addImported([
      ParsedTxn(
        type: TxType.expense,
        amount: 100,
        merchant: 'SHOP',
        date: DateTime(2026, 7, 1, 10),
        ref: 'K1',
        categoryId: 'other_expense',
        sender: 'VM-HDFCBK',
        rawBody: 'Rs.100 debited from a/c XX1234. Avl Bal Rs.5000.',
        acctKey: null,
        balanceAfter: 5000,
      ),
    ]);
    await p.confirmTransaction(p.pendingTransactions.single.id);
    // …then the user creates the account, links the number, and files the
    // row into it. The alert genuinely describes this account, so its figure
    // may anchor it.
    final id = await p.addAccount(name: 'HDFC', type: AccountType.bank);
    await p.addAccountKey(id, 'HDFC:1234');
    await p.assignAccount(p.transactions.single.id, id);

    expect(p.transactions.single.balanceAfter, 5000);
    expect(p.accountBalance(p.accountById(id)!), 5000);
    final (source, _) = p.accountBalanceProvenance(p.accountById(id)!);
    expect(source, BalanceSource.alert);
  });

  test('savings accounts count transfers with inverted sign', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    final rdId = await p.addAccount(name: 'RD', type: AccountType.savings);
    await p.setManualBalance(rdId, 10000);

    final now = DateTime.now();
    // Expense-typed "To savings" = deposit into this account.
    final dep = await p.addTransaction(
      type: TxType.expense,
      categoryId: kSavingsTransferCategoryId,
      amount: 5000,
      note: 'RD instalment',
      date: now.add(const Duration(minutes: 1)),
    );
    await p.assignAccount(dep, rdId);
    expect(p.accountBalance(p.accountById(rdId)!), 15000);

    // Income-typed transfer = withdrawal back to the bank.
    final wd = await p.addTransaction(
      type: TxType.income,
      categoryId: kTransferInCategoryId,
      amount: 2000,
      note: 'partial withdrawal',
      date: now.add(const Duration(minutes: 2)),
    );
    await p.assignAccount(wd, rdId);
    expect(p.accountBalance(p.accountById(rdId)!), 13000);

    // Non-transfer rows keep their natural sign (interest credit).
    final interest = await p.addTransaction(
      type: TxType.income,
      categoryId: 'investment',
      amount: 1000,
      note: 'interest',
      date: now.add(const Duration(minutes: 3)),
    );
    await p.assignAccount(interest, rdId);
    expect(p.accountBalance(p.accountById(rdId)!), 14000);

    // A deposit is not money "spent" on the RD tile.
    expect(p.accountSpentThisMonth(p.accountById(rdId)!), 0);
  });

  test(
    'v4 migration strips foreign balances from hand-moved rows only',
    () async {
      final rdBody =
          'ICICI Bank Acc XX879 debited Rs. 5,000.00 on 01-Aug-26 InfoTo '
          'RD Ac no 1.Avl Bal Rs. 8,668.22.';
      final corrupted = Tx(
        id: 'a',
        type: TxType.expense,
        categoryId: kSavingsTransferCategoryId,
        amount: 5000,
        note: rdBody,
        date: DateTime(2026, 8, 1, 10),
        source: TxSource.sms,
        sender: 'AD-ICICIB',
        acctKey: 'manual:a',
        balanceAfter: 8668.22,
      );
      final anchored = Tx(
        id: 'b',
        type: TxType.expense,
        categoryId: 'other_expense',
        amount: 100,
        note: 'Rs.100 debited from a/c XX1234. Avl Bal Rs.5000.',
        date: DateTime(2026, 7, 1, 10),
        source: TxSource.sms,
        sender: 'VM-HDFCBK',
        acctKey: 'HDFC:1234',
        balanceAfter: 5000,
      );
      // Hand-moved, but its own SMS names a number the owning account holds —
      // a legitimate anchor that must survive.
      final legit = Tx(
        id: 'd',
        type: TxType.expense,
        categoryId: 'other_expense',
        amount: 300,
        note: 'Rs.300 debited from a/c XX1234. Avl Bal Rs.4700.',
        date: DateTime(2026, 7, 2, 10),
        source: TxSource.sms,
        sender: 'VM-HDFCBK',
        acctKey: 'manual:d',
        balanceAfter: 4700,
      );
      SharedPreferences.setMockInitialValues({
        'transactions_v1': jsonEncode([
          corrupted.toJson(),
          anchored.toJson(),
          legit.toJson(),
        ]),
        'accounts_v1': jsonEncode([
          Account(
            id: 'acc_rd',
            name: 'RD',
            type: AccountType.savings,
            keys: {'manual:a'},
          ).toJson(),
          Account(
            id: 'acc_h',
            name: 'HDFC',
            type: AccountType.bank,
            keys: {'HDFC:1234', 'manual:d'},
          ).toJson(),
        ]),
        'accounts_migrated_v1': true,
        'accounts_migrated_v2': true,
        'accounts_migrated_v3': true,
      });
      final p = FinanceProvider();
      await p.load();

      Tx byId(String id) => p.transactions.firstWhere((t) => t.id == id);
      expect(byId('a').balanceAfter, isNull); // repaired
      expect(byId('b').balanceAfter, 5000); // untouched: still on its bank key
      expect(byId('d').balanceAfter, 4700); // untouched: legitimately anchored

      // One-shot: a second load changes nothing further.
      final p2 = FinanceProvider();
      await p2.load();
      expect(
        p2.transactions.firstWhere((t) => t.id == 'a').balanceAfter,
        isNull,
      );
    },
  );
}

// Minimal inline JSON for the legacy Tx (mirrors Tx.toJson essentials).
String _json(Tx t) =>
    '{"id":"${t.id}","type":"${t.type.name}","categoryId":"${t.categoryId}",'
    '"amount":${t.amount},"note":"${t.note.replaceAll('"', '\\"')}",'
    '"date":"${t.date.toIso8601String()}","source":"${t.source.name}",'
    '"sender":"${t.sender}"}';
