import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('totals and balance are computed from transactions and goals', () async {
    final p = FinanceProvider();
    await p.load();

    await p.addTransaction(
      type: TxType.income,
      categoryId: 'salary',
      amount: 50000,
      note: 'July salary',
      date: DateTime(2026, 7, 1),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 1200,
      note: 'Groceries',
      date: DateTime(2026, 7, 2),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: kSavingsTransferCategoryId,
      amount: 5000,
      note: 'RD instalment',
      date: DateTime(2026, 7, 3),
    );

    expect(p.totalIncome, 50000);
    expect(p.totalExpense, 1200); // savings transfer excluded from expenses
    expect(p.totalSavingsTransfers, 5000);
    expect(p.balance, 50000 - 1200 - 5000);
  });

  test('monthly aggregation only counts the given month', () async {
    final p = FinanceProvider();
    await p.load();

    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 100,
      note: '',
      date: DateTime(2026, 6, 30),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 250,
      note: '',
      date: DateTime(2026, 7, 15),
    );

    expect(p.expenseInMonth(DateTime(2026, 7)), 250);
    expect(p.expenseInMonth(DateTime(2026, 6)), 100);
    expect(p.expenseByCategory(DateTime(2026, 7)).single.value, 250);
  });

  test('transactions persist across provider instances', () async {
    final p1 = FinanceProvider();
    await p1.load();
    await p1.addTransaction(
      type: TxType.income,
      categoryId: 'salary',
      amount: 1000,
      note: 'persisted',
      date: DateTime(2026, 7, 1),
    );

    final p2 = FinanceProvider();
    await p2.load();
    expect(p2.transactions.single.note, 'persisted');
    expect(p2.transactions.single.amount, 1000);
  });

  test('update and delete transaction', () async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 10,
      note: '',
      date: DateTime(2026, 7, 1),
    );
    final tx = p.transactions.single;

    await p.updateTransaction(tx.copyWith(amount: 20));
    expect(p.transactions.single.amount, 20);

    await p.deleteTransaction(tx.id);
    expect(p.transactions, isEmpty);
  });
}
