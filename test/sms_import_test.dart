import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/sms_parser.dart';

ParsedTxn txn({
  TxType type = TxType.expense,
  double amount = 100,
  String merchant = 'Swiggy',
  DateTime? date,
  String? ref,
  String categoryId = 'food',
  String sender = 'VM-HDFCBK',
  String rawBody = 'Rs.100 debited at SWIGGY',
  bool spamSuspect = false,
}) => ParsedTxn(
  type: type,
  amount: amount,
  merchant: merchant,
  date: date ?? DateTime(2026, 7, 1, 13, 0),
  ref: ref,
  categoryId: categoryId,
  sender: sender,
  rawBody: rawBody,
  spamSuspect: spamSuspect,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('imported transactions are pending and excluded from totals', () async {
    final p = FinanceProvider();
    await p.load();

    final (added, _) = await p.addImported([txn(amount: 250, ref: 'REF1')]);
    expect(added, 1);
    expect(p.pendingTransactions.length, 1);
    expect(p.transactions, isEmpty);
    expect(p.totalExpense, 0);

    await p.confirmTransaction(p.pendingTransactions.single.id);
    expect(p.pendingTransactions, isEmpty);
    expect(p.transactions.length, 1);
    expect(p.totalExpense, 250);
  });

  test('same bank ref is deduplicated across imports', () async {
    final p = FinanceProvider();
    await p.load();

    await p.addImported([txn(ref: 'REF1')]);
    final (added, _) = await p.addImported([
      txn(ref: 'REF1'),
      txn(ref: 'REF2'),
    ]);
    expect(added, 1);
    expect(p.pendingTransactions.length, 2);
  });

  test('ref-less duplicates matched by amount+type+time window', () async {
    final p = FinanceProvider();
    await p.load();

    final d = DateTime(2026, 7, 1, 13, 0);
    await p.addImported([txn(amount: 99, date: d)]);
    // Same alert delivered twice a minute later → duplicate.
    var (added, _) = await p.addImported([
      txn(amount: 99, date: d.add(const Duration(minutes: 1))),
    ]);
    expect(added, 0);
    // Same amount hours apart → genuinely separate purchase.
    (added, _) = await p.addImported([
      txn(amount: 99, date: d.add(const Duration(hours: 5))),
    ]);
    expect(added, 1);
  });

  test('confirmAllPending confirms everything at once', () async {
    final p = FinanceProvider();
    await p.load();
    await p.addImported([txn(ref: 'A'), txn(ref: 'B'), txn(ref: 'C')]);

    await p.confirmAllPending();
    expect(p.pendingTransactions, isEmpty);
    expect(p.transactions.length, 3);
  });

  test('discarding a pending import removes it', () async {
    final p = FinanceProvider();
    await p.load();
    await p.addImported([txn(ref: 'A')]);

    await p.deleteTransaction(p.pendingTransactions.single.id);
    expect(p.pendingTransactions, isEmpty);
    expect(p.transactions, isEmpty);
  });

  test('pending state and source survive persistence round-trip', () async {
    final p1 = FinanceProvider();
    await p1.load();
    await p1.addImported([txn(ref: 'A')]);

    final p2 = FinanceProvider();
    await p2.load();
    expect(p2.pendingTransactions.length, 1);
    expect(p2.pendingTransactions.single.source, TxSource.sms);
    expect(p2.pendingTransactions.single.externalRef, 'A');
  });

  test('imports store the SMS sender and full message as smsBody', () async {
    final p = FinanceProvider();
    await p.load();
    await p.addImported([
      txn(
        ref: 'A',
        sender: 'AD-SBIUPI',
        rawBody: 'Dear UPI user A/C X5678 debited by Rs.100 trf to SWIGGY',
      ),
    ]);

    final t = p.pendingTransactions.single;
    expect(t.sender, 'AD-SBIUPI');
    expect(
      t.smsBody,
      'Dear UPI user A/C X5678 debited by Rs.100 trf to SWIGGY',
    );
    // The note is the user's own field now — imports leave it empty.
    expect(t.note, '');
  });

  test('spam rule drops matching messages entirely', () async {
    final p = FinanceProvider();
    await p.load();
    await p.addRule('this is a spam message', 'spam');

    final (added, spamDropped) = await p.addImported([
      txn(ref: 'A', rawBody: 'Rs.100 debited. THIS IS A SPAM MESSAGE offer!'),
      txn(ref: 'B', rawBody: 'Rs.200 debited at SWIGGY'),
    ]);
    expect(added, 1);
    expect(spamDropped, 1);
    expect(p.pendingTransactions.single.externalRef, 'B');
  });

  test('category rule overrides parser guess and clears suspicion', () async {
    final p = FinanceProvider();
    await p.load();
    await p.addRule('Chai Kings', 'food');

    await p.addImported([
      txn(
        ref: 'A',
        categoryId: 'other_expense',
        rawBody:
            'ICICI Bank Acct XX879 debited for Rs 75.00; Chai Kings Gudu credited.',
        spamSuspect: true,
      ),
    ]);
    final t = p.pendingTransactions.single;
    expect(t.categoryId, 'food');
    expect(t.suspectedSpam, isFalse);
  });

  test('income rule does not apply to an expense', () async {
    final p = FinanceProvider();
    await p.load();
    await p.addRule('ZOHO', 'salary'); // salary is an income category

    await p.addImported([
      txn(ref: 'A', categoryId: 'other_expense', rawBody: 'debited to ZOHO'),
    ]);
    expect(p.pendingTransactions.single.categoryId, 'other_expense');
  });

  test('suspected spam is excluded from confirm-all', () async {
    final p = FinanceProvider();
    await p.load();
    await p.addImported([txn(ref: 'A'), txn(ref: 'B', spamSuspect: true)]);

    await p.confirmAllPending();
    expect(p.transactions.length, 1);
    expect(p.pendingTransactions.single.suspectedSpam, isTrue);

    // Individual confirmation still works for suspects.
    await p.confirmTransaction(p.pendingTransactions.single.id);
    expect(p.pendingTransactions, isEmpty);
    expect(p.transactions.length, 2);
  });

  test('rules persist across provider instances', () async {
    final p1 = FinanceProvider();
    await p1.load();
    await p1.addRule('Chai Kings', 'food');

    final p2 = FinanceProvider();
    await p2.load();
    // Built-in keyword rules are seeded alongside; the user rule stays
    // first in the list so it outranks them during matching.
    final userRules = p2.rules.where((r) => !r.isBuiltIn).toList();
    expect(userRules.single.pattern, 'Chai Kings');
    expect(userRules.single.categoryId, 'food');
    expect(p2.rules.first.pattern, 'Chai Kings');
  });

  test('clearAll wipes transactions and accounts', () async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 10,
      note: '',
      date: DateTime(2026, 7, 1),
    );
    await p.addImported([txn(ref: 'A')]);

    await p.clearAll();
    expect(p.transactions, isEmpty);
    expect(p.pendingTransactions, isEmpty);
    expect(p.accounts, isEmpty);

    // And the empty state persists.
    final p2 = FinanceProvider();
    await p2.load();
    expect(p2.transactions, isEmpty);
    expect(p2.accounts, isEmpty);
  });
}
