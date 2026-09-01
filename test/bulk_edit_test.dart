import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<FinanceProvider> seeded() async {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []); // module-global registry — isolate tests
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: 100,
      note: 'a',
      date: DateTime(2026, 7, 1, 10),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: 200,
      note: 'b',
      date: DateTime(2026, 7, 2, 10),
    );
    await p.addTransaction(
      type: TxType.income,
      categoryId: 'other_income',
      amount: 300,
      note: 'c',
      date: DateTime(2026, 7, 3, 10),
    );
    return p;
  }

  test('bulk category applies to matching-type rows only', () async {
    final p = await seeded();
    final ids = {for (final t in p.transactions) t.id};
    // "food" is an expense category — the income row must be skipped, not
    // silently converted.
    final changed = await p.setCategoryForMany(ids, 'food');
    expect(changed, 2);
    expect(p.transactions.where((t) => t.categoryId == 'food').length, 2);
    expect(
      p.transactions.where((t) => t.categoryId == 'other_income').length,
      1,
    );
  });

  test('bulk account assignment moves every selected row safely', () async {
    final p = await seeded();
    final id = await p.addAccount(name: 'HDFC', type: AccountType.bank);
    final ids = {for (final t in p.transactions) t.id};
    final changed = await p.assignAccountToMany(ids, id);
    expect(changed, 3);
    expect(p.transactionCountForAccount(id), 3);
    // Re-running over the same selection is a no-op, not a re-write.
    expect(await p.assignAccountToMany(ids, id), 0);
  });

  test(
    'bulk-applying a custom transfer category respects the type guard',
    () async {
      final p = await seeded();
      final chitId = await p.addCategory(
        label: 'Chit',
        type: TxType.expense,
        icon: Icons.savings,
        color: Colors.teal,
        isTransfer: true,
      );
      final ids = {for (final t in p.transactions) t.id};
      final changed = await p.setCategoryForMany(ids, chitId);
      expect(changed, 2); // the income row is skipped, not converted
      expect(p.totalExpense, 0); // transfer rows leave the expense totals
      expect(p.totalIncome, 300);
    },
  );

  test('bulk date-time stamps every selected row', () async {
    final p = await seeded();
    final ids = {for (final t in p.transactions) t.id};
    final when = DateTime(2026, 7, 15, 18, 30);
    final changed = await p.setDateTimeForMany(ids, when);
    expect(changed, 3);
    expect(p.transactions.every((t) => t.date == when), isTrue);
  });
}
