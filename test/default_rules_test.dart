import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/sms_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('built-in keyword rules are seeded and classify imports', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();

    expect(
      p.rules.any((r) => r.pattern == 'swiggy' && r.categoryId == 'food'),
      isTrue,
    );
    expect(p.rules.where((r) => r.isBuiltIn), isNotEmpty);

    // The parser no longer categorises — the seeded rule does, on import.
    final (added, _) = await p.addImported([
      ParsedTxn(
        type: TxType.expense,
        amount: 250,
        merchant: 'SWIGGY',
        date: DateTime(2026, 7, 1),
        ref: 'REF123456',
        categoryId: 'other_expense',
        sender: 'VM-HDFCBK',
        rawBody: 'Rs.250.00 debited from a/c XX1234 at SWIGGY Ref REF123456.',
      ),
    ]);
    expect(added, 1);
    expect(p.pendingTransactions.single.categoryId, 'food');
  });

  test('seeding happens once — no duplicates on reload', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    final count = p.rules.length;

    final p2 = FinanceProvider();
    await p2.load();
    expect(p2.rules.length, count);
  });

  test('user rules outrank built-ins and clear spam suspicion', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    // User rule added later must win over the seeded swiggy → food rule.
    await p.addRule('swiggy', 'entertainment');

    await p.addImported([
      ParsedTxn(
        type: TxType.expense,
        amount: 99,
        merchant: 'SWIGGY',
        date: DateTime(2026, 7, 2),
        ref: 'REF987654',
        categoryId: 'other_expense',
        sender: 'VM-HDFCBK',
        rawBody: 'Rs.99.00 debited at SWIGGY Ref REF987654.',
      ),
    ]);
    expect(p.pendingTransactions.single.categoryId, 'entertainment');
  });

  test('built-in rule match keeps the spam-suspect flag', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();

    await p.addImported([
      ParsedTxn(
        type: TxType.expense,
        amount: 199,
        merchant: 'JIO RECHARGE',
        date: DateTime(2026, 7, 3),
        ref: 'REF555555',
        categoryId: 'other_expense',
        sender: 'VM-HDFCBK',
        rawBody:
            'Rs.199.00 debited for JIO RECHARGE Ref REF555555. '
            'Recharge now and win cashback https://promo.example',
        spamSuspect: true,
      ),
    ]);
    final tx = p.pendingTransactions.single;
    // Categorised by the built-in "recharge" rule…
    expect(tx.categoryId, 'bills');
    // …but still quarantined for individual review.
    expect(tx.suspectedSpam, isTrue);
  });

  test('adding a rule recategorises existing SMS transactions', () async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();

    await p.addImported([
      ParsedTxn(
        type: TxType.expense,
        amount: 120,
        merchant: 'CHAI KINGS',
        date: DateTime(2026, 6, 20),
        ref: 'REF111222',
        categoryId: 'other_expense',
        sender: 'VM-HDFCBK',
        rawBody: 'Rs.120.00 debited at CHAI KINGS Ref REF111222.',
      ),
    ]);
    await p.confirmTransaction(p.pendingTransactions.single.id);
    expect(p.transactions.single.categoryId, 'other_expense');

    await p.addRule('chai kings', 'food');
    expect(p.transactions.single.categoryId, 'food');
  });
}
